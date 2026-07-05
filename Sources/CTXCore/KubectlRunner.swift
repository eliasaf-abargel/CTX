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

public protocol KubectlProcessHandling: Sendable {
    var isRunning: Bool { get }
    func terminate()
    func outputIfExited() -> String
    func setTerminationHandler(_ handler: @Sendable @escaping () -> Void)
}

public protocol KubectlProcessStarting: Sendable {
    func start(_ command: KubectlCommand) throws -> any KubectlProcessHandling
}

public final class KubectlRunner: KubectlRunning, KubectlCommandBuilding, KubectlProcessStarting {
    private let environment: @Sendable () -> [String: String]

    public init(
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.environment = environment
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

    public func run(_ command: KubectlCommand, timeout: TimeInterval) async throws -> KubectlResult {
        let environment = environmentWithSearchPath(environment())
        let processBox = ProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let timedOut = TimeoutFlag()
            processBox.set(process)

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
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = environmentWithSearchPath(environment()).merging(command.environmentOverrides) { _, override in override }
        do {
            try process.run()
        } catch {
            throw KubectlRunnerError.launchFailed(error.localizedDescription)
        }
        return KubectlStartedProcess(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
    }

    public func resolveKubectlPath() throws -> String {
        let paths = searchPaths(in: environment())
        for dir in paths {
            let path = (dir as NSString).appendingPathComponent("kubectl")
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        throw KubectlRunnerError.kubectlNotFound
    }

    private func searchPaths(in environment: [String: String]) -> [String] {
        let pathDirs = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return pathDirs + [
            "\(home)/.rd/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    }

    private func environmentWithSearchPath(_ environment: [String: String]) -> [String: String] {
        var merged = environment
        merged["PATH"] = searchPaths(in: environment).joined(separator: ":")
        return merged
    }
}

private final class KubectlStartedProcess: KubectlProcessHandling, @unchecked Sendable {
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let outputLock = NSLock()
    private var outputData = Data()
    private var terminationHandler: (@Sendable () -> Void)?

    init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        
        setupReadabilityHandlers()
        setupTerminationHandler()
    }

    deinit {
        cleanup()
    }

    private func setupReadabilityHandlers() {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendData(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendData(data)
        }
    }

    private func setupTerminationHandler() {
        process.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }
    }

    private func handleTermination() {
        cleanup()
        let handler: (@Sendable () -> Void)?
        outputLock.lock()
        handler = terminationHandler
        outputLock.unlock()
        handler?()
    }

    private func appendData(_ data: Data) {
        outputLock.lock()
        defer { outputLock.unlock() }
        outputData.append(data)
        if outputData.count > 64 * 1024 {
            outputData = outputData.suffix(64 * 1024)
        }
    }

    var isRunning: Bool {
        process.isRunning
    }

    func terminate() {
        cleanup()
        guard process.isRunning else { return }
        process.terminate()
    }

    private func cleanup() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    func outputIfExited() -> String {
        cleanup()
        outputLock.lock()
        defer { outputLock.unlock() }
        return String(decoding: outputData, as: UTF8.self)
    }

    func setTerminationHandler(_ handler: @Sendable @escaping () -> Void) {
        outputLock.lock()
        terminationHandler = handler
        let alreadyExited = !process.isRunning
        outputLock.unlock()
        if alreadyExited {
            handler()
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
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
