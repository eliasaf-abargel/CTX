import CTXCore
import Foundation

func testProfileCommandServiceBuildsProviderCommands() async {
    let runner = RecordingCloudRunner()
    let kubectl = ScriptedKubectl()
    let service = ProfileCommandService(runner: runner, kubectl: kubectl)
    let aws = CloudProfile(provider: .aws, name: "dev")
    let gcp = CloudProfile(provider: .gcp, name: "dev", roleName: "dev@example.com")
    let azure = CloudProfile(provider: .azure, name: "dev", accountID: "sub-123", roleName: "tenant-123")
    let kube = CloudProfile(provider: .kubernetes, name: "dev-context")

    _ = await service.activateGCPConfiguration(gcp)
    _ = await service.activateAzureSubscription(azure)
    _ = await service.login(aws)
    _ = await service.login(gcp)
    _ = await service.login(azure)
    _ = await service.selectAzureSubscription(azure)
    _ = await service.logout(aws)
    _ = await service.logout(gcp)
    _ = await service.logout(azure)
    _ = await service.signOutFromProvider(aws)
    _ = await service.signOutFromProvider(gcp)
    _ = await service.signOutFromProvider(azure)
    _ = await service.verify(aws, activeKubeContext: "")
    _ = await service.verify(gcp, activeKubeContext: "")
    _ = await service.verify(azure, activeKubeContext: "")
    _ = await service.verify(kube, activeKubeContext: "dev-context")
    _ = await service.exportAWSCredentials(for: aws)

    let commands = await runner.allCommands()
    assert(commands == [
        ["gcloud", "config", "configurations", "activate", "dev"],
        ["az", "account", "set", "--subscription", "sub-123"],
        ["aws", "sso", "login", "--profile", "dev", "--no-browser"],
        ["gcloud", "auth", "login", "--configuration", "dev", "--account", "dev@example.com"],
        ["gcloud", "auth", "application-default", "login"],
        ["az", "login", "--tenant", "tenant-123"],
        ["az", "account", "set", "--subscription", "sub-123"],
        ["aws", "sso", "logout"],
        ["gcloud", "auth", "revoke", "dev@example.com", "--configuration", "dev"],
        ["az", "logout"],
        ["aws", "sts", "get-caller-identity", "--profile", "dev", "--output", "json"],
        ["gcloud", "config", "configurations", "describe", "dev", "--format=value(properties.core.account)", "--quiet"],
        ["az", "account", "show", "--subscription", "sub-123", "--output", "json"],
        ["az", "account", "get-access-token", "--subscription", "sub-123", "--output", "none"],
        ["aws", "configure", "export-credentials", "--profile", "dev", "--output", "json"]
    ])
    assert(kubectl.commands.map(\.arguments) == [
        ["--context", "dev-context", "get", "--raw=/version", "--request-timeout=10s"]
    ])
}

func testProfileCommandServiceReadsProviderPathsPerCommand() async {
    let suiteName = "ctx-provider-environment-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("/configs/aws", forKey: CTXDefaultsKey.awsConfigPath)
    defaults.set("/configs/credentials", forKey: CTXDefaultsKey.awsCredentialsPath)
    defaults.set("/configs/gcloud", forKey: CTXDefaultsKey.gcpConfigDirPath)
    defaults.set("/configs/azure", forKey: CTXDefaultsKey.azureCLIDirPath)

    let runner = RecordingCloudRunner()
    let service = ProfileCommandService(
        runner: runner,
        providerEnvironment: {
            ProviderCommandEnvironment.overrides(defaults: UserDefaults(suiteName: suiteName)!)
        }
    )
    let profile = CloudProfile(provider: .aws, name: "dev")

    _ = await service.verify(profile, activeKubeContext: "")
    defaults.set("/configs/aws-updated", forKey: CTXDefaultsKey.awsConfigPath)
    _ = await service.verify(profile, activeKubeContext: "")
    _ = await service.exportAWSCredentials(for: profile)
    _ = await service.signOutFromProvider(profile)
    _ = await service.signOutFromProvider(
        CloudProfile(provider: .gcp, name: "dev", roleName: "developer@example.com")
    )
    _ = await service.signOutFromProvider(
        CloudProfile(provider: .azure, name: "dev", accountID: "subscription-123")
    )

    let environments = await runner.allEnvironmentOverrides()
    assert(environments.count == 6)
    assert(environments[0]["AWS_CONFIG_FILE"] == "/configs/aws")
    assert(environments[0]["AWS_SHARED_CREDENTIALS_FILE"] == "/configs/credentials")
    assert(environments[0]["CLOUDSDK_CONFIG"] == "/configs/gcloud")
    assert(environments[0]["AZURE_CONFIG_DIR"] == "/configs/azure")
    assert(environments[1]["AWS_CONFIG_FILE"] == "/configs/aws-updated")
    assert(environments[2]["AWS_CONFIG_FILE"] == "/configs/aws-updated")
    assert(environments[2]["AWS_SHARED_CREDENTIALS_FILE"] == "/configs/credentials")
    for environment in environments.dropFirst(3) {
        assert(environment["AWS_CONFIG_FILE"] == "/configs/aws-updated")
        assert(environment["AWS_SHARED_CREDENTIALS_FILE"] == "/configs/credentials")
        assert(environment["CLOUDSDK_CONFIG"] == "/configs/gcloud")
        assert(environment["AZURE_CONFIG_DIR"] == "/configs/azure")
    }
}

