import CTXCore
import Foundation

@MainActor
func testRapidConnectsRunOneEffectiveCommandFlow() async throws {
    let runner = LifecycleGateRunner()
    let (store, directory, defaults, suiteName) = try makeLifecycleStore(profileNames: ["alpha"], runner: runner)
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let profile = store.profiles.first!

    store.login(profile)
    await runner.waitForCommandCount(1)
    store.login(profile)
    let commands = await runner.allCommands()
    assert(commands.filter { Array($0.prefix(3)) == ["aws", "sso", "login"] }.count == 1)

    await runner.releaseCommand(0, result: CommandResult(exitCode: 0, output: "login complete"))
    await runner.waitForCommandCount(2)
    await runner.releaseCommand(1, result: CommandResult(exitCode: 1, output: "not authenticated"))
}

@MainActor
func testDisconnectSupersedesLateConnectResult() async throws {
    let runner = LifecycleGateRunner()
    let (store, directory, defaults, suiteName) = try makeLifecycleStore(profileNames: ["alpha"], runner: runner)
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let profile = store.profiles.first!

    store.login(profile)
    await runner.waitForCommandCount(1)
    store.logout(profile)
    await runner.releaseCommand(0, result: CommandResult(exitCode: 0, output: "late login success"))
    await waitForLifecycleCondition("disconnect superseding a late connect") {
        store.profiles.first?.status != .disconnecting
    }

    let commands = await runner.allCommands()
    assert(!commands.contains { $0.starts(with: ["aws", "sso", "logout"]) })
    assert(store.profiles.first?.status == .needsLogin)
    assert(store.activeAWSProfile.isEmpty)
}

@MainActor
func testCancelledAWSActivationCannotRestoreClearedDefaultProfile() async throws {
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

    store.setActive(profile)
    store.clearActive(for: .aws)
    await Task.yield()

    let config = try String(contentsOf: directory.appendingPathComponent("config"), encoding: .utf8)
    assert(!config.contains("[default]"), "cancelled activation recreated the cleared AWS default profile")
    assert(store.activeAWSProfile.isEmpty)
}

