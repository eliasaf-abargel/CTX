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
}

public final class CloudCommandRunner: CloudCommandRunning {
    public init() {}

    public func run(_ arguments: [String]) async -> CommandResult {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()

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

            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe

            var environment = ProcessInfo.processInfo.environment
            let existingPath = environment["PATH"] ?? ""
            let newPath = (searchDirs + [existingPath]).joined(separator: ":")
            environment["PATH"] = newPath
            process.environment = environment

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return CommandResult(
                    exitCode: process.terminationStatus,
                    output: String(decoding: data, as: UTF8.self)
                )
            } catch {
                return CommandResult(exitCode: 127, output: error.localizedDescription)
            }
        }.value
    }
}