@MainActor
func testProfileStoreReloadsLiveAWSPathAndSharesCommandDefaults() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-live-aws-path-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let initialConfig = directory.appendingPathComponent("initial-config")
    let updatedConfig = directory.appendingPathComponent("updated-config")
    try "[default]\nregion = keep-me\n[profile initial]\nsso_region = us-east-1\n".write(
        to: initialConfig,
        atomically: true,
        encoding: .utf8
    )
    try "[default]\nregion = remove-me\n[profile updated]\nsso_region = us-west-2\n".write(
        to: updatedConfig,
        atomically: true,
        encoding: .utf8
    )
    let suiteName = "ctx-live-aws-path-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let credentialsURL = directory.appendingPathComponent("credentials")
    try "[default]\naws_access_key_id = REMOVE\naws_secret_access_key = remove\n".write(
        to: credentialsURL,
        atomically: true,
        encoding: .utf8
    )
    defaults.set(credentialsURL.path, forKey: CTXDefaultsKey.awsCredentialsPath)
    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: initialConfig,
        runner: runner,
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        defaults: defaults,
        startsBackgroundServices: false
    )
    assert(store.profiles.contains { $0.provider == .aws && $0.name == "initial" })

    defaults.set(updatedConfig.path, forKey: CTXDefaultsKey.awsConfigPath)
    store.reloadConfiguredSources()
    try await Task.sleep(nanoseconds: 400_000_000)

    guard let updated = store.profiles.first(where: { $0.provider == .aws && $0.name == "updated" }) else {
        assertionFailure("updated AWS config path was not rediscovered")
        return
    }
    _ = await store.verify(updated)
    let environments = await runner.allEnvironmentOverrides()
    assert(environments.last?["AWS_CONFIG_FILE"] == updatedConfig.path)
    assert(environments.last?["AWS_SHARED_CREDENTIALS_FILE"] == credentialsURL.path)

    store.clearActive(for: .aws)
    let updatedText = try String(contentsOf: updatedConfig, encoding: .utf8)
    let initialText = try String(contentsOf: initialConfig, encoding: .utf8)
    let credentialsText = try String(contentsOf: credentialsURL, encoding: .utf8)
    assert(!updatedText.contains("[default]"))
    assert(initialText.contains("[default]"), "injected defaults must not mutate the fallback config")
    assert(!credentialsText.contains("[default]"))
}

func testKubernetesVerificationPreservesContextPathAndProviderEnvironment() async {
    let runner = RecordingCloudRunner()
    let kubectl = ScriptedKubectl()
    let service = ProfileCommandService(
        runner: runner,
        kubectl: kubectl,
        providerEnvironment: {
            [
                "AWS_CONFIG_FILE": "/configs/aws",
                "AWS_SHARED_CREDENTIALS_FILE": "/configs/credentials",
                "CLOUDSDK_CONFIG": "/configs/gcloud",
                "AZURE_CONFIG_DIR": "/configs/azure"
            ]
        }
    )

    let result = await service.verify(
        CloudProfile(provider: .kubernetes, name: "prod-context"),
        activeKubeContext: "prod-context",
        kubeconfigPath: "/configs/kube/prod"
    )

    assert(result.exitCode == 0)
    assert(kubectl.commands.count == 1)
    let command = kubectl.commands[0]
    assert(Array(command.arguments.prefix(2)) == ["--context", "prod-context"])
    assert(command.arguments.contains("--kubeconfig"))
    assert(command.arguments.contains("/configs/kube/prod"))
    assert(command.environmentOverrides["KUBECONFIG"] == "/configs/kube/prod")
    assert(command.environmentOverrides["AWS_CONFIG_FILE"] == "/configs/aws")
    assert(command.environmentOverrides["AWS_SHARED_CREDENTIALS_FILE"] == "/configs/credentials")
    assert(command.environmentOverrides["CLOUDSDK_CONFIG"] == "/configs/gcloud")
    assert(command.environmentOverrides["AZURE_CONFIG_DIR"] == "/configs/azure")
    let cloudCommands = await runner.allCommands()
    assert(cloudCommands == [], "kubectl verification must not use CloudCommandRunner")
}

func testProfileCommandServiceRedactsFailedOutput() async {
    let runner = RecordingCloudRunner()
    await runner.setDefault(CommandResult(exitCode: 1, output: "bearer demo-token failed"))
    let service = ProfileCommandService(runner: runner)

    let result = await service.login(CloudProfile(provider: .aws, name: "dev"))

    assert(result.output.contains("[redacted]"))
    assert(!result.output.contains("demo-token"))
}

func testProfileCommandServiceStrongDMLoginAndVerify() async {
    actor CustomCommandRunner: CloudCommandRunning {
        private var commands: [[String]] = []
        private var results: [CommandResult] = []

        func setResults(_ results: [CommandResult]) {
            self.results = results
        }

        func allCommands() -> [[String]] {
            commands
        }

        func run(
            _ arguments: [String],
            environmentOverrides: [String: String],
            timeout: TimeInterval,
            onOutput: (@Sendable (String) -> Void)?
        ) async -> CommandResult {
            commands.append(arguments)
            if !results.isEmpty {
                return results.removeFirst()
            }
            return CommandResult(exitCode: 0, output: "")
        }
    }

    let runner = CustomCommandRunner()
    await runner.setResults([
        CommandResult(exitCode: 0, output: "sdm-context connected"), // sdm status for verify
        CommandResult(exitCode: 0, output: "connect success"), // sdm connect for login
        CommandResult(exitCode: 0, output: "disconnect success") // sdm disconnect for logout
    ])

    let kubectl = ScriptedKubectl()
    kubectl.outputForCommand = { _ in .success("{}") }
    let service = ProfileCommandService(runner: runner, kubectl: kubectl)
    let sdmKube = CloudProfile(provider: .kubernetes, name: "sdm-context", roleName: ("sdm-" + "user"))

    // Test verify when cluster API succeeds
    let verifyResult = await service.verify(sdmKube, activeKubeContext: "sdm-context")
    assert(verifyResult.exitCode == 0)

    // Test login: runs sdm connect directly
    let loginResult = await service.login(sdmKube)
    assert(loginResult.exitCode == 0)

    // Test logout
    let logoutResult = await service.logout(sdmKube)
    assert(logoutResult.exitCode == 0)
    let teleport = CloudProfile(provider: .kubernetes, name: "teleport-context", roleName: "tsh-user")
    let teleportLogout = await service.logout(teleport)
    assert(teleportLogout.exitCode == 0)

    let commands = await runner.allCommands()
    assert(commands == [
        ["sdm", "status"],
        ["sdm", "connect", "sdm-context"],
        ["sdm", "disconnect", "sdm-context"],
        ["tsh", "kube", "logout", "teleport-context"]
    ])
    await runner.setResults([
        CommandResult(exitCode: 1, output: "login required"),
        CommandResult(exitCode: 0, output: "signed in"),
        CommandResult(exitCode: 1, output: "resource unavailable")
    ])
    let failedReconnect = await service.login(sdmKube)
    assert(failedReconnect.exitCode == 1)

}

func testCTXUpdateServiceParsesReleaseAndComparesVersions() throws {
    let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v1.2.3"])

    assert(CTXUpdateService.releaseTag(from: data) == "v1.2.3")
    assert(CTXUpdateService.isUpdateAvailable(latestTag: "v1.2.3", currentVersion: "1.2.2"))
    assert(!CTXUpdateService.isUpdateAvailable(latestTag: "v1.2.3", currentVersion: "1.2.3"))
    assert(CTXUpdateService.downloadURL(for: "v1.2.3")?.absoluteString == "https://github.com/opsbit-io/ctx/releases/download/v1.2.3/CTX.app.zip")
}

