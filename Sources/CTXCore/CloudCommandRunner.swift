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
    func run(_ arguments: [String]) async -> CommandResult
    func run(_ arguments: [String], onOutput: (@Sendable (String) -> Void)?) async -> CommandResult
    /// `timeout` bounds how long the subprocess may run before it is terminated.
    /// Pass `0` for no bound. Test doubles inherit the default below and ignore it.
    func run(_ arguments: [String], timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)?) async -> CommandResult
}

public extension CloudCommandRunning {
    func run(_ arguments: [String], onOutput: (@Sendable (String) -> Void)?) async -> CommandResult {
        await run(arguments)
    }

    func run(_ arguments: [String], timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)?) async -> CommandResult {
        await run(arguments, onOutput: onOutput)
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
    public init() {}

    public func run(_ arguments: [String]) async -> CommandResult {
        await run(arguments, timeout: CloudCommandTimeout.standard, onOutput: nil)
    }

    public func run(_ arguments: [String], onOutput: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        await run(arguments, timeout: CloudCommandTimeout.standard, onOutput: onOutput)
    }

    public func run(_ arguments: [String], timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        let processBox = ProcessBox()
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

            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let searchDirs = ["\(home)/.rd/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

            if let binaryName = arguments.first {
                let fm = FileManager.default
                for dir in searchDirs {
                    let path = (dir as NSString).appendingPathComponent(binaryName)
                    if fm.fileExists(atPath: path) {
                        execPath = path
                        args.removeFirst()
                        break
                    }
                }
            }

            let stdinPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = args
            process.standardInput = stdinPipe
            process.standardOutput = pipe
            process.standardError = pipe

            let interceptorDir = ensureInterceptorBinDir()
            var environment = ProcessInfo.processInfo.environment
            let existingPath = environment["PATH"] ?? ""
            let newPath = ([interceptorDir] + searchDirs + [existingPath]).joined(separator: ":")
            environment["PATH"] = newPath
            environment["BROWSER"] = "echo"
            environment["AWS_SSO_BROWSER"] = "none"
            environment["SDM_BROWSER"] = "echo"
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