@MainActor
func testAWSActivationNeverExportsOrWritesDefaultCredentials() async throws {
    let runner = LifecycleGateRunner()
    let (store, directory, defaults, suiteName) = try makeLifecycleStore(
        profileNames: ["alpha", "beta"],
        runner: runner,
        activeAWSProfile: "alpha"
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let beta = store.profiles.first { $0.name == "beta" }!

    store.setActive(beta)
    await runner.waitForCommandCount(1)
    await runner.releaseCommand(
        0,
        result: CommandResult(exitCode: 0, output: #"{"Account":"123456789012"}"#)
    )
    await waitForLifecycleCondition("AWS activation verification") {
        store.profiles.first(where: { $0.id == beta.id })?.status == .connected
    }

    let commands = await runner.allCommands()
    assert(commands == [["aws", "sts", "get-caller-identity", "--profile", "beta", "--output", "json"]])
    let credentialsURL = directory.appendingPathComponent("credentials")
    let credentials = (try? String(contentsOf: credentialsURL, encoding: .utf8)) ?? ""
    assert(!credentials.contains("[default]"))
    assert(!credentials.contains("[beta]"))
}

@MainActor
func testAWSActiveProfileChangeSupersedesInFlightExportBeforeWrite() async throws {
    let runner = LifecycleGateRunner()
    let (store, directory, defaults, suiteName) = try makeLifecycleStore(
        profileNames: ["alpha", "beta"],
        runner: runner,
        activeAWSProfile: "alpha"
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let alpha = store.profiles.first { $0.name == "alpha" }!
    let beta = store.profiles.first { $0.name == "beta" }!

    let verification = Task {
        await store.verify(alpha, isManualAttempt: true)
    }
    await runner.waitForCommandCount(1)
    await runner.releaseCommand(
        0,
        result: CommandResult(exitCode: 0, output: #"{"Account":"123456789012"}"#)
    )
    let verified = await verification.value
    assert(verified)

    store.exportAWSCredentials(alpha)
    await runner.waitForCommandCount(2)
    store.setActive(beta)
    await runner.waitForCommandCount(3)
    await runner.releaseCommand(
        1,
        result: CommandResult(
            exitCode: 0,
            output: #"{"AccessKeyId":"STALE","SecretAccessKey":"stale-secret","SessionToken":"stale-token","Expiration":"2026-08-20T20:00:00Z"}"#
        )
    )
    await runner.releaseCommand(2, result: CommandResult(exitCode: 1, output: "not authenticated"))
    await Task.yield()
    await Task.yield()

    let credentials = (try? String(
        contentsOf: directory.appendingPathComponent("credentials"),
        encoding: .utf8
    )) ?? ""
    assert(store.activeAWSProfile == "beta")
    assert(!credentials.contains("[alpha]"))
    assert(!credentials.contains("[default]"))
}

@MainActor
func testAWSGlobalSignOutCancelsOtherOperationsAndCleansExports() async throws {
    let runner = LifecycleGateRunner()
    let (store, directory, defaults, suiteName) = try makeLifecycleStore(
        profileNames: ["alpha", "beta"],
        runner: runner,
        activeAWSProfile: "beta"
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let alpha = store.profiles.first { $0.name == "alpha" }!
    let beta = store.profiles.first { $0.name == "beta" }!

    let verification = Task {
        await store.verify(beta, isManualAttempt: true)
    }
    await runner.waitForCommandCount(1)
    await runner.releaseCommand(
        0,
        result: CommandResult(exitCode: 0, output: #"{"Account":"123456789012"}"#)
    )
    let verified = await verification.value
    assert(verified)

    store.exportAWSCredentials(beta)
    await runner.waitForCommandCount(2)
    store.requestProviderSignOut(alpha)
    guard case .providerSignOutConfirmation(let confirmation) = store.presentation?.route else {
        assertionFailure("expected AWS sign-out confirmation")
        return
    }
    store.confirmProviderSignOut(confirmation, from: .mainWindow)
    await runner.waitForCommandCount(3)
    await runner.releaseCommand(2, result: CommandResult(exitCode: 0, output: "signed out"))
    await runner.releaseCommand(
        1,
        result: CommandResult(
            exitCode: 0,
            output: #"{"AccessKeyId":"STALE","SecretAccessKey":"stale-secret","SessionToken":"stale-token"}"#
        )
    )
    while !store.activeAWSProfile.isEmpty
        || store.profiles.contains(where: { $0.provider == .aws && $0.status != .needsLogin }) {
        await Task.yield()
    }

    let credentials = (try? String(
        contentsOf: directory.appendingPathComponent("credentials"),
        encoding: .utf8
    )) ?? ""
    assert(!credentials.contains("[beta]"))
    assert(!credentials.contains("[default]"))
    let commands = await runner.allCommands()
    assert(commands.contains(["aws", "sso", "logout"]))
}

@MainActor
func testProfileOperationsRemainIndependent() async throws {
    let runner = LifecycleGateRunner()
    let (store, directory, defaults, suiteName) = try makeLifecycleStore(
        profileNames: ["alpha", "beta"],
        runner: runner
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let alpha = store.profiles.first { $0.name == "alpha" }!
    let beta = store.profiles.first { $0.name == "beta" }!
    var publications: [[String: ProfileStatus]] = []
    let cancellable = store.$profiles.dropFirst().sink { profiles in
        publications.append(Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.status) }))
    }
    defer { cancellable.cancel() }

    store.login(alpha)
    store.login(beta)
    await runner.waitForCommandCount(2)
    let commands = await runner.allCommands()
    assert(commands.contains { $0.contains("alpha") })
    assert(commands.contains { $0.contains("beta") })

    let alphaLoginIndex = commands.firstIndex { $0.contains("alpha") }!
    let betaLoginIndex = commands.firstIndex { $0.contains("beta") }!
    await runner.releaseCommand(alphaLoginIndex, result: CommandResult(exitCode: 1, output: "alpha failed"))
    await runner.releaseCommand(betaLoginIndex, result: CommandResult(exitCode: 0, output: "beta login succeeded"))
    await runner.waitForCommandCount(3)
    var allCommands = await runner.allCommands()
    let betaVerifyIndex = allCommands.firstIndex {
        $0.starts(with: ["aws", "sts", "get-caller-identity"]) && $0.contains("beta")
    }!
    await runner.releaseCommand(
        betaVerifyIndex,
        result: CommandResult(exitCode: 0, output: #"{"Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/Developer/beta"}"#)
    )
    await runner.waitForCommandCount(4)
    allCommands = await runner.allCommands()
    let betaExportIndex = allCommands.firstIndex {
        $0.starts(with: ["aws", "configure", "export-credentials"]) && $0.contains("beta")
    }!
    await runner.releaseCommand(
        betaExportIndex,
        result: CommandResult(
            exitCode: 0,
            output: #"{"AccessKeyId":"AKIATEST","SecretAccessKey":"secret","SessionToken":"token"}"#
        )
    )
    await waitForLifecycleCondition("superseding AWS login completion") {
        store.profiles.first(where: { $0.id == beta.id })?.status == .connected
    }

    assert(store.profiles.first(where: { $0.id == alpha.id })?.status == .needsLogin)
    assert(store.profiles.first(where: { $0.id == beta.id })?.status == .connected)
    assert(store.verificationErrors[beta.id] == nil)
    assert(store.awsIdentity == "beta")
    assert(publications.contains { $0[alpha.id] == .needsLogin })
    assert(!publications.contains { $0[beta.id] == .needsLogin })
}

@MainActor
func testVerificationNeverExportsAWSCredentials() async throws {
    let runner = LifecycleGateRunner()
    let (store, directory, defaults, suiteName) = try makeLifecycleStore(
        profileNames: ["alpha", "beta"],
        runner: runner,
        activeAWSProfile: "alpha"
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let profile = store.profiles.first { $0.name == "beta" }!

    let manual = Task {
        await store.verify(profile, isManualAttempt: true)
    }
    await runner.waitForCommandCount(1)
    await runner.releaseCommand(
        0,
        result: CommandResult(exitCode: 0, output: #"{"Account":"123456789012"}"#)
    )
    let manualResult = await manual.value
    assert(manualResult)

    store.verifyAllProfiles()
    await runner.waitForCommandCount(3)
    await runner.releaseCommand(
        1,
        result: CommandResult(exitCode: 0, output: #"{"Account":"123456789012"}"#)
    )
    await runner.releaseCommand(
        2,
        result: CommandResult(exitCode: 0, output: #"{"Account":"123456789012"}"#)
    )
    await waitForLifecycleCondition("background verification completion") {
        store.lastVerifiedAt != nil
    }

    let commands = await runner.allCommands()
    assert(commands.filter { $0.starts(with: ["aws", "configure", "export-credentials"]) }.isEmpty)
}

@MainActor
func testAWSLoginExportsExactlyOnce() async throws {
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

    store.login(profile)
    await runner.waitForCommandCount(1)
    await runner.releaseCommand(0, result: CommandResult(exitCode: 0, output: "login complete"))
    await runner.waitForCommandCount(2)
    await runner.releaseCommand(
        1,
        result: CommandResult(
            exitCode: 0,
            output: #"{"Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/Developer/alpha"}"#
        )
    )
    await runner.waitForCommandCount(3)
    await runner.releaseCommand(
        2,
        result: CommandResult(
            exitCode: 0,
            output: #"{"AccessKeyId":"AKIATEST","SecretAccessKey":"secret","SessionToken":"token"}"#
        )
    )
    await waitForLifecycleCondition("AWS login credential export") {
        store.profiles.first?.status == .connected
    }

    let commands = await runner.allCommands()
    assert(commands.filter { $0.starts(with: ["aws", "configure", "export-credentials"]) }.count == 1)
}

@MainActor
func testExplicitAWSExportSurfacesWriteFailure() async throws {
    let runner = LifecycleGateRunner()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-export-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (store, storeDirectory, defaults, suiteName) = try makeLifecycleStore(
        profileNames: ["alpha"],
        runner: runner,
        activeAWSProfile: "alpha",
        credentialsURL: directory
    )
    defer {
        try? FileManager.default.removeItem(at: storeDirectory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let profile = store.profiles.first!

    let verification = Task { await store.verify(profile, isManualAttempt: true) }
    await runner.waitForCommandCount(1)
    await runner.releaseCommand(
        0,
        result: CommandResult(exitCode: 0, output: #"{"Account":"123456789012"}"#)
    )
    _ = await verification.value

    store.exportAWSCredentials(profile)
    await runner.waitForCommandCount(2)
    await runner.releaseCommand(
        1,
        result: CommandResult(
            exitCode: 0,
            output: #"{"AccessKeyId":"AKIATEST","SecretAccessKey":"private-secret","SessionToken":"private-token"}"#
        )
    )
    await waitForLifecycleCondition("credential write failure presentation") {
        store.presentation != nil
    }

    let commands = await runner.allCommands()
    assert(commands.filter { $0.starts(with: ["aws", "configure", "export-credentials"]) }.count == 1)
    guard case .operationError(let error) = store.presentation?.route else {
        assertionFailure("credential write failure must be visible")
        return
    }
    assert(!error.message.contains("private-secret"))
    assert(!error.message.contains("private-token"))
}

@MainActor
func testProviderSignOutRequiresMatchingConfirmationAndPreservesFailureState() async throws {
    let runner = LifecycleGateRunner()
    let (store, directory, defaults, suiteName) = try makeLifecycleStore(
        profileNames: ["alpha"],
        runner: runner,
        activeAWSProfile: "alpha"
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let profile = store.profiles.first!
    let previousStatus = profile.status

    store.requestProviderSignOut(profile, from: .settings)
    guard case .providerSignOutConfirmation(let confirmation) = store.presentation?.route else {
        assertionFailure("provider sign-out must use a typed confirmation")
        return
    }
    assert(confirmation.warning.contains("clears all cached AWS SSO sessions"))
    assert(confirmation.warning.contains("temporary credential sections"))
    assert(confirmation.warning.contains("including default"))
    store.confirmProviderSignOut(confirmation, from: .mainWindow)
    let commandsBeforeConfirmation = await runner.allCommands()
    assert(commandsBeforeConfirmation.isEmpty)

    store.confirmProviderSignOut(confirmation, from: .settings)
    await runner.waitForCommandCount(1)
    await runner.releaseCommand(
        0,
        result: CommandResult(exitCode: 1, output: "token=private-value provider rejected logout")
    )
    await waitForLifecycleCondition("failed provider sign-out") {
        store.profiles.first?.status != .disconnecting
    }

    assert(store.activeAWSProfile == "alpha")
    assert(store.profiles.first?.status == previousStatus)
    guard case .operationError(let error) = store.presentation?.route else {
        assertionFailure("failed provider sign-out must route an error")
        return
    }
    assert(!error.message.contains("private-value"))
    store.requestProviderSignOut(profile)
    guard case .providerSignOutConfirmation(let retryConfirmation) = store.presentation?.route else {
        assertionFailure("expected retry confirmation")
        return
    }
    store.confirmProviderSignOut(retryConfirmation, from: .mainWindow)
    await runner.waitForCommandCount(2)
    await runner.releaseCommand(1, result: CommandResult(exitCode: 0, output: "signed out"))
    await waitForLifecycleCondition("successful provider sign-out") {
        store.activeAWSProfile.isEmpty
    }

    assert(store.profiles.first?.status == .needsLogin)
    let commands = await runner.allCommands()
    assert(commands == [["aws", "sso", "logout"], ["aws", "sso", "logout"]])
}

@MainActor
func testProviderSignOutWarningContractsIdentifyScope() async throws {
    let runner = LifecycleGateRunner()
    let (store, directory, defaults, suiteName) = try makeLifecycleStore(
        profileNames: ["alpha"],
        runner: runner
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let gcp = CloudProfile(
        provider: .gcp,
        name: "dev",
        accountID: "project-id",
        roleName: "developer@example.com"
    )
    store.requestProviderSignOut(gcp)
    guard case .providerSignOutConfirmation(let gcpConfirmation) = store.presentation?.route else {
        assertionFailure("expected GCP confirmation")
        return
    }
    assert(gcpConfirmation.warning.contains("developer@example.com"))
    assert(gcpConfirmation.warning.contains("configurations sharing that account"))
    store.confirmProviderSignOut(gcpConfirmation, from: .mainWindow)
    await runner.waitForCommandCount(1)
    await runner.releaseCommand(0, result: CommandResult(exitCode: 0, output: "revoked"))

    let azure = CloudProfile(provider: .azure, name: "dev", accountID: "subscription-123")
    store.requestProviderSignOut(azure)
    guard case .providerSignOutConfirmation(let azureConfirmation) = store.presentation?.route else {
        assertionFailure("expected Azure confirmation")
        return
    }
    assert(azureConfirmation.warning.contains("subscription-123"))
    assert(azureConfirmation.warning.contains("account cache globally"))
    store.confirmProviderSignOut(azureConfirmation, from: .mainWindow)
    await runner.waitForCommandCount(2)
    await runner.releaseCommand(1, result: CommandResult(exitCode: 0, output: "signed out"))

    let ambiguous = CloudProfile(provider: .gcp, name: "ambiguous")
    store.requestProviderSignOut(ambiguous)
    guard case .operationError(let error) = store.presentation?.route else {
        assertionFailure("ambiguous GCP sign-out must explain why it cannot run")
        return
    }
    assert(error.message.contains("cannot determine"))
    let commands = await runner.allCommands()
    assert(commands == [
        ["gcloud", "auth", "revoke", "developer@example.com", "--configuration", "dev"],
        ["az", "logout"]
    ])
}

@MainActor
func testGCPProviderSignOutClearsOnlyProfilesWithExactAccount() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-gcp-signout-\(UUID().uuidString)")
    let configurationsURL = directory.appendingPathComponent("configurations")
    try FileManager.default.createDirectory(at: configurationsURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profiles = [
        ("shared-a", "shared@example.com", "project-a"),
        ("shared-b", "SHARED@example.com", "project-b"),
        ("different", "different@example.com", "project-c")
    ]
    for (name, account, project) in profiles {
        try """
        [core]
        account = \(account)
        project = \(project)
        """.write(
            to: configurationsURL.appendingPathComponent("config_\(name)"),
            atomically: true,
            encoding: .utf8
        )
    }
    let suiteName = "ctx-gcp-signout-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("shared-a", forKey: "activeGCPProfile")
    let activeConfigURL = directory.appendingPathComponent("active_config")
    try "different\n".write(to: activeConfigURL, atomically: true, encoding: .utf8)
    let runner = RecordingCloudRunner()
    let kubeDiscovery = KubeConfigDiscoveryService(
        environment: { [:] },
        customPath: { directory.appendingPathComponent("missing-kubeconfig").path }
    )
    let configURL = directory.appendingPathComponent("aws-config")
    let store = ProfileStore(
        configURL: configURL,
        runner: runner,
        kubeConfigDiscoveryService: kubeDiscovery,
        localProfileDiscovery: LocalProfileDiscoveryService(
            awsConfigURL: configURL,
            kubeConfigDiscoveryService: kubeDiscovery,
            gcpConfigurationsDirURL: { configurationsURL },
            gcpActiveConfigURL: { activeConfigURL },
            azureProfilesDirURL: { directory.appendingPathComponent("missing-azure") }
        ),
        profileCommands: ProfileCommandService(runner: runner),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsCredentials: AWSCredentialService(
            configURL: configURL,
            credentialsURL: directory.appendingPathComponent("credentials")
        ),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        defaults: defaults,
        startsBackgroundServices: false
    )
    assert(store.activeGCPProfile == "shared-a", "external gcloud state overrode the CTX-selected profile")
    let requested = store.profiles.first { $0.name == "shared-a" }!

    store.requestProviderSignOut(requested)
    guard case .providerSignOutConfirmation(let confirmation) = store.presentation?.route else {
        assertionFailure("expected GCP sign-out confirmation")
        return
    }
    store.confirmProviderSignOut(confirmation, from: .mainWindow)
    await waitForLifecycleCondition("GCP provider sign-out") {
        store.profiles.first(where: { $0.name == "shared-a" })?.status == .needsLogin
    }

    assert(store.profiles.first(where: { $0.name == "shared-b" })?.status == .needsLogin)
    let disconnectedIDs = Set(
        defaults.stringArray(forKey: CTXDefaultsKey.manuallyDisconnectedProfileIDs) ?? []
    )
    assert(disconnectedIDs.contains(store.profiles.first { $0.name == "shared-a" }!.id))
    assert(disconnectedIDs.contains(store.profiles.first { $0.name == "shared-b" }!.id))
    assert(!disconnectedIDs.contains(store.profiles.first { $0.name == "different" }!.id))
    assert(store.activeGCPProfile.isEmpty)
    let commands = await runner.allCommands()
    let revokeCommands = commands.filter { $0.starts(with: ["gcloud", "auth", "revoke"]) }
    assert(revokeCommands == [
        ["gcloud", "auth", "revoke", "shared@example.com", "--configuration", "shared-a"]
    ])
}

@MainActor
func testBrokerDisconnectFailuresPreserveStateAndSanitizeErrors() async throws {
    let cases = [
        (
            context: "sdm-context",
            user: "sdm-" + "user",
            expected: ["sdm", "disconnect", "sdm-context"]
        ),
        (
            context: "teleport-context",
            user: "teleport-user",
            expected: ["tsh", "kube", "logout", "teleport-context"]
        )
    ]
    for testCase in cases {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-broker-disconnect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let kubeconfigURL = directory.appendingPathComponent("kubeconfig")
        try kubeconfig(
            context: testCase.context,
            cluster: "broker-cluster",
            user: testCase.user,
            server: "https://cluster.example.com"
        ).write(to: kubeconfigURL, atomically: true, encoding: .utf8)
        let suiteName = "ctx-broker-disconnect-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let runner = RecordingCloudRunner()
        await runner.setDefault(
            CommandResult(exitCode: 1, output: "token=private-value disconnect rejected")
        )
        let configURL = directory.appendingPathComponent("aws-config")
        let kubeDiscovery = KubeConfigDiscoveryService(
            environment: { [:] },
            customPath: { kubeconfigURL.path }
        )
        let store = ProfileStore(
            configURL: configURL,
            runner: runner,
            kubeConfigDiscoveryService: kubeDiscovery,
            profileCommands: ProfileCommandService(runner: runner),
            updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
            awsCredentials: AWSCredentialService(
                configURL: configURL,
                credentialsURL: directory.appendingPathComponent("credentials")
            ),
            profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
            fileWatchers: ProfileFileWatcherService(),
            folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
            defaults: defaults,
            startsBackgroundServices: false
        )
        let profile = store.profiles.first { $0.name == testCase.context }!
        store.logout(profile)
        await waitForLifecycleCondition("broker disconnect result") {
            store.lastMessage.contains("could not be confirmed")
        }
        let commandsBeforeVerify = await runner.allCommands()
        assert(commandsBeforeVerify.first == testCase.expected)
        assert(store.profiles.first(where: { $0.id == profile.id })?.status == .needsLogin)
        assert(store.activeKubeContext.isEmpty)
        assert(store.presentation == nil)
        assert(!store.lastMessage.contains("private-value"))
        let verified = await store.verify(profile)
        let commandsAfterVerify = await runner.allCommands()
        assert(!verified && commandsAfterVerify == commandsBeforeVerify)
        assert(defaults.stringArray(forKey: CTXDefaultsKey.manuallyDisconnectedProfileIDs)?.contains(profile.id) == true)

    }
}


@MainActor
func runProfileLifecycleActivationTests() async throws {
    try await testRapidConnectsRunOneEffectiveCommandFlow()
    try await testDisconnectSupersedesLateConnectResult()
    try await testCancelledAWSActivationCannotRestoreClearedDefaultProfile()
    try await testAWSActivationNeverExportsOrWritesDefaultCredentials()
    try await testAWSActiveProfileChangeSupersedesInFlightExportBeforeWrite()
    try await testAWSGlobalSignOutCancelsOtherOperationsAndCleansExports()
    try await testProfileOperationsRemainIndependent()
    try await testVerificationNeverExportsAWSCredentials()
    try await testAWSLoginExportsExactlyOnce()
    try await testExplicitAWSExportSurfacesWriteFailure()
    try await testProviderSignOutRequiresMatchingConfirmationAndPreservesFailureState()
    try await testProviderSignOutWarningContractsIdentifyScope()
    try await testGCPProviderSignOutClearsOnlyProfilesWithExactAccount()
    try await testBrokerDisconnectFailuresPreserveStateAndSanitizeErrors()
}