func testAWSSessionExpirationServicePrefersCredentialsExpiry() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-aws-expiry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let credentialsURL = dir.appendingPathComponent("credentials")
    try """
    [dev]
    aws_access_key_id = example
    aws_session_expiration = 2026-07-04T12:34:56Z
    """.write(to: credentialsURL, atomically: true, encoding: .utf8)

    let cacheURL = dir.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    try """
    {"startUrl":"https://example.awsapps.com/start","expiresAt":"2026-07-04T11:00:00Z"}
    """.write(to: cacheURL.appendingPathComponent("cache.json"), atomically: true, encoding: .utf8)

    let service = AWSSessionExpirationService(credentialsURL: credentialsURL, ssoCacheURL: cacheURL)
    let profile = CloudProfile(provider: .aws, name: "dev", ssoStartURL: "https://example.awsapps.com/start")
    let expiry = service.sessionExpiry(for: profile)

    assert(expiry == ISO8601DateFormatter().date(from: "2026-07-04T12:34:56Z"))
}

func testAWSCredentialsFileAuditFlagsConfigKeysThatOverrideTheConfigFile() throws {
    let text = """
    [demo]
    sso_start_url = https://stale.awsapps.com/start
    aws_access_key_id = AKIA
    aws_secret_access_key = secret

    [plain]
    aws_access_key_id = AKIA
    aws_secret_access_key = secret
    aws_session_token = token

    [inherits]
    Role_ARN = arn:aws:iam::111122223333:role/Admin
    """

    let conflicts = AWSCredentialsFileAudit.conflicts(credentialsText: text)
    assert(conflicts.count == 2)
    assert(conflicts[0].profileName == "demo")
    assert(conflicts[0].overridingKeys == ["sso_start_url"])
    // Credentials-only sections are the normal case and must stay quiet — CTX
    // writes them itself after every verified login.
    assert(!conflicts.contains { $0.profileName == "plain" })
    // Key matching is case-insensitive, like the CLI's own parser.
    assert(conflicts[1].overridingKeys == ["role_arn"])
    assert(conflicts[0].explanation.contains("~/.aws/config"))
}

func testCLIToolRequirementsCoverEachProfileShape() throws {
    assert(CLITool.required(for: CloudProfile(provider: .aws, name: "dev")) == [.aws])
    assert(CLITool.required(for: CloudProfile(provider: .gcp, name: "dev")) == [.gcloud])
    assert(CLITool.required(for: CloudProfile(provider: .azure, name: "dev")) == [.az])

    let plainKube = CloudProfile(provider: .kubernetes, name: "dev-context")
    assert(CLITool.required(for: plainKube) == [.kubectl])

    // A broker-fronted context needs its broker's CLI on top of kubectl.
    let sdmKube = CloudProfile(provider: .kubernetes, name: "sdm-cluster", roleName: "sdm-" + "user")
    assert(sdmKube.usesStrongDM ? CLITool.required(for: sdmKube) == [.kubectl, .sdm] : true)

    assert(CLITool.aws.installCommand == "brew install awscli")
    assert(CLITool.gcloud.installCommand == "brew install --cask google-cloud-sdk")
    // StrongDM ships no Homebrew package — the sheet must fall back to its page.
    assert(CLITool.sdm.installCommand == "brew install --cask sdm")

    assert(CLIToolPaths.resolve("definitely-not-a-real-cli-xyz") == nil)
    assert(CLIToolPaths.resolve("ls") != nil)
    assert(CLIToolPaths.dirs(fromPathVariable: "/a:/b") == ["/a", "/b"])
    assert(CLIToolPaths.searchDirs.contains("/opt/homebrew/bin"))
}

func testAWSSSOTokenStateDistinguishesInteractiveLoginFromSilentRefresh() throws {
    let now = ISO8601DateFormatter().date(from: "2026-08-12T10:00:00Z")!
    let later = now.addingTimeInterval(3600)
    let earlier = now.addingTimeInterval(-3600)

    assert(AWSSessionExpirationService.tokenState(expiresAt: later, refreshToken: nil, registrationExpiresAt: nil, now: now) == .valid(later))
    // Expiring inside the slack window is not "valid".
    assert(AWSSessionExpirationService.tokenState(expiresAt: now.addingTimeInterval(30), refreshToken: "r", registrationExpiresAt: later, now: now) == .refreshable)
    assert(AWSSessionExpirationService.tokenState(expiresAt: earlier, refreshToken: "r", registrationExpiresAt: later, now: now) == .refreshable)
    assert(AWSSessionExpirationService.tokenState(expiresAt: earlier, refreshToken: "r", registrationExpiresAt: earlier, now: now) == .needsInteractive)
    assert(AWSSessionExpirationService.tokenState(expiresAt: earlier, refreshToken: nil, registrationExpiresAt: later, now: now) == .needsInteractive)
    assert(AWSSessionExpirationService.tokenState(expiresAt: nil, refreshToken: nil, registrationExpiresAt: nil, now: now) == .needsInteractive)

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-sso-state-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try """
    {"startUrl":"https://example.awsapps.com/start","expiresAt":"2026-08-12T09:00:00Z","refreshToken":"r","registrationExpiresAt":"2026-11-12T09:00:00Z"}
    """.write(to: dir.appendingPathComponent("token.json"), atomically: true, encoding: .utf8)

    let service = AWSSessionExpirationService(credentialsURL: dir.appendingPathComponent("credentials"), ssoCacheURL: dir)
    let profile = CloudProfile(provider: .aws, name: "dev", ssoStartURL: "https://example.awsapps.com/start")
    assert(service.ssoTokenState(for: profile, now: now) == .refreshable)

    let unknown = CloudProfile(provider: .aws, name: "other", ssoStartURL: "https://other.awsapps.com/start")
    assert(service.ssoTokenState(for: unknown, now: now) == .needsInteractive)
}

