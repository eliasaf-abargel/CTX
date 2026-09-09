import CTXCore
import Foundation

private actor RecoveryRunner: CloudCommandRunning {
    var replies: [CommandResult]
    var commands: [[String]] = []
    init(_ replies: [CommandResult]) { self.replies = replies }
    func run(_ arguments: [String], environmentOverrides: [String: String], timeout: TimeInterval,
             onOutput: (@Sendable (String) -> Void)?) async -> CommandResult {
        commands.append(arguments)
        precondition(!replies.isEmpty, "Unexpected command")
        let result = replies.removeFirst()
        onOutput?(result.output)
        return result
    }
    func recorded() -> [[String]] { commands }
}

func testStrongDMSSOContinuesToResourceAndVerifiesAPI() async {
    let runner = RecoveryRunner([
        CommandResult(exitCode: 1, output: "not logged in"),
        CommandResult(exitCode: 1, output: "not logged in"),
        CommandResult(exitCode: 0, output: "Continue at https://login.example.com/authorize"),
        CommandResult(exitCode: 0, output: "connected"),
        CommandResult(exitCode: 0, output: "team-sdm  connected  localhost:6443")
    ])
    let kubectl = ScriptedKubectl()
    kubectl.outputForCommand = { _ in .failure(stderr: "connection refused") }
    let service = ProfileCommandService(runner: runner, kubectl: kubectl)
    let profile = CloudProfile(provider: .kubernetes, name: "team-sdm")
    let login = await service.login(profile, email: "developer@example.com")
    assert(login.exitCode == 0)
    let verification = await service.verify(profile, activeKubeContext: profile.name, kubeconfigPath: "/tmp/team-config")
    assert(verification.exitCode != 0, "broker status must not mask an unreachable cluster API")
    assert(verification.output.contains("connection refused"))
    let commands = await runner.recorded()
    assert(commands == [
        ["sdm", "connect", "team-sdm"], ["sdm", "status"],
        ["sdm", "login", "--email", "developer@example.com"],
        ["sdm", "connect", "team-sdm"], ["sdm", "status"]
    ])
}

func testStrongDMAlreadyDisconnectedAndResourceFailure() async {
    let profile = CloudProfile(provider: .kubernetes, name: "team-sdm")
    let runner = RecoveryRunner([
        CommandResult(exitCode: 1, output: "already disconnected"),
        CommandResult(exitCode: 0, output: "team-sdm  not connected  localhost:6443")
    ])
    let result = await ProfileCommandService(runner: runner).logout(profile)
    assert(result.exitCode == 0)
    assert(ProfileCommandService.strongDMConnectionState(in: "team-sdm  not connected  6443", resource: profile.name) == false)
    assert(ProfileCommandService.strongDMConnectionState(in: "team-sdm-other  connected  6443", resource: profile.name) == nil)
    let denied = RecoveryRunner([
        CommandResult(exitCode: 1, output: "access denied"),
        CommandResult(exitCode: 0, output: "team-sdm  not connected  localhost:6443")
    ])
    let failed = await ProfileCommandService(runner: denied).login(profile)
    assert(failed.exitCode != 0)
    let commands = await denied.recorded()
    assert(!commands.contains { $0.contains("login") }, "an authenticated resource failure must not repeat SSO")
}

func testUpdateCheckDistinguishesCurrentReleaseFromServiceFailure() throws {
    let data = Data(#"{"tag_name":"v1.2.3"}"#.utf8)
    for version in ["1.2.3", "v1.2.3", "1.2.4"] {
        let result = try CTXUpdateService.checkResult(data: data, statusCode: 200, currentVersion: version)
        assert(!result.isUpdateAvailable)
    }
    let newer = try CTXUpdateService.checkResult(data: data, statusCode: 200, currentVersion: "1.2.2")
    assert(newer.isUpdateAvailable)
    for status in [404, 403, 429, 500] {
        do {
            _ = try CTXUpdateService.checkResult(data: data, statusCode: status, currentVersion: "1.2.3")
            assertionFailure("Unavailable release service is not proof of being up to date")
        } catch CTXUpdateServiceError.releaseUnavailable(let actual) {
            assert(actual == status)
        }
    }
}

@MainActor
func testLocalIdentityDoesNotFollowProviderSelection() async throws {
    let runner = LifecycleGateRunner()
    let (store, directory, defaults, suite) = try makeLifecycleStore(profileNames: ["alpha", "beta"], runner: runner)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let identity = store.localIdentityLabel
    let initials = store.localIdentityInitials
    for (index, name) in ["alpha", "beta"].enumerated() {
        let profile = store.profiles.first { $0.name == name }!
        store.setActive(profile)
        await runner.waitForCommandCount(index + 1)
        await runner.releaseCommand(index, result: CommandResult(exitCode: 0, output: "{}"))
        await waitForLifecycleCondition("provider activation") {
            store.profiles.first { $0.name == name }?.status == .connected
        }
        assert(store.activeAWSProfile == name)
        assert(!identity.isEmpty && store.localIdentityLabel == identity)
        assert(store.localIdentityInitials == initials)
    }
}

func testStrongDMPostSSOFailureAndDiagnosticPrivacy() async throws {
    for loginCode: Int32 in [0, 1] {
        var results = [
            CommandResult(exitCode: 1, output: "not logged in"),
            CommandResult(exitCode: 1, output: "not logged in"),
            CommandResult(exitCode: loginCode, output: "https://login.example.com/authorize")
        ]
        if loginCode == 0 { results.append(CommandResult(exitCode: 1, output: "access denied")) }
        let runner = RecoveryRunner(results)
        let result = await ProfileCommandService(runner: runner).login(CloudProfile(provider: .kubernetes, name: "team-sdm"))
        assert(result.exitCode == 1, "SSO output must not hide login or final resource failure")
        let commands = await runner.recorded()
        assert(commands.count == (loginCode == 0 ? 4 : 3))
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = LocalDiagnostics(directory: directory)
    log.recordCommand(arguments: ["sdm", "login", "--email", "private-sentinel@example.com"],
                      result: CommandResult(exitCode: 1, output: "authentication failed token=private-sentinel"), durationMs: 10)
    let data = try String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
    assert(!data.contains("private-sentinel"))
    assert(data.contains("authentication_required") && data.contains("exitCode"))
}
