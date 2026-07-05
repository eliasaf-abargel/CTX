import Foundation

public enum AuditEventType: String, Codable, Sendable {
    case contextDiscovered
    case contextSelected
    case healthCheckRequested
    case kubectlCommandFailed
    case exportCreated
    case portForwardStarted
    case portForwardStopped
}

public struct AuditEvent: Codable, Equatable, Sendable {
    public var type: AuditEventType
    public var timestamp: Date
    public var contextName: String
    public var message: String

    public init(
        type: AuditEventType,
        timestamp: Date = Date(),
        contextName: String = "",
        message: String = ""
    ) {
        self.type = type
        self.timestamp = timestamp
        self.contextName = contextName
        self.message = message
    }
}

public protocol AuditLogging: Sendable {
    func record(_ event: AuditEvent) throws
}

public final class LocalAuditLogService: AuditLogging {
    private let fileURL: URL
    private let encoder: JSONEncoder

    public init(fileURL: URL = LocalAuditLogService.defaultLogURL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public func record(_ event: AuditEvent) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let event = sanitized(event)
        let data = try encoder.encode(event)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([0x0A]))
            try handle.close()
        } else {
            try (data + Data([0x0A])).write(to: fileURL, options: .atomic)
        }
    }

    public static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("ctx")
            .appendingPathComponent("audit.jsonl")
    }

    private func sanitized(_ event: AuditEvent) -> AuditEvent {
        AuditEvent(
            type: event.type,
            timestamp: event.timestamp,
            contextName: scrub(event.contextName),
            message: scrub(event.message)
        )
    }

    private func scrub(_ value: String) -> String {
        let forbidden = ["token", "secret", "password", "authorization", "bearer"]
        let lowercased = value.lowercased()
        if forbidden.contains(where: { lowercased.contains($0) }) {
            return "[redacted]"
        }
        return value
    }
}