func testAWSCredentialServiceParsesIdentityAndCredentials() throws {
    let service = AWSCredentialService()
    let identity = service.identity(fromCallerIdentityOutput: #"{"Arn":"arn:aws:sts::123456789012:assumed-role/Admin/dev@example.com","Account":"123456789012"}"#)
    let exported = try AWSCredentialService.parseExportedCredentials(#"{"AccessKeyId":"AKIAEXAMPLE","SecretAccessKey":"secret","SessionToken":"token","Expiration":"2026-07-04T12:34:56Z"}"#)

    assert(identity == "dev@example.com")
    assert(exported.accessKeyId == "AKIAEXAMPLE")
    assert(exported.secretAccessKey == "secret")
    assert(exported.sessionToken == "token")
    assert(exported.expiration == "2026-07-04T12:34:56Z")
}

func testAWSCredentialServiceRemovesOnlyCTXExportedTemporarySections() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-credential-cleanup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("config")
    let credentialsURL = directory.appendingPathComponent("credentials")
    try """
    [profile tracked]
    sso_session = tracked
    [profile legacy]
    sso_start_url = https://example.awsapps.com/start
    [profile unrelated-session]
    region = us-east-1
    """.write(to: configURL, atomically: true, encoding: .utf8)
    try """
    [static]
    aws_access_key_id = STATIC
    aws_secret_access_key = static-secret
    [legacy]
    aws_access_key_id = LEGACY
    aws_secret_access_key = legacy-secret
    aws_session_token = legacy-token
    aws_session_expiration = 2026-08-20T20:00:00Z
    [unrelated-session]
    aws_access_key_id = OTHER
    aws_secret_access_key = other-secret
    aws_session_token = other-token
    aws_session_expiration = 2026-08-20T20:00:00Z
    """.write(to: credentialsURL, atomically: true, encoding: .utf8)
    let service = AWSCredentialService(configURL: configURL, credentialsURL: credentialsURL)

    _ = try service.storeExportedCredentials(
        #"{"AccessKeyId":"TRACKED","SecretAccessKey":"tracked-secret","SessionToken":"tracked-token"}"#,
        profileName: "tracked"
    )
    try service.clearExportedTemporaryCredentials()

    let credentials = try String(contentsOf: credentialsURL, encoding: .utf8)
    assert(!credentials.contains("[tracked]"))
    assert(!credentials.contains("[default]"))
    assert(!credentials.contains("[legacy]"))
    assert(credentials.contains("[static]"))
    assert(credentials.contains("[unrelated-session]"))
    assert(!FileManager.default.fileExists(
        atPath: credentialsURL.appendingPathExtension("ctx-exported-profiles.json").path
    ))
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    assert(!files.contains { $0.contains("ctx-backup") }, "credential cleanup must not copy secrets into backups")
}

func testAWSCredentialCleanupPreservesReplacedLongLivedKeys() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-credential-replaced-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("config")
    let credentialsURL = directory.appendingPathComponent("credentials")
    try "[profile tracked]\nsso_session = tracked\n".write(
        to: configURL,
        atomically: true,
        encoding: .utf8
    )
    let service = AWSCredentialService(configURL: configURL, credentialsURL: credentialsURL)
    _ = try service.storeExportedCredentials(
        #"{"AccessKeyId":"TEMP","SecretAccessKey":"temporary","SessionToken":"session"}"#,
        profileName: "tracked"
    )
    try """
    [tracked]
    aws_access_key_id = LONG_LIVED
    aws_secret_access_key = preserved-secret
    """.write(to: credentialsURL, atomically: true, encoding: .utf8)

    try service.clearExportedTemporaryCredentials()

    let credentials = try String(contentsOf: credentialsURL, encoding: .utf8)
    assert(credentials.contains("[tracked]"))
    assert(credentials.contains("LONG_LIVED"))
    assert(!FileManager.default.fileExists(
        atPath: credentialsURL.appendingPathExtension("ctx-exported-profiles.json").path
    ))
}

func testCloudProfilePersistenceServiceWritesAWSProfile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-profile-persistence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let configURL = dir.appendingPathComponent("config")
    let service = CloudProfilePersistenceService(awsConfigURL: configURL)
    var draft = AWSProfileDraft()
    draft.name = "dev"
    draft.ssoStartURL = "https://example.awsapps.com/start"
    draft.ssoRegion = "us-east-1"
    draft.accountID = "123456789012"
    draft.roleName = "Developer"
    draft.defaultRegion = "us-west-2"

    try service.addAWSProfile(draft)
    let added = try String(contentsOf: configURL, encoding: .utf8)
    assert(added.contains("[profile dev]"))
    assert(added.contains("sso_account_id = 123456789012"))

    try service.deleteAWSProfile("dev")
    let deleted = try String(contentsOf: configURL, encoding: .utf8)
    assert(!deleted.contains("[profile dev]"))
}

func testProfileStoreAddsAWSProfileIntoVisibleStateImmediately() async throws {
    try await MainActor.run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-profile-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("aws-config")
        let credentialsURL = dir.appendingPathComponent("aws-credentials")
        let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
        try "apiVersion: v1\nkind: Config\n".write(to: kubeconfigURL, atomically: true, encoding: .utf8)

        let suiteName = "ctx-profile-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runner = RecordingCloudRunner()
        let store = ProfileStore(
            configURL: configURL,
            runner: runner,
            kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
            profileCommands: ProfileCommandService(runner: runner),
            updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
            awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: credentialsURL),
            profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
            fileWatchers: ProfileFileWatcherService(),
            folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
            startsBackgroundServices: false
        )

        var draft = AWSProfileDraft()
        draft.name = "dev"
        draft.ssoStartURL = "https://example.awsapps.com/start"
        draft.ssoRegion = "us-east-1"
        draft.accountID = "123456789012"
        draft.roleName = "Developer"
        draft.defaultRegion = "us-west-2"

        try store.addAWSProfile(draft)

        assert(store.profiles.contains { $0.provider == .aws && $0.name == "dev" })
        assert(store.selectedProfile?.name == "dev")
        assert(store.activeAWSProfile == "dev")
    }
}

