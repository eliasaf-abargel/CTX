import Foundation

/// Restore points for the provider configuration files CTX edits.
///
/// Those files are also written by hand and by the vendor's own CLI, so anything that
/// overwrites or removes one leaves a copy beside it first.
public enum ConfigBackup {
    /// Returns the backup's location, or `nil` when there was nothing to copy.
    @discardableResult
    public static func snapshot(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let backupURL = url
            .deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).ctx-backup-\(stamp())")
        try FileManager.default.copyItem(at: url, to: backupURL)
        return backupURL
    }

    /// UTC so backups sort chronologically across machines, with a random suffix so two
    /// edits in the same second cannot collide.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
    }
}
