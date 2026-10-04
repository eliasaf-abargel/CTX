import CTXCore
import Foundation

func testCloudCommandRunnerTerminatesAHangingProcess() async throws {
    let started = Date()
    let result = await CloudCommandRunner().run(["sleep", "30"], timeout: 1.0, onOutput: nil)
    let elapsed = Date().timeIntervalSince(started)
    assert(result.exitCode == 124, "expected timeout exit code, got \(result.exitCode)")
    assert(result.output.contains("timed out"), "timeout should be visible in the output")
    assert(elapsed < 10, "runner should return near the timeout, took \(elapsed)s")
}

func testCloudCommandRunnerMergesOverridesWithSafetyEnvironment() async throws {
    let result = await CloudCommandRunner().run(
        [
            "sh", "-c",
            "printf '%s\\n%s\\n%s\\n%s' \"$AWS_CONFIG_FILE\" \"$BROWSER\" \"$AWS_SSO_BROWSER\" \"$PATH\""
        ],
        environmentOverrides: [
            "AWS_CONFIG_FILE": "/configs/aws",
            "BROWSER": "unsafe-browser",
            "AWS_SSO_BROWSER": "unsafe-sso-browser",
            "PATH": "/custom/bin"
        ],
        timeout: 2,
        onOutput: nil
    )

    assert(result.exitCode == 0)
    let lines = result.output.components(separatedBy: .newlines)
    assert(lines[0] == "/configs/aws")
    assert(lines[1] == "echo")
    assert(lines[2] == "none")
    assert(lines[3].contains("/custom/bin"))
    assert(lines[3].contains("/opt/homebrew/bin"))
}

/// Cancelling the task must actually kill the subprocess, not just abandon it.
func testCloudCommandRunnerCancellationTerminatesTheSubprocess() async throws {
    let started = Date()
    let task = Task {
        await CloudCommandRunner().run(["sleep", "30"], timeout: 0, onOutput: nil)
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    _ = await task.value
    let elapsed = Date().timeIntervalSince(started)
    assert(elapsed < 10, "cancellation should end the run promptly, took \(elapsed)s")
}

/// The regression that made CTX stop noticing CLI logins: every tool CTX watches
/// writes atomically (temp file + rename), which unlinks the inode the watcher
/// holds. Without re-arming, only the first write is ever seen.
func testProfileFileWatcherSurvivesAtomicReplacement() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx-watch-\(UUID().uuidString)")
    // The watched file lives in its own directory, and every *other* configured
    // path points somewhere else entirely — otherwise a directory watcher would
    // fire on the temp files an atomic write creates, and the test would pass even
    // with a dead file watcher.
    let watchedDirectory = root.appendingPathComponent("watched")
    let unrelated = root.appendingPathComponent("unrelated")
    try FileManager.default.createDirectory(at: watchedDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let target = watchedDirectory.appendingPathComponent("config")
    try "first".write(to: target, atomically: false, encoding: .utf8)

    let counter = FireCounter()
    let watcher = ProfileFileWatcherService()
    watcher.start(
        kubeConfigPath: nil,
        awsConfigPath: target.path,
        gcpActiveConfigPath: unrelated.appendingPathComponent("active_config").path,
        gcpConfigsDirPath: unrelated.appendingPathComponent("configurations").path,
        azureProfilesDirPath: unrelated.appendingPathComponent("azure").path,
        onRefresh: { counter.fire() },
        onGCPActiveConfigChanged: {}
    )
    defer { watcher.stop() }

    // `atomically: true` is exactly what the provider CLIs do — write a temp file
    // and rename it over the target.
    for text in ["second", "third"] {
        try await Task.sleep(nanoseconds: 700_000_000)
        try text.write(to: target, atomically: true, encoding: .utf8)
    }
    try await Task.sleep(nanoseconds: 700_000_000)

    assert(counter.count >= 2, "watcher went deaf after the first atomic replace (fired \(counter.count) times)")
}



/// Remediation commands are built from names CTX does not control, including a
/// word sliced out of CLI error output — they must never reach AppleScript's
/// `do script` with shell metacharacters intact.
func testShellCommandSafetyRejectsInjection() throws {
    assert(ShellCommandSafety.isSafeForTerminal("aws sso login --profile dev-sso"))
    assert(ShellCommandSafety.isSafeForTerminal("kubectl get --raw=/version --context my-cluster"))
    assert(ShellCommandSafety.isSafeForTerminal("sdm connect prod-db.example.com"))

    assert(!ShellCommandSafety.isSafeForTerminal("aws sso login --profile a\"; rm -rf ~; echo \""))
    assert(!ShellCommandSafety.isSafeForTerminal("sdm connect $(whoami)"))
    assert(!ShellCommandSafety.isSafeForTerminal("tsh kube login a`id`"))
    assert(!ShellCommandSafety.isSafeForTerminal("aws sso login --profile x && curl evil.test"))
    assert(!ShellCommandSafety.isSafeForTerminal("aws sso login\nrm -rf ~"))
    assert(!ShellCommandSafety.isSafeForTerminal(""))
}


func runCloudCommandSafetyTests() async throws {
    try await testCloudCommandRunnerTerminatesAHangingProcess()
    try await testCloudCommandRunnerMergesOverridesWithSafetyEnvironment()
    try await testCloudCommandRunnerCancellationTerminatesTheSubprocess()
    try await testProfileFileWatcherSurvivesAtomicReplacement()
    try testShellCommandSafetyRejectsInjection()
}