@MainActor
func testProfileStoreAddsCloudProfilesIntoTargetFolders() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-profile-folders-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let oldGCPPath = UserDefaults.standard.string(forKey: "customGCPConfigDirPath")
    let oldAzurePath = UserDefaults.standard.string(forKey: "customAzureProfilesDirPath")
    UserDefaults.standard.set(dir.appendingPathComponent("gcloud").path, forKey: "customGCPConfigDirPath")
    UserDefaults.standard.set(dir.appendingPathComponent("azure").path, forKey: "customAzureProfilesDirPath")
    defer {
        if let oldGCPPath {
            UserDefaults.standard.set(oldGCPPath, forKey: "customGCPConfigDirPath")
        } else {
            UserDefaults.standard.removeObject(forKey: "customGCPConfigDirPath")
        }
        if let oldAzurePath {
            UserDefaults.standard.set(oldAzurePath, forKey: "customAzureProfilesDirPath")
        } else {
            UserDefaults.standard.removeObject(forKey: "customAzureProfilesDirPath")
        }
    }

    let suiteName = "ctx-profile-folders-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let runner = RecordingCloudRunner()
    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try "apiVersion: v1\nkind: Config\n".write(to: kubeconfigURL, atomically: true, encoding: .utf8)
    let store = ProfileStore(
        configURL: dir.appendingPathComponent("aws-config"),
        runner: runner,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: dir.appendingPathComponent("aws-config"), credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: dir.appendingPathComponent("aws-config")),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )

    var aws = AWSProfileDraft()
    aws.name = " cloud-alpha "
    aws.ssoStartURL = "https://example.awsapps.com/start"
    aws.ssoRegion = "us-east-1"
    aws.accountID = "123456789012"
    aws.roleName = "Developer"
    aws.defaultRegion = "us-west-2"
    try store.addAWSProfile(aws, targetFolder: CloudFolder.builtIn(provider: .aws, environment: .data))

    var gcp = GCPProfileDraft()
    gcp.name = " cloud-beta "
    gcp.project = "example-project-123456"
    gcp.account = "user@example.com"
    try store.addGCPProfile(gcp, targetFolder: CloudFolder.builtIn(provider: .gcp, environment: .development))

    var azure = AzureProfileDraft()
    azure.name = " cloud-gamma "
    azure.subscriptionID = "00000000-0000-0000-0000-000000000000"
    try store.addAzureProfile(azure, targetFolder: CloudFolder.builtIn(provider: .azure, environment: .production))

    assert(store.folderOverrides["AWS:cloud-alpha"] == "AWS:Data")
    assert(store.folderOverrides["GCP:cloud-beta"] == "GCP:Development")
    assert(store.folderOverrides["Azure:cloud-gamma"] == "Azure:Production")
}

@MainActor
func testProfileStoreKeepsKubeContextTargetFolderBeforeDiscoveryCatchesUp() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-folder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let configURL = dir.appendingPathComponent("aws-config")
    let credentialsURL = dir.appendingPathComponent("aws-credentials")
    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try "apiVersion: v1\nkind: Config\n".write(to: kubeconfigURL, atomically: true, encoding: .utf8)

    let suiteName = "ctx-kube-folder-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let runner = RecordingCloudRunner()
    let kubectl = ScriptedKubectl()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigMutations: KubeConfigMutationService(kubectl: kubectl),
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: credentialsURL),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )
    let targetFolder = CloudFolder.builtIn(provider: .kubernetes, environment: .development)

    try await store.addKubeContext(
        name: " internal-dev ",
        server: " https://127.0.0.1:8443 ",
        cluster: " internal-dev ",
        user: "",
        namespace: "default",
        credential: .internalProxy,
        targetFolder: targetFolder
    )

    assert(store.folderOverrides["Kubernetes:internal-dev"] == targetFolder.id)
    assert(CloudFolderPreferencesStore(defaults: defaults).load().folderOverrides["Kubernetes:internal-dev"] == targetFolder.id)
}

@MainActor
func testProfileStoreDuplicatesKubeContextWithoutMutatingSourceAndInheritsFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-duplicate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try kubeconfig(
        context: "source",
        cluster: "shared-cluster",
        user: "shared-user",
        namespace: "apps",
        server: "https://cluster.example.com"
    ).write(to: kubeconfigURL, atomically: true, encoding: .utf8)

    let suiteName = "ctx-kube-duplicate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let runner = RecordingCloudRunner()
    let kubectl = ScriptedKubectl()
    kubectl.onRun = { command in
        guard command.arguments.contains("set-context") else { return }
        let duplicatedConfig = """
        apiVersion: v1
        kind: Config
        current-context: source
        clusters:
        - name: shared-cluster
          cluster:
            server: https://cluster.example.com
        contexts:
        - name: source
          context:
            cluster: shared-cluster
            user: shared-user
            namespace: apps
        - name: source-copy
          context:
            cluster: shared-cluster
            user: shared-user
            namespace: apps
        users:
        - name: shared-user
          user: {}
        """
        try! duplicatedConfig.write(to: kubeconfigURL, atomically: true, encoding: .utf8)
    }
    let store = ProfileStore(
        configURL: dir.appendingPathComponent("aws-config"),
        runner: runner,
        kubeConfigMutations: KubeConfigMutationService(kubectl: kubectl),
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: dir.appendingPathComponent("aws-config"), credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: dir.appendingPathComponent("aws-config")),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )
    let source = store.profiles.first { $0.provider == .kubernetes && $0.name == "source" }!
    let sourceSnapshot = source
    let sourceContextSnapshot = store.kubernetesContexts.first { $0.contextName == "source" }!
    let folder = CloudFolder.builtIn(provider: .kubernetes, environment: .development)
    store.move(source, to: folder)

    assert(store.suggestedKubeContextDuplicateName(for: source) == "source-copy")
    try await store.duplicateKubeContext(source, newName: " source-copy ")

    let duplicate = store.profiles.first { $0.provider == .kubernetes && $0.name == "source-copy" }!
    assert(duplicate.id != source.id)
    assert(duplicate.accountID == source.accountID)
    assert(duplicate.roleName == source.roleName)
    assert(duplicate.region == source.region)
    assert(store.profiles.contains(sourceSnapshot))
    assert(store.kubernetesContexts.contains(sourceContextSnapshot))
    assert(store.folderOverrides[duplicate.id] == folder.id)
    assert(store.suggestedKubeContextDuplicateName(for: source) == "source-copy-2")
    let duplicateCommands = kubectl.commands.filter { $0.arguments.contains("set-context") }
    assert(duplicateCommands.count == 1)
    assert(Array(duplicateCommands[0].arguments.prefix(2)) == ["--kubeconfig", kubeconfigURL.path])
}

