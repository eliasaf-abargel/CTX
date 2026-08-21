import CTXCore
import Foundation

actor LifecycleGateRunner: CloudCommandRunning {
    private var commands: [[String]] = []
    private var resultContinuations: [Int: CheckedContinuation<CommandResult, Never>] = [:]
    private var outputHandlers: [Int: @Sendable (String) -> Void] = [:]

    func run(
        _ arguments: [String],
        environmentOverrides: [String: String],
        timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)?
    ) async -> CommandResult {
        let index = commands.count
        commands.append(arguments)
        outputHandlers[index] = onOutput
        return await withCheckedContinuation { continuation in
            resultContinuations[index] = continuation
        }
    }

    func waitForCommandCount(_ count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while commands.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(
            commands.count >= count,
            "Timed out waiting for \(count) commands; observed \(commands.count): \(commands)"
        )
    }

    func releaseCommand(_ index: Int, result: CommandResult) {
        outputHandlers[index] = nil
        resultContinuations.removeValue(forKey: index)?.resume(returning: result)
    }

    func emitOutput(_ output: String, forCommand index: Int) {
        outputHandlers[index]?(output)
    }

    func allCommands() -> [[String]] {
        commands
    }
}

@MainActor
func waitForLifecycleCondition(
    _ description: String,
    timeout: Duration = .seconds(1),
    condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    precondition(condition(), "Timed out waiting for \(description)")
}

@MainActor
func makeLifecycleStore(
    profileNames: [String],
    runner: LifecycleGateRunner,
    activeAWSProfile: String? = nil,
    credentialsURL: URL? = nil,
    missingCLIToolResolver: @escaping MissingCLIToolResolving = { _ in nil }
) throws -> (ProfileStore, URL, UserDefaults, String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-lifecycle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let configURL = directory.appendingPathComponent("config")
    let config = profileNames.map {
        "[profile \($0)]\nsso_start_url = https://\($0)-\(UUID().uuidString).example.com/start\nsso_region = us-east-1"
    }.joined(separator: "\n\n")
    try config.write(to: configURL, atomically: true, encoding: .utf8)
    let suiteName = "ctx-lifecycle-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    if let activeAWSProfile {
        defaults.set(activeAWSProfile, forKey: "activeAWSProfile")
    }
    let kubeDiscovery = KubeConfigDiscoveryService(
        environment: { [:] },
        customPath: { directory.appendingPathComponent("missing-kubeconfig").path }
    )
    let store = ProfileStore(
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
            credentialsURL: credentialsURL ?? directory.appendingPathComponent("credentials")
        ),
        profilePersistence: CloudProfilePersistenceService(awsConfigURL: configURL),
        fileWatchers: ProfileFileWatcherService(),
        folderPreferences: CloudFolderPreferencesStore(defaults: defaults),
        missingCLIToolResolver: missingCLIToolResolver,
        defaults: defaults,
        startsBackgroundServices: false
    )
    return (store, directory, defaults, suiteName)
}
