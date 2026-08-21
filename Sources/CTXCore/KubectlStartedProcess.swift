import Foundation

final class KubectlStartedProcess: KubectlProcessHandling, @unchecked Sendable {
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
        outputLock.lock()
        let handler = terminationHandler
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

    private func cleanup() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }
}