@MainActor
func testKubeDuplicateRediscoveryMissDoesNotPersistFolderOverride() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-kube-duplicate-miss-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kubeconfigURL = directory.appendingPathComponent("kubeconfig")
    try kubeconfig(
        context: "source",
        cluster: "shared",
        user: "shared-user",
        server: "https://cluster.example.com"
    ).write(to: kubeconfigURL, atomically: true, encoding: .utf8)
    let suiteName = "ctx-kube-duplicate-miss-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let runner = RecordingCloudRunner()
    let discovery = KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path })
    let store = ProfileStore(
        configURL: directory.appendingPathComponent("config"),
        runner: runner,
        kubeConfigMutations: KubeConfigMutationService(kubectl: ScriptedKubectl()),
        kubeConfigDiscoveryService: discovery,
        localProfileDiscovery: LocalProfileDiscoveryService(
            awsConfigURL: directory.appendingPathComponent("config"),
            kubeConfigDiscoveryService: discovery
        ),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        defaults: defaults,
        startsBackgroundServices: false
    )
    let source = store.profiles.first { $0.name == "source" }!
    let folder = CloudFolder.builtIn(provider: .kubernetes, environment: .development)

    do {
        try await store.duplicateKubeContext(source, newName: "missing-copy", targetFolder: folder)
        assertionFailure("expected rediscovery miss")
    } catch ProfileStoreMutationError.rediscoveryMiss {
        // Expected.
    }

    assert(store.folderOverrides["Kubernetes:missing-copy"] == nil)
    assert(CloudFolderPreferencesStore(defaults: defaults).load().folderOverrides["Kubernetes:missing-copy"] == nil)
}

@MainActor
func testProfileStoreMigratesFolderMappingAfterSuccessfulCloudRename() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-cloud-rename-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let suiteName = "ctx-cloud-rename-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let configURL = dir.appendingPathComponent("aws-config")
    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )
    var draft = AWSProfileDraft()
    draft.name = "source"
    draft.ssoStartURL = "https://example.awsapps.com/start"
    draft.ssoRegion = "us-east-1"
    draft.accountID = "123456789012"
    draft.roleName = "Developer"
    draft.defaultRegion = "us-west-2"
    let folder = CloudFolder.builtIn(provider: .aws, environment: .data)
    try store.addAWSProfile(draft, targetFolder: folder)
    let source = store.profiles.first { $0.provider == .aws && $0.name == "source" }!

    draft.name = " renamed "
    try store.updateAWSProfile(source, draft: draft)

    assert(store.folderOverrides["AWS:renamed"] == folder.id)
    assert(store.folderOverrides["AWS:source"] == nil)
    let persisted = CloudFolderPreferencesStore(defaults: defaults).load().folderOverrides
    assert(persisted["AWS:renamed"] == folder.id)
    assert(persisted["AWS:source"] == nil)
}

@MainActor
func testProfileStoreRetainsFolderMappingWhenCloudPersistenceFails() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-cloud-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let suiteName = "ctx-cloud-failure-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let configURL = dir.appendingPathComponent("aws-config")
    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )
    var draft = AWSProfileDraft()
    draft.name = "source"
    draft.ssoStartURL = "https://example.awsapps.com/start"
    draft.ssoRegion = "us-east-1"
    draft.accountID = "123456789012"
    draft.roleName = "Developer"
    draft.defaultRegion = "us-west-2"
    let folder = CloudFolder.builtIn(provider: .aws, environment: .data)
    try store.addAWSProfile(draft, targetFolder: folder)
    let source = store.profiles.first { $0.provider == .aws && $0.name == "source" }!
    try FileManager.default.removeItem(at: configURL)
    try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: false)
    draft.name = "renamed"

    do {
        try store.updateAWSProfile(source, draft: draft)
        assertionFailure("Expected persistence failure")
    } catch {
        assert(store.folderOverrides[source.id] == folder.id)
        assert(CloudFolderPreferencesStore(defaults: defaults).load().folderOverrides[source.id] == folder.id)
    }
}

@MainActor
func testProfileStoreRetainsFolderMappingWhenKubeRediscoveryMissesRename() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-rename-miss-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try kubeconfig(context: "source", cluster: "source-cluster", user: "source-user", server: "https://cluster.example.com")
        .write(to: kubeconfigURL, atomically: true, encoding: .utf8)
    let suiteName = "ctx-kube-rename-miss-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: dir.appendingPathComponent("aws-config"),
        runner: runner,
        kubeConfigMutations: KubeConfigMutationService(kubectl: ScriptedKubectl()),
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: dir.appendingPathComponent("aws-config"), credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: dir.appendingPathComponent("aws-config")),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )
    let source = store.profiles.first { $0.provider == .kubernetes && $0.name == "source" }!
    let folder = CloudFolder.builtIn(provider: .kubernetes, environment: .development)
    store.move(source, to: folder)

    do {
        try await store.updateKubeContext(
            source,
            newName: " renamed ",
            server: "https://cluster.example.com",
            cluster: "source-cluster",
            user: "source-user",
            namespace: "",
            credentialUpdate: .preserveExisting
        )
        assertionFailure("Expected rediscovery miss")
    } catch {
        assert(error as? ProfileStoreMutationError == .rediscoveryMiss(provider: .kubernetes, name: "renamed"))
        assert(store.folderOverrides[source.id] == folder.id)
        assert(store.folderOverrides["Kubernetes:renamed"] == nil)
        assert(CloudFolderPreferencesStore(defaults: defaults).load().folderOverrides[source.id] == folder.id)
    }
}

@MainActor
func testProfileStorePromptsForFolderWhenCreatedWithoutOne() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-folder-prompt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let configURL = dir.appendingPathComponent("aws-config")
    let credentialsURL = dir.appendingPathComponent("aws-credentials")
    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try "apiVersion: v1\nkind: Config\n".write(to: kubeconfigURL, atomically: true, encoding: .utf8)

    let suiteName = "ctx-folder-prompt-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let runner = RecordingCloudRunner()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: credentialsURL),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )
    func pendingFolder() -> CloudProfile? {
        guard case .pendingFolderAssignment(let profile) = store.presentation?.route else { return nil }
        return profile
    }

    assert(pendingFolder() == nil, "no prompt before anything is created")

    var aws = AWSProfileDraft()
    aws.name = "unfiled-profile"
    aws.ssoStartURL = "https://example.awsapps.com/start"
    aws.ssoRegion = "us-east-1"
    aws.accountID = "123456789012"
    aws.roleName = "Developer"
    aws.defaultRegion = "us-west-2"

    // Created with no targetFolder — must prompt for one instead of silently
    // landing in the generic default folder.
    try store.addAWSProfile(aws)
    // Generous: this waits on a detached Task scheduling a subprocess call, which can
    // take well over a second on a loaded machine. A tight deadline here fails as a
    // wrong-kubeconfig assertion rather than as the timeout it actually is.
    let deadline = Date().addingTimeInterval(10)
    while pendingFolder() == nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    assert(pendingFolder()?.name == "unfiled-profile", "must offer a folder for a profile created outside any folder")

    store.dismissPresentation(from: .mainWindow)

    var filed = AWSProfileDraft()
    filed.name = "filed-profile"
    filed.ssoStartURL = "https://example.awsapps.com/start"
    filed.ssoRegion = "us-east-1"
    filed.accountID = "123456789012"
    filed.roleName = "Developer"
    filed.defaultRegion = "us-west-2"

    // Created with an explicit targetFolder — must not prompt again.
    try store.addAWSProfile(filed, targetFolder: CloudFolder.builtIn(provider: .aws, environment: .data))
    try await Task.sleep(nanoseconds: 300_000_000)
    assert(pendingFolder() == nil, "must not prompt when a folder was already chosen at creation time")

    store.presentProfileEditor(.selectProvider(targetFolder: nil), from: .mainWindow)
    var guarded = aws
    guarded.name = "guarded-unfiled-profile"
    try store.addAWSProfile(guarded)
    store.report("newer route", from: .mainWindow)
    try await Task.sleep(nanoseconds: 100_000_000)
    guard case .pendingFolderAssignment = store.presentation?.route else {
        return
    }
    assertionFailure("a deferred folder prompt must not overwrite a newer route")
}

