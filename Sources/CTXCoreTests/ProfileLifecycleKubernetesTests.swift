import CTXCore
import Foundation

actor KubeActivationGate {
    private var commands: [KubectlCommand] = []
    private var continuations: [Int: CheckedContinuation<KubectlResult, Never>] = [:]

    func run(_ command: KubectlCommand) async -> KubectlResult {
        guard command.arguments.contains("use-context") else {
            return KubectlResult(exitCode: 0, stdout: "{}", stderr: "")
        }
        let index = commands.count
        commands.append(command)
        return await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func waitForCount(_ count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while commands.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(
            commands.count >= count,
            "Timed out waiting for \(count) kubectl commands; observed \(commands.count)"
        )
    }

    func release(_ index: Int, exitCode: Int32) {
        continuations.removeValue(forKey: index)?.resume(
            returning: KubectlResult(
                exitCode: exitCode,
                stdout: exitCode == 0 ? "switched" : "",
                stderr: exitCode == 0 ? "" : "switch failed"
            )
        )
    }
}

actor BrokerPollDelayGate {
    private var started = false
    private var cancelled = false

    func suspendUntilCancelled() async throws {
        started = true
        do {
            while true {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        let deadline = Date().addingTimeInterval(5)
        while !started, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(started, "Timed out waiting for broker polling to start")
    }

    func waitUntilCancelled() async {
        let deadline = Date().addingTimeInterval(5)
        while !cancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(cancelled, "Timed out waiting for broker polling cancellation")
    }
}

final class GatedActivationKubectl: KubectlRunning, KubectlCommandBuilding, KubectlConfigurationCommandBuilding, @unchecked Sendable {
    let gate = KubeActivationGate()

    func inspectionCommand(context: String, arguments: [String]) throws -> KubectlCommand {
        KubectlCommand(executablePath: "/mock/kubectl", arguments: ["--context", context] + arguments)
    }

    func configurationCommand(arguments: [String]) throws -> KubectlCommand {
        KubectlCommand(executablePath: "/mock/kubectl", arguments: arguments)
    }

    func run(_ command: KubectlCommand, timeout: TimeInterval) async throws -> KubectlResult {
        await gate.run(command)
    }
}

func lifecycleKubeconfig(
    current: String,
    contexts: [String] = ["old", "new", "third"]
) -> String {
    let contextRecords = contexts.map { name in
        """
        - name: \(name)
          context:
            cluster: shared
            user: user
        """
    }.joined(separator: "\n")
    return """
    apiVersion: v1
    kind: Config
    current-context: \(current)
    clusters:
    - name: shared
      cluster:
        server: https://cluster.example.com
    contexts:
    \(contextRecords)
    users:
    - name: user
      user: {}
    """
}

@MainActor
func makeKubeActivationStore() throws -> (ProfileStore, GatedActivationKubectl, URL, UserDefaults, String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-kube-activation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let kubeconfigURL = directory.appendingPathComponent("kubeconfig")
    try lifecycleKubeconfig(current: "old").write(to: kubeconfigURL, atomically: true, encoding: .utf8)
    let suiteName = "ctx-kube-activation-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set("old", forKey: "activeKubeContext")
    let runner = RecordingCloudRunner()
    let kubectl = GatedActivationKubectl()
    let discovery = KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path })
    let store = ProfileStore(
        configURL: directory.appendingPathComponent("config"),
        runner: runner,
        kubeConfigMutations: KubeConfigMutationService(kubectl: kubectl),
        kubeConfigDiscoveryService: discovery,
        localProfileDiscovery: LocalProfileDiscoveryService(
            awsConfigURL: directory.appendingPathComponent("config"),
            kubeConfigDiscoveryService: discovery,
            gcpConfigurationsDirURL: { directory.appendingPathComponent("missing-gcp") },
            gcpActiveConfigURL: { directory.appendingPathComponent("missing-gcp/active_config") },
            azureProfilesDirURL: { directory.appendingPathComponent("missing-azure") }
        ),
        profileCommands: ProfileCommandService(runner: runner, kubectl: kubectl),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsSessionExpirations: AWSSessionExpirationService(
            credentialsURL: directory.appendingPathComponent("credentials"),
            ssoCacheURL: directory.appendingPathComponent("missing-sso-cache")
        ),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        missingCLIToolResolver: { _ in nil },
        defaults: defaults,
        startsBackgroundServices: false
    )
    return (store, kubectl, directory, defaults, suiteName)
}

@MainActor
func testKubeActivationIgnoresStaleDiscoveryAndConfirmsSuccess() async throws {
    let (store, kubectl, directory, defaults, suiteName) = try makeKubeActivationStore()
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let kubeconfigURL = directory.appendingPathComponent("kubeconfig")
    let target = store.profiles.first { $0.name == "new" }!

    store.setActive(target)
    await kubectl.gate.waitForCount(1)
    store.refreshImmediately(runVerification: false)
    assert(store.activeKubeContext == "new", "stale disk current-context replaced an in-flight target")

    await kubectl.gate.release(0, exitCode: 0)
    try lifecycleKubeconfig(current: "new").write(to: kubeconfigURL, atomically: true, encoding: .utf8)
    store.refreshImmediately(runVerification: false)
    try lifecycleKubeconfig(current: "old").write(to: kubeconfigURL, atomically: true, encoding: .utf8)
    store.refreshImmediately(runVerification: false)
    assert(store.activeKubeContext == "new", "external kubeconfig changes overrode CTX selection")
}

@MainActor
func testKubeActivationFailureAndSupersessionClearPendingState() async throws {
    let (store, kubectl, directory, defaults, suiteName) = try makeKubeActivationStore()
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let new = store.profiles.first { $0.name == "new" }!
    let third = store.profiles.first { $0.name == "third" }!

    store.setActive(new)
    await kubectl.gate.waitForCount(1)
    store.setActive(third)
    await kubectl.gate.waitForCount(2)
    await kubectl.gate.release(0, exitCode: 1)
    await Task.yield()
    assert(store.activeKubeContext == "third", "superseded failure cleared the newer target")

    await kubectl.gate.release(1, exitCode: 1)
    await waitForLifecycleCondition("failed kube activation rollback") {
        store.activeKubeContext != "third"
    }
    assert(store.activeKubeContext == "new", "current switch failure did not restore its prior active state")

    store.refreshImmediately(runVerification: false)
    assert(store.activeKubeContext == "new", "discovery overrode the CTX rollback target")
}

@MainActor
func testDisconnectCancelsOwnedPendingKubeActivation() async throws {
    let (store, kubectl, directory, defaults, suiteName) = try makeKubeActivationStore()
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let target = store.profiles.first { $0.name == "new" }!

    store.setActive(target)
    await kubectl.gate.waitForCount(1)
    store.logout(target)
    assert(store.activeKubeContext == "old", "disconnect did not revert the pending CTX activation")

    await kubectl.gate.release(0, exitCode: 0)
    await waitForLifecycleCondition("pending kube activation cancellation") {
        store.profiles.first(where: { $0.id == target.id })?.status != .disconnecting
    }
    store.refreshImmediately(runVerification: false)

    assert(store.activeKubeContext == "old", "a cancelled activation completion replaced the CTX selection")
}

@MainActor
func testMissingKubeProfileCancelsAndRevertsOwnedActivation() async throws {
    let (store, kubectl, directory, defaults, suiteName) = try makeKubeActivationStore()
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let kubeconfigURL = directory.appendingPathComponent("kubeconfig")
    let target = store.profiles.first { $0.name == "new" }!

    store.setActive(target)
    await kubectl.gate.waitForCount(1)
    assert(store.activeKubeContext == "new")

    try lifecycleKubeconfig(current: "old", contexts: ["old", "third"])
        .write(to: kubeconfigURL, atomically: true, encoding: .utf8)
    store.refreshImmediately(runVerification: false)

    assert(!store.profiles.contains { $0.id == target.id })
    assert(store.activeKubeContext == "old", "removing the owner must revert its pending activation")

    await kubectl.gate.release(0, exitCode: 0)
    store.refreshImmediately(runVerification: false)
    assert(store.activeKubeContext == "old", "a late completion from the removed owner must not reactivate it")
}

@MainActor
func testLocalKubeDisconnectSurvivesRefreshAndVerification() async throws {
    let (store, _, directory, defaults, suiteName) = try makeKubeActivationStore()
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let profile = store.profiles.first { $0.name == "old" }!
    let kubeconfigURL = directory.appendingPathComponent("kubeconfig")

    store.logout(profile)
    await waitForLifecycleCondition("local kube disconnect") {
        store.lastMessage == "Disconnected old from CTX"
    }
    store.refreshImmediately(runVerification: false)
    let verified = await store.verify(profile)

    assert(!verified, "manual disconnect must override a successful local kubectl probe")
    assert(store.activeKubeContext.isEmpty)
    assert(store.profiles.first(where: { $0.id == profile.id })?.status != .connected)
    let discovery = KubeConfigDiscoveryService(
        environment: { [:] },
        customPath: { kubeconfigURL.path }
    ).discover()
    assert(discovery.currentContext == "old", "CTX disconnect must not mutate kubeconfig current-context")
}

@MainActor
func testMultiFileActivationConfirmsAgainstTargetedKubeconfig() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-kube-multifile-activation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let primary = directory.appendingPathComponent("primary")
    let secondary = directory.appendingPathComponent("secondary")
    try lifecycleKubeconfig(current: "old", contexts: ["old"])
        .write(to: primary, atomically: true, encoding: .utf8)
    try lifecycleKubeconfig(current: "new", contexts: ["new"])
        .write(to: secondary, atomically: true, encoding: .utf8)
    let suiteName = "ctx-kube-multifile-activation-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set("old", forKey: "activeKubeContext")
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let runner = RecordingCloudRunner()
    let kubectl = GatedActivationKubectl()
    let discovery = KubeConfigDiscoveryService(
        environment: { ["KUBECONFIG": "\(primary.path):\(secondary.path)"] },
        customPath: { nil }
    )
    let store = ProfileStore(
        configURL: directory.appendingPathComponent("config"),
        runner: runner,
        kubeConfigMutations: KubeConfigMutationService(kubectl: kubectl),
        kubeConfigDiscoveryService: discovery,
        localProfileDiscovery: LocalProfileDiscoveryService(
            awsConfigURL: directory.appendingPathComponent("config"),
            kubeConfigDiscoveryService: discovery,
            gcpConfigurationsDirURL: { directory.appendingPathComponent("missing-gcp") },
            gcpActiveConfigURL: { directory.appendingPathComponent("missing-gcp/active_config") },
            azureProfilesDirURL: { directory.appendingPathComponent("missing-azure") }
        ),
        profileCommands: ProfileCommandService(runner: runner, kubectl: kubectl),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        missingCLIToolResolver: { _ in nil },
        defaults: defaults,
        startsBackgroundServices: false
    )
    let target = store.profiles.first { $0.name == "new" }!

    store.setActive(target)
    await kubectl.gate.waitForCount(1)
    await kubectl.gate.release(0, exitCode: 0)
    await waitForLifecycleCondition("secondary kubeconfig activation") {
        store.lastMessage == "Switched kube context to new"
    }
    store.refreshImmediately(runVerification: false)

    assert(
        store.activeKubeContext == "new",
        "primary kubeconfig discovery overrode the CTX-selected secondary context"
    )
}

