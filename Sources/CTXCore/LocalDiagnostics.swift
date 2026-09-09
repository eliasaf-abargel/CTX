import Foundation

/// Local metadata only: never accepts command output, credentials, or config text.
public final class LocalDiagnostics: @unchecked Sendable {
    public static let shared = LocalDiagnostics()
    /// Honours `CTX_DIAGNOSTICS_DIR` so a test run does not write into the real one.
    /// `CTXPerfLog` records through the shared instance on every timed step, which meant
    /// the suite filled a person's own diagnostics file and rolled the previous one out.
    public static var directory: URL {
        // getenv, not ProcessInfo: that snapshots the environment on first access, so a
        // value set after launch - as a test harness must - would never be seen.
        if let raw = getenv("CTX_DIAGNOSTICS_DIR") {
            let override = String(cString: raw)
            if !override.isEmpty { return URL(fileURLWithPath: override) }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ctx/diagnostics")
    }
    private let lock = NSLock()
    private let directory: URL
    private let maximumBytes: Int

    public init(directory: URL = LocalDiagnostics.directory, maximumBytes: Int = 2_000_000) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    public func record(step: String, contextID: String = "", durationMs: Int = 0, outcome: String, count: Int = 0, exitCode: Int32? = nil, category: String? = nil) throws {
        // Step/outcome are application-defined labels. Identity is never persisted.
        var entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "step": step, "contextID": CTXPerfLog.safeContextHash(contextID),
            "durationMs": durationMs, "outcome": outcome, "count": count
        ]
        if let exitCode { entry["exitCode"] = exitCode }
        if let category { entry["category"] = category }
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) + Data([10])
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("events.jsonl")
        let previous = directory.appendingPathComponent("events.previous.jsonl")
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > maximumBytes {
            if FileManager.default.fileExists(atPath: previous.path) {
                try FileManager.default.removeItem(at: previous)
            }
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.moveItem(at: file, to: previous)
            }
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data().write(to: file, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