@MainActor
func testProfileStoreTargetsContextsOwnKubeconfigFileNotJustThePrimaryOne() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-logout-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Two-file KUBECONFIG where the context under test lives only in the SECOND
    // file — the primary/first candidate path has no contexts at all. Any call
    // that falls back to "the primary path" instead of resolving this context's
    // actual file would silently operate on the wrong (empty) file.
    let primary = dir.appendingPathComponent("primary")
    let secondary = dir.appendingPathComponent("secondary")
    try "apiVersion: v1\nkind: Config\n".write(to: primary, atomically: true, encoding: .utf8)
    try kubeconfig(context: "team-b", cluster: "team-b-cluster", user: "team-b-user", server: "https://team-b.example.com:6443")
        .write(to: secondary, atomically: true, encoding: .utf8)

    let env = ["KUBECONFIG": "\(primary.path):\(secondary.path)"]
    let suiteName = "ctx-kube-logout-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let configURL = dir.appendingPathComponent("aws-config")
    let runner = RecordingCloudRunner()
    let kubectl = ScriptedKubectl()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigMutations: KubeConfigMutationService(kubectl: kubectl),
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { env }, customPath: { nil }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        startsBackgroundServices: false
    )

    guard let profile = store.profiles.first(where: { $0.provider == .kubernetes && $0.name == "team-b" }) else {
        assertionFailure("expected discovery to find the team-b context")
        return
    }

    store.logout(profile)
    await waitForLifecycleCondition("ordinary Kubernetes disconnect") {
        store.profiles.first(where: { $0.id == profile.id })?.status != .disconnecting
    }
    assert(kubectl.commands.isEmpty, "ordinary Kubernetes disconnect must not mutate current-context")

    _ = await store.resolveKubeServer(for: "team-b-cluster", contextName: "team-b")
    assert(Array(kubectl.commands.last?.arguments.prefix(2) ?? []) == ["--kubeconfig", secondary.path], "resolving the server for an existing context's edit form must target that context's own file, not the primary KUBECONFIG entry")
}

@MainActor
func testProfileStoreLoginActuallySwitchesKubeContextEvenWhenStatusWasUnknown() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-login-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try kubeconfig(context: "team-c", cluster: "team-c-cluster", user: "team-c-user", server: "https://team-c.example.com:6443")
        .write(to: kubeconfigURL, atomically: true, encoding: .utf8)

    let suiteName = "ctx-kube-login-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let configURL = dir.appendingPathComponent("aws-config")
    let runner = RecordingCloudRunner()
    let kubectl = ScriptedKubectl()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigMutations: KubeConfigMutationService(kubectl: kubectl),
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        // What this test proves is the context switch, not whether the host has
        // kubectl. Left to the real preflight it passes on a developer Mac and
        // fails on a CI runner without kubectl, where `login()` returns early.
        missingCLIToolResolver: { _ in nil },
        // Mirrors real app startup: contexts are discovered before the background
        // verify pass has run, so a never-yet-verified context sits at `.unknown` —
        // exactly the state that used to make `login()` skip the real context switch.
        startsBackgroundServices: false
    )

    guard let profile = store.profiles.first(where: { $0.provider == .kubernetes && $0.name == "team-c" }) else {
        assertionFailure("expected discovery to find the team-c context")
        return
    }
    assert(profile.status == .unknown, "test only proves what it claims if the profile truly starts unverified")

    store.login(profile)
    // Generous: this waits on a detached Task scheduling a subprocess call, which can
    // take well over a second on a loaded machine. A tight deadline here fails as a
    // wrong-kubeconfig assertion rather than as the timeout it actually is.
    let deadline = Date().addingTimeInterval(10)
    while !kubectl.commands.contains(where: { $0.arguments.contains("use-context") }), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    assert(kubectl.commands.contains {
        $0.arguments.contains("use-context") && $0.arguments.contains("team-c")
    }, "Connect on a never-yet-verified kube context must still run the real kubectl context switch, not just update in-app bookkeeping")
}

/// The other side of the injected preflight: a resolver that does report a missing
/// tool must still stop the connect before any command runs, so making the switch
/// test host-independent cannot quietly disable the preflight itself.
@MainActor
func testProfileStoreLoginStopsAtPreflightWhenARequiredCLIIsMissing() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-kube-preflight-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let kubeconfigURL = dir.appendingPathComponent("kubeconfig")
    try kubeconfig(context: "team-d", cluster: "team-d-cluster", user: "team-d-user", server: "https://team-d.example.com:6443")
        .write(to: kubeconfigURL, atomically: true, encoding: .utf8)

    let suiteName = "ctx-kube-preflight-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let configURL = dir.appendingPathComponent("aws-config")
    let runner = RecordingCloudRunner()
    let kubectl = ScriptedKubectl()
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigMutations: KubeConfigMutationService(kubectl: kubectl),
        kubeConfigDiscoveryService: KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path }),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(configURL: configURL, credentialsURL: dir.appendingPathComponent("aws-credentials")),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        missingCLIToolResolver: { _ in .kubectl },
        startsBackgroundServices: false
    )

    guard let profile = store.profiles.first(where: { $0.provider == .kubernetes && $0.name == "team-d" }) else {
        assertionFailure("expected discovery to find the team-d context")
        return
    }

    store.login(profile)
    guard case .missingCLI(let request) = store.presentation?.route else {
        assertionFailure("a missing required CLI must surface as an install request")
        return
    }
    assert(request.tool == .kubectl, "the install request must identify kubectl")
    assert(request.profile.id == profile.id, "the install request must name the profile the user tried to connect")

    // Long enough that a connect Task, had one been spawned, would have recorded
    // its command by now.
    try await Task.sleep(nanoseconds: 300_000_000)
    assert(!kubectl.commands.contains { $0.arguments.contains("use-context") }, "a blocked preflight must run no kubectl commands at all")
}

