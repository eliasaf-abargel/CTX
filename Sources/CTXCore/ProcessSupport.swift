import Foundation

/// Shared subprocess plumbing for both runners — `KubectlRunner` (cluster reads)
/// and `CloudCommandRunner` (provider CLIs). Both need the same two things: a way
/// for a cancelled `Task` to reach in and terminate the process it started, and a
/// thread-safe flag recording that a timeout, rather than the command itself,
/// ended the run.

/// Holds the `Process` a detached run is driving so the task's cancellation
/// handler — which runs on a different thread — can terminate it. Also refuses to
/// hand over a process at all if cancellation already arrived first, which
/// otherwise leaves an orphan subprocess nobody can stop.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func set(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            return false
        }
        self.process = process
        return true
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        isCancelled = true
        let process = self.process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

/// Gate for commands CTX hands to Terminal.app as a remediation shortcut.
///
/// Those commands are assembled from names CTX does not control — profile names
/// read out of `~/.aws/config` or a kubeconfig, and in the AWS SSO case a word
/// sliced out of CLI error output. Every command CTX offers is a fixed verb
/// followed by names and flags, so anything carrying shell or AppleScript
/// metacharacters did not come from CTX and is not run.
public enum ShellCommandSafety {
    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_./:=@+"
    )

    public static func isSafeForTerminal(_ command: String) -> Bool {
        guard !command.isEmpty, command.count <= 512 else { return false }
        return command.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// Set by the timeout watchdog before it terminates the process, so the result can
/// say "timed out" rather than reporting the resulting non-zero exit as a plain
/// command failure.
final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mark() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}
