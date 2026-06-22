import Foundation

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var output: String
}

public final class CloudCommandRunner: Sendable {
    public init() {}

    public func run(_ arguments: [String]) async -> CommandResult {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()

            var args = arguments
            var execPath = "/usr/bin/env"
            
            if let binaryName = arguments.first {
                let fm = FileManager.default
                let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
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
            let additionalPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
            let newPath = (additionalPaths + [existingPath]).joined(separator: ":")
            environment["PATH"] = newPath
            process.environment = environment

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