func testCloudFolderPreferencesStoreRoundTripsState() throws {
    let suiteName = "ctx-folder-prefs-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        assertionFailure("Could not create test defaults")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = CloudFolderPreferencesStore(defaults: defaults)
    let custom = CloudFolder(id: "AWS:custom:team", provider: .aws, name: "Team", icon: .shield)
    let builtIn = CloudFolder(id: "AWS:Production", provider: .aws, name: "Prod", icon: .server, isCustom: false)

    store.saveCustomFolders([custom])
    store.saveFolderCustomizations([builtIn.id: builtIn])
    store.saveFolderOverrides(["AWS:dev": custom.id])
    store.saveHiddenFolderIDs([CloudFolder.builtIn(provider: .aws, environment: .other).id])

    let state = store.load()
    assert(state.customFolders == [custom])
    assert(state.folderCustomizations[builtIn.id] == builtIn)
    assert(state.folderOverrides["AWS:dev"] == custom.id)
    assert(state.hiddenFolderIDs == ["AWS:Other"])
}

func testOpenSourceFixturesStayGeneric() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    // Directories, not a list of filenames: the previous version named each doc
    // individually, so moving or adding one silently dropped it from the scan.
    let scannedPaths = [
        root.appendingPathComponent("Sources"),
        root.appendingPathComponent("docs"),
        root.appendingPathComponent("README.md"),
        root.appendingPathComponent("AGENTS.md")
    ]
    let blocked = [
        ["access", "hub"],
        ["monitoring", "-", "prod"],
        ["ip", "-", "10"],
        ["j", "frog"],
        ["AWS", "-", "it", "-", "admin"],
        ["it", "services"],
        ["s", "d", "m", "-", "user"],
        ["it", "-", "admin"],
        ["sell", "er"],
        ["p", "2", "p"],
        ["s", "d", "m", "-", "prod"]
    ].map { $0.joined() }

    for path in scannedPaths where FileManager.default.fileExists(atPath: path.path) {
        for file in try textFiles(under: path) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in blocked {
                assert(!text.localizedCaseInsensitiveContains(token), "Private fixture token \(token) found in \(file.path)")
            }
        }
    }
}

func testLocalAuditLogRedactsSensitiveMessages() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-audit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("audit.jsonl")
    let audit = LocalAuditLogService(fileURL: url)
    try audit.record(AuditEvent(type: .kubectlCommandFailed, contextName: "prod", message: "bearer token leaked"))

    let text = try String(contentsOf: url, encoding: .utf8)
    assert(text.contains("[redacted]"))
    assert(!text.localizedCaseInsensitiveContains("bearer token leaked"))
}

/// Fake `KubernetesResourceReading` for `ResourceRefreshCoordinator` tests — counts
/// live calls, records their keys, and can simulate a slow response (to test
/// dedup of concurrent requests) or a scripted result (to test failure handling).



@MainActor
func testKubernetesContextStatusUpdatesOnVerificationFailureAndExpiration() async throws {
    let store = ProfileStore(startsBackgroundServices: false)
    store.markKubernetesContextNeedsLogin(contextName: "non-existent-context", reason: "API Down")
}

func testHPAAndPVCResourceKinds() throws {
    assert(KubernetesResourceKind.hpa.title == "HPA")
    assert(KubernetesResourceKind.pvc.title == "Storage (PVC)")
    assert(KubernetesResourceKind.hpa.supportsInspectionYAML)
    assert(KubernetesResourceKind.pvc.supportsInspectionYAML)
}



@MainActor
func runCloudProfileStoreTests() async throws {
    await testProfileCommandServiceBuildsProviderCommands()
    await testProfileCommandServiceReadsProviderPathsPerCommand()
    try await testProfileStoreReloadsLiveAWSPathAndSharesCommandDefaults()
    await testKubernetesVerificationPreservesContextPathAndProviderEnvironment()
    await testProfileCommandServiceRedactsFailedOutput()
    await testProfileCommandServiceStrongDMLoginAndVerify()
    try testCTXUpdateServiceParsesReleaseAndComparesVersions()
    try testAWSSessionExpirationServicePrefersCredentialsExpiry()
    try testAWSCredentialsFileAuditFlagsConfigKeysThatOverrideTheConfigFile()
    try testCLIToolRequirementsCoverEachProfileShape()
    try testAWSSSOTokenStateDistinguishesInteractiveLoginFromSilentRefresh()
    try testAWSCredentialServiceParsesIdentityAndCredentials()
    try testAWSCredentialServiceRemovesOnlyCTXExportedTemporarySections()
    try testAWSCredentialCleanupPreservesReplacedLongLivedKeys()
    try testCloudProfilePersistenceServiceWritesAWSProfile()
    try await testProfileStoreAddsAWSProfileIntoVisibleStateImmediately()
    try testProfileStoreAddsCloudProfilesIntoTargetFolders()
    try await testProfileStoreKeepsKubeContextTargetFolderBeforeDiscoveryCatchesUp()
    try await testProfileStoreDuplicatesKubeContextWithoutMutatingSourceAndInheritsFolder()
    try await testKubeDuplicateRediscoveryMissDoesNotPersistFolderOverride()
    try testProfileStoreMigratesFolderMappingAfterSuccessfulCloudRename()
    try testProfileStoreRetainsFolderMappingWhenCloudPersistenceFails()
    try await testProfileStoreRetainsFolderMappingWhenKubeRediscoveryMissesRename()
    try await testProfileStorePromptsForFolderWhenCreatedWithoutOne()
    try await testProfileStoreTargetsContextsOwnKubeconfigFileNotJustThePrimaryOne()
    try await testProfileStoreLoginActuallySwitchesKubeContextEvenWhenStatusWasUnknown()
    try await testProfileStoreLoginStopsAtPreflightWhenARequiredCLIIsMissing()
    try await testKubernetesContextStatusUpdatesOnVerificationFailureAndExpiration()
    try testHPAAndPVCResourceKinds()
    try testCloudFolderPreferencesStoreRoundTripsState()
    try testOpenSourceFixturesStayGeneric()
}