@MainActor
func testBrokerPollingStopsWhenLifecycleOperationIsCancelled() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-broker-cancellation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "ctx-broker-cancellation-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let kubeconfigURL = directory.appendingPathComponent("kubeconfig")
    try lifecycleKubeconfig(current: "sdm-cluster", contexts: ["sdm-cluster"])
        .write(to: kubeconfigURL, atomically: true, encoding: .utf8)

    let runner = LifecycleGateRunner()
    let kubectl = ScriptedKubectl()
    kubectl.outputForCommand = { command in
        command.arguments.contains("use-context") || command.arguments.contains("unset")
            ? .success("switched")
            : .failure(stderr: "broker is not ready")
    }
    let delay = BrokerPollDelayGate()
    let discovery = KubeConfigDiscoveryService(environment: { [:] }, customPath: { kubeconfigURL.path })
    let store = ProfileStore(
        configURL: directory.appendingPathComponent("config"),
        runner: runner,
        kubeConfigMutations: KubeConfigMutationService(kubectl: kubectl),
        kubeConfigDiscoveryService: discovery,
        localProfileDiscovery: LocalProfileDiscoveryService(
            awsConfigURL: directory.appendingPathComponent("config"),
            kubeConfigDiscoveryService: discovery,
            gcpConfigurationsDirURL: { directory.appendingPathComponent("missing-gcp") },
            gcpActiveConfigURL: { directory.appendingPathComponent("missing-gcp/active_config") },
            azureProfilesDirURL: { directory.appendingPathComponent("missing-azure") }
        ),
        profileCommands: ProfileCommandService(runner: runner, kubectl: kubectl),
        updateService: CTXUpdateService(runner: runner, currentVersion: { "0.1.0" }),
        awsSessionExpirations: AWSSessionExpirationService(
            credentialsURL: directory.appendingPathComponent("credentials"),
            ssoCacheURL: directory.appendingPathComponent("missing-sso-cache")
        ),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        missingCLIToolResolver: { _ in nil },
        brokerPollDelay: { try await delay.suspendUntilCancelled() },
        defaults: defaults,
        startsBackgroundServices: false
    )
    let profile = store.profiles.first!

    store.login(profile)
    await runner.waitForCommandCount(1)
    await runner.releaseCommand(0, result: CommandResult(exitCode: 0, output: "connected"))
    await runner.waitForCommandCount(2)
    await runner.releaseCommand(1, result: CommandResult(exitCode: 1, output: "not ready"))
    await delay.waitUntilStarted()

    store.logout(profile)
    await delay.waitUntilCancelled()
    await runner.waitForCommandCount(3)
    await runner.releaseCommand(2, result: CommandResult(exitCode: 0, output: "disconnected"))
    await waitForLifecycleCondition("broker disconnect completion") {
        store.profiles.first?.status != .disconnecting
    }

    let commands = await runner.allCommands()
    assert(
        commands.filter { $0.starts(with: ["sdm", "status"]) }.count == 1,
        "expected one broker status poll, got \(commands)"
    )
    assert(store.profiles.first?.status == .needsLogin)
}
