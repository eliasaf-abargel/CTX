import Foundation

public enum AuditEventType: String, Codable, Sendable {
    case contextDiscovered
    case contextSelected
    case healthCheckRequested
    case kubectlCommandFailed
    case exportCreated
    case portForwardStarted
    case portForwardStopped
    case yamlDryRun
    case yamlApplied
    case yamlApplyFailed
    case yamlRolledBack
    case mcpApplyBlocked
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
    private let decoder: JSONDecoder

    /// Nobody rotates this file by hand, so it must bound itself: every write
    /// drops entries older than two weeks before appending the new one. The
    /// trail stays useful for "what did CTX just do to my cluster" without
    /// ever becoming a file someone has to notice and clean up.
    private static let retentionWindow: TimeInterval = 14 * 24 * 60 * 60

    public init(fileURL: URL = LocalAuditLogService.defaultLogURL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func record(_ event: AuditEvent) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-Self.retentionWindow)
        var kept = readEvents().filter { $0.timestamp >= cutoff }
        kept.append(sanitized(event))
        try write(kept)
    }

    public static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("ctx")
            .appendingPathComponent("audit.jsonl")
    }

    private func readEvents() -> [AuditEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(AuditEvent.self, from: Data($0)) }
    }

    private func write(_ events: [AuditEvent]) throws {
        let data = events.reduce(into: Data()) { partial, event in
            guard let encoded = try? encoder.encode(event) else { return }
            partial.append(encoded)
            partial.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
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
