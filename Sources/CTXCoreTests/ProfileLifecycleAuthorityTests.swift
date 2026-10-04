import CTXCore
import Foundation

@MainActor
private func makeAuthorityStore(
    configURL: URL,
    defaults: UserDefaults,
    runner: any CloudCommandRunning
) -> ProfileStore {
    let directory = configURL.deletingLastPathComponent()
    let kubeDiscovery = KubeConfigDiscoveryService(
        environment: { [:] },
        customPath: { directory.appendingPathComponent("missing-kubeconfig").path }
    )
    return ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigDiscoveryService: kubeDiscovery,
        localProfileDiscovery: LocalProfileDiscoveryService(
            awsConfigURL: configURL,
            kubeConfigDiscoveryService: kubeDiscovery,
            gcpConfigurationsDirURL: { directory.appendingPathComponent("missing-gcp") },
            gcpActiveConfigURL: { directory.appendingPathComponent("missing-gcp/active_config") },
            azureProfilesDirURL: { directory.appendingPathComponent("missing-azure") }
        ),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsSessionExpirations: AWSSessionExpirationService(
            credentialsURL: directory.appendingPathComponent("credentials"),
            ssoCacheURL: directory.appendingPathComponent("missing-sso-cache")
        ),
        awsCredentials: AWSCredentialService(
            configURL: configURL,
            credentialsURL: directory.appendingPathComponent("credentials")
        ),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        missingCLIToolResolver: { _ in nil },
        defaults: defaults,
        startsBackgroundServices: false
    )
}

@MainActor
func testVerificationDoesNotSelectProfileWithoutCTXIntent() async throws {
    let runner = LifecycleGateRunner()
    let (store, directory, defaults, suiteName) = try makeLifecycleStore(
        profileNames: ["alpha"],
        runner: runner
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let profile = store.profiles.first!

    let verification = Task {
        await store.verify(profile, isManualAttempt: true)
    }
    await runner.waitForCommandCount(1)
    await runner.releaseCommand(
        0,
        result: CommandResult(exitCode: 0, output: #"{"Account":"123456789012"}"#)
    )
    let verified = await verification.value

    assert(verified)
    assert(store.profiles.first?.status == .connected)
    assert(store.activeAWSProfile.isEmpty, "verification selected an AWS profile without CTX user intent")
    assert(store.activeProfile(for: .aws) == nil, "a connected provider session was treated as CTX-active")
    assert(!store.isActive(profile), "profile became active without CTX user intent")
}

@MainActor
func testManualDisconnectRemainsAuthoritativeAfterRestart() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-authority-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("config")
    try """
    [profile alpha]
    sso_start_url = https://alpha.example.com/start
    sso_region = us-east-1
    sso_account_id = 123456789012
    sso_role_name = Developer
    """.write(to: configURL, atomically: true, encoding: .utf8)
    let suiteName = "ctx-authority-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("alpha", forKey: "activeAWSProfile")
    let runner = LifecycleGateRunner()

    let firstStore = makeAuthorityStore(configURL: configURL, defaults: defaults, runner: runner)
    let firstProfile = firstStore.profiles.first!
    firstStore.logout(firstProfile)
    await waitForLifecycleCondition("persisted manual disconnect") {
        firstStore.profiles.first?.status == .needsLogin
    }

    let restartedStore = makeAuthorityStore(configURL: configURL, defaults: defaults, runner: runner)
    let restartedProfile = restartedStore.profiles.first!
    let verified = await restartedStore.verify(restartedProfile, isManualAttempt: true)
    let commands = await runner.allCommands()
    assert(commands.isEmpty, "verification after Disconnect must not contact providers")

    assert(!verified, "provider session overrode a persisted CTX disconnect")
    assert(restartedStore.profiles.first?.status == .needsLogin)
    assert(restartedStore.activeAWSProfile.isEmpty)
}

@MainActor
func testManualDisconnectSurvivesProfileRename() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-authority-rename-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("config")
    try """
    [profile alpha]
    sso_start_url = https://alpha.example.com/start
    sso_region = us-east-1
    sso_account_id = 123456789012
    sso_role_name = Developer
    """.write(to: configURL, atomically: true, encoding: .utf8)
    let suiteName = "ctx-authority-rename-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let runner = RecordingCloudRunner()
    await runner.setDefault(
        CommandResult(exitCode: 0, output: #"{"Account":"123456789012"}"#)
    )

    let store = makeAuthorityStore(configURL: configURL, defaults: defaults, runner: runner)
    let profile = store.profiles.first!
    store.logout(profile)
    await waitForLifecycleCondition("manual disconnect before profile rename") {
        store.profiles.first?.status == .needsLogin
    }

    var draft = AWSProfileDraft(profile: profile)
    draft.name = "beta"
    try store.updateAWSProfile(profile, draft: draft)
    await waitForLifecycleCondition("renamed disconnected profile") {
        store.profiles.first(where: { $0.name == "beta" })?.status == .needsLogin
    }

    let restartedStore = makeAuthorityStore(configURL: configURL, defaults: defaults, runner: runner)
    let renamedProfile = restartedStore.profiles.first { $0.name == "beta" }!
    let verified = await restartedStore.verify(renamedProfile, isManualAttempt: true)

    assert(!verified, "profile rename discarded the persisted CTX disconnect")
    assert(restartedStore.profiles.first?.status == .needsLogin)
}

@MainActor
func runProfileLifecycleAuthorityTests() async throws {
    try await testVerificationDoesNotSelectProfileWithoutCTXIntent()
    try await testManualDisconnectRemainsAuthoritativeAfterRestart()
    try await testManualDisconnectSurvivesProfileRename()
}
