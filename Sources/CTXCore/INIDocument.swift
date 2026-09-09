import Foundation

/// An INI file edited in place, preserving everything it was not asked to change.
///
/// A provider's configuration holds far more than the handful of fields any one form
/// collects - a gcloud configuration carries compute zones, container clusters and run
/// regions alongside the project and account CTX edits. Rebuilding such a file from
/// those few fields silently discards the rest, so edits go through this instead:
/// every line, comment and blank included, is kept verbatim, and only the key being
/// set is rewritten or appended.
public struct INIDocument {
    private var lines: [String]

    public init(text: String) {
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// Sets `key` within `section`, creating either when missing.
    public mutating func set(_ key: String, to value: String, in section: String) {
        let entry = "\(key) = \(value)"

        guard let start = indexOfSection(section) else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("[\(section)]")
            lines.append(entry)
            return
        }

        // Walk the section; replace the key in place if it is already there, otherwise
        // append after its last non-blank line so trailing spacing survives.
        var cursor = start + 1
        var lastContent = start
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if Self.sectionName(ofLine: trimmed) != nil { break }
            if Self.keyValue(ofLine: trimmed)?.key == key {
                lines[cursor] = entry
                return
            }
            if !trimmed.isEmpty { lastContent = cursor }
            cursor += 1
        }
        lines.insert(entry, at: lastContent + 1)
    }

    public func rendered() -> String {
        lines.joined(separator: "\n")
    }

    private func indexOfSection(_ section: String) -> Int? {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "[\(section)]" }
    }
}

extension INIDocument {
    /// The name inside `[…]`, or `nil` when the line is not a section header.
    static func sectionName(ofLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    /// The `key = value` on a line, or `nil` for a blank, a comment, or anything else.
    ///
    /// One implementation because there were two, and they disagreed: only one skipped
    /// comments. Nothing depended on the difference, which is exactly why it would have
    /// gone on quietly disagreeing.
    static func keyValue(ofLine line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
              let separator = trimmed.firstIndex(of: "=")
        else { return nil }
        return (
            String(trimmed[trimmed.startIndex..<separator]).trimmingCharacters(in: .whitespaces),
            String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        )
    }
}
