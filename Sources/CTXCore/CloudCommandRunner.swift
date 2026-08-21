import Foundation

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public protocol CloudCommandRunning: Sendable {
    /// The one method a conformer has to write, so that `environmentOverrides` —
    /// which carries the user's configured AWS/gcloud/Azure config locations — can
    /// never be dropped on the floor. It used to be the other way round: the
    /// protocol defaulted the environment-aware call to the plain one, so any
    /// runner (including every test double) silently ran provider CLIs against the
    /// default config paths and nothing said so.
    ///
    /// `timeout` bounds how long the subprocess may run before it is terminated.
    /// Pass `0` for no bound; test doubles are free to ignore it.
    func run(
        _ arguments: [String],
        environmentOverrides: [String: String],
        timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)?
    ) async -> CommandResult
}

/// Convenience spellings for callers that have nothing to override. Each one
/// funnels into the single requirement above, so a conformer cannot accidentally
/// implement one path and leave the environment-aware path behind.
public extension CloudCommandRunning {
    func run(_ arguments: [String]) async -> CommandResult {
        await run(arguments, environmentOverrides: [:], timeout: CloudCommandTimeout.standard, onOutput: nil)
    }

    func run(_ arguments: [String], onOutput: (@Sendable (String) -> Void)?) async -> CommandResult {
        await run(arguments, environmentOverrides: [:], timeout: CloudCommandTimeout.standard, onOutput: onOutput)
    }

    func run(_ arguments: [String], timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)?) async -> CommandResult {
        await run(arguments, environmentOverrides: [:], timeout: timeout, onOutput: onOutput)
    }
}

/// Default bound for a provider CLI call. Verification and activation commands are
/// expected to answer quickly; an interactive login is not, and passes its own
/// longer bound (see `ProfileCommandService`). Nothing here is ever unbounded —
/// a hung `aws`/`gcloud`/`sdm` process used to leave the profile's status stuck on
/// "connecting" for the lifetime of the app with no way to recover.
public enum CloudCommandTimeout {
    public static let standard: TimeInterval = 25
    public static let interactiveLogin: TimeInterval = 300
}

public final class CloudCommandRunner: CloudCommandRunning {
    /// Provider logins must not pop a browser out from under the user, so by
    /// default the child gets `BROWSER=echo` and a no-op `open` ahead of its
    /// `PATH`. That is wrong for anything that legitimately opens things — a
    /// Homebrew cask install runs `open` on the downloaded package and would
    /// silently do nothing — so those callers turn it off.
    private let suppressesBrowserLaunch: Bool

    public init(suppressesBrowserLaunch: Bool = true) {
        self.suppressesBrowserLaunch = suppressesBrowserLaunch
    }

    public func run(_ arguments: [String]) async -> CommandResult {
        await run(arguments, timeout: CloudCommandTimeout.standard, onOutput: nil)
    }

    public func run(_ arguments: [String], onOutput: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        await run(arguments, timeout: CloudCommandTimeout.standard, onOutput: onOutput)
    }

    public func run(_ arguments: [String], timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        await run(arguments, environmentOverrides: [:], timeout: timeout, onOutput: onOutput)
    }

    public func run(
        _ arguments: [String],
        environmentOverrides: [String: String],
        timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> CommandResult {
        let processBox = ProcessBox()
        let suppressesBrowserLaunch = self.suppressesBrowserLaunch
        return await withTaskCancellationHandler {
            await Task.detached {
            let process = Process()
            let pipe = Pipe()
            let timedOut = TimeoutFlag()
            guard processBox.set(process) else {
                return CommandResult(exitCode: 130, output: "Cancelled")
            }

            var args = arguments
            var execPath = "/usr/bin/env"

            let searchDirs = CLIToolPaths.searchDirs
            let inheritedPathDirs = CLIToolPaths.dirs(fromPathVariable: ProcessInfo.processInfo.environment["PATH"])

            if let binaryName = arguments.first {
                guard let resolved = CLIToolPaths.resolve(binaryName, extraDirs: inheritedPathDirs) else {
                    // Saying which tool is missing beats letting `env` answer with
                    // "No such file or directory", which is what a profile that
                    // simply had no CLI installed used to report.
                    return CommandResult(
                        exitCode: 127,
                        output: "\(binaryName) was not found on this Mac. Install the \(binaryName) CLI, then try again."
                    )
                }
                execPath = resolved
                args.removeFirst()
            }

            let stdinPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = args
            process.standardInput = stdinPipe
            process.standardOutput = pipe
            process.standardError = pipe

            var environment = ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, override in override }
            let existingPath = environment["PATH"] ?? ""
            let pathDirs = suppressesBrowserLaunch
                ? [ensureInterceptorBinDir()] + searchDirs + [existingPath]
                : searchDirs + [existingPath]
            environment["PATH"] = pathDirs.joined(separator: ":")
            if suppressesBrowserLaunch {
                environment["BROWSER"] = "echo"
                environment["AWS_SSO_BROWSER"] = "none"
                environment["SDM_BROWSER"] = "echo"
            }
            process.environment = environment

            do {
                try process.run()
                try? stdinPipe.fileHandleForWriting.close()

                if timeout > 0 {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                        guard process.isRunning else { return }
                        timedOut.mark()
                        process.terminate()
                    }
                }

                let handle = pipe.fileHandleForReading
                var capturedData = Data()

                if let onOutput {
                    // `availableData` blocks until the child writes or closes the
                    // pipe, so this drains as output arrives (which is what lets an
                    // SSO URL be picked up mid-login) and ends at EOF — no polling
                    // loop, and nothing left spinning when the child is terminated.
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        capturedData.append(data)
                        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                            onOutput(text)
                        }
                    }
                } else {
                    capturedData = handle.readDataToEndOfFile()
                }
                process.waitUntilExit()
                processBox.clear()

                if timedOut.value {
                    let partial = String(decoding: capturedData, as: UTF8.self)
                    let notice = "Command timed out after \(Int(timeout))s: \(arguments.first ?? "command")"
                    return CommandResult(
                        exitCode: 124,
                        output: partial.isEmpty ? notice : "\(notice)\n\(partial)"
                    )
                }

                return CommandResult(
                    exitCode: process.terminationStatus,
                    output: String(decoding: capturedData, as: UTF8.self)
                )
            } catch {
                processBox.clear()
                return CommandResult(exitCode: 127, output: error.localizedDescription)
            }
            }.value
        } onCancel: {
            processBox.terminate()
        }
    }
}

private func ensureInterceptorBinDir() -> String {
    let fm = FileManager.default
    let tempDir = NSTemporaryDirectory()
    let binDir = (tempDir as NSString).appendingPathComponent("ctx-interceptor-bin")
    try? fm.createDirectory(atPath: binDir, withIntermediateDirectories: true, attributes: nil)

    let openScriptPath = (binDir as NSString).appendingPathComponent("open")
    if !fm.fileExists(atPath: openScriptPath) {
        let scriptContent = "#!/bin/sh\nexit 0\n"
        try? scriptContent.write(toFile: openScriptPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openScriptPath)
    }
    return binDir
}
