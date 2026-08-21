import Foundation

public struct KubectlCommand: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environmentOverrides: [String: String]

    public init(executablePath: String, arguments: [String], environmentOverrides: [String: String] = [:]) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environmentOverrides = environmentOverrides
    }
}

public struct KubectlResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public enum KubectlRunnerError: LocalizedError, Equatable, Sendable {
    case kubectlNotFound
    case emptyContext
    case emptyArguments
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .kubectlNotFound:
            "kubectl was not found"
        case .emptyContext:
            "kubectl context is required"
        case .emptyArguments:
            "kubectl arguments are required"
        case .launchFailed(let message):
            "kubectl failed to launch: \(message)"
        }
    }
}

public protocol KubectlRunning: Sendable {
    func run(_ command: KubectlCommand, timeout: TimeInterval) async throws -> KubectlResult
}

public protocol KubectlCommandBuilding: Sendable {
    func inspectionCommand(context: String, arguments: [String]) throws -> KubectlCommand
}

public protocol KubectlConfigurationCommandBuilding: Sendable {
    func configurationCommand(arguments: [String]) throws -> KubectlCommand
}

public protocol KubectlProcessHandling: Sendable {
    var isRunning: Bool { get }
    func terminate()
    func outputIfExited() -> String
    func setTerminationHandler(_ handler: @Sendable @escaping () -> Void)
}

public protocol KubectlProcessStarting: Sendable {
    func start(_ command: KubectlCommand) throws -> any KubectlProcessHandling
}

public final class KubectlRunner: KubectlRunning, KubectlCommandBuilding, KubectlConfigurationCommandBuilding, KubectlProcessStarting {
    private let environment: @Sendable () -> [String: String]
    private let providerEnvironment: @Sendable () -> [String: String]

    public convenience init(
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.init(
            environment: environment,
            providerEnvironment: { ProviderCommandEnvironment.overrides() }
        )
    }

    public init(
        environment: @escaping @Sendable () -> [String: String],
        providerEnvironment: @escaping @Sendable () -> [String: String]
    ) {
        self.environment = environment
        self.providerEnvironment = providerEnvironment
    }

    public func inspectionCommand(context: String, arguments: [String]) throws -> KubectlCommand {
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { throw KubectlRunnerError.emptyContext }
        guard !arguments.isEmpty else { throw KubectlRunnerError.emptyArguments }
        return KubectlCommand(
            executablePath: try resolveKubectlPath(),
            arguments: ["--context", context] + arguments
        )
    }

    public func configurationCommand(arguments: [String]) throws -> KubectlCommand {
        guard !arguments.isEmpty else { throw KubectlRunnerError.emptyArguments }
        return KubectlCommand(
            executablePath: try resolveKubectlPath(),
            arguments: arguments
        )
    }

    public func run(_ command: KubectlCommand, timeout: TimeInterval) async throws -> KubectlResult {
        let environment = environmentWithSearchPath(environment())
            .merging(providerEnvironment()) { _, override in override }
        let processBox = ProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let timedOut = TimeoutFlag()
            guard processBox.set(process) else {
                throw CancellationError()
            }

            process.executableURL = URL(fileURLWithPath: command.executablePath)
            process.arguments = command.arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.environment = environment.merging(command.environmentOverrides) { _, override in override }

            do {
                try process.run()
            } catch {
                throw KubectlRunnerError.launchFailed(error.localizedDescription)
            }

            if timeout > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    timedOut.mark()
                    process.terminate()
                }
            }

            // Read stderr concurrently to prevent deadlock if both pipes get filled past the 64KB buffer limit
            let readStderrTask = Task {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = await readStderrTask.value

            process.waitUntilExit()
            processBox.clear()

            return KubectlResult(
                exitCode: process.terminationStatus,
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self),
                timedOut: timedOut.value
            )
            }.value
        } onCancel: {
            processBox.terminate()
        }
    }

    public func start(_ command: KubectlCommand) throws -> any KubectlProcessHandling {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = environmentWithSearchPath(environment())
            .merging(providerEnvironment()) { _, override in override }
            .merging(command.environmentOverrides) { _, override in override }
        do {
            try process.run()
            try? stdinPipe.fileHandleForWriting.close()
        } catch {
            throw KubectlRunnerError.launchFailed(error.localizedDescription)
        }
        return KubectlStartedProcess(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
    }

    public func resolveKubectlPath() throws -> String {
        guard let path = resolve("kubectl") else {
            throw KubectlRunnerError.kubectlNotFound
        }
        return path
    }

    /// Finds a CLI on the same search path kubectl is found on. `nil` rather than a
    /// throw, because callers for optional tooling (`helm`) treat "not installed" as
    /// a normal state to report, not an error.
    public func resolve(_ binary: String) -> String? {
        for dir in searchPaths(in: environment()) {
            let path = (dir as NSString).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func searchPaths(in environment: [String: String]) -> [String] {
        CLIToolPaths.dirs(fromPathVariable: environment["PATH"]) + CLIToolPaths.searchDirs
    }

    private func environmentWithSearchPath(_ environment: [String: String]) -> [String: String] {
        var merged = environment
        merged["PATH"] = searchPaths(in: environment).joined(separator: ":")
        return merged
    }
}

// `ProcessBox` and `TimeoutFlag` live in `ProcessSupport.swift` — `CloudCommandRunner`
// needs the same cancellation and timeout plumbing, so it is shared rather than
// copied.
