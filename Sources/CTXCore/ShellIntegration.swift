import Foundation

/// Lets a terminal the person opened themselves adopt the profile selected in CTX,
/// through a file CTX owns and a snippet in the shell's rc.
///
/// Safe where `[default]` was not: it is read once at shell start, so a session opened
/// an hour ago never changes underneath the person, and a variable the shell already
/// carries always wins.
public enum ShellIntegration {
    public static let beginMarker = "# >>> CTX shell integration >>>"
    public static let endMarker = "# <<< CTX shell integration <<<"

    public static var selectionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ctx", isDirectory: true)
            .appendingPathComponent("shell-env")
    }

    /// The lines a person adds to their `.zshrc` or `.bashrc`.
    public static var snippet: String {
        """
        \(beginMarker)
        # Adopts the profile selected in CTX for new shells only. A variable this shell
        # already carries always wins, so anything set by hand is never overridden.
        if [ -r "$HOME/.ctx/shell-env" ]; then
          while IFS='=' read -r ctx_key ctx_value; do
            case "$ctx_key" in ''|\\#*) continue ;; esac
            if [ -z "$(printenv "$ctx_key")" ]; then
              export "$ctx_key=$ctx_value"
            fi
          done < "$HOME/.ctx/shell-env"
          unset ctx_key ctx_value
        fi
        \(endMarker)
        """
    }

    /// Records the selection. Values carrying a newline or `=` are skipped rather than
    /// written, since either would let a profile name forge a second assignment.
    public static func writeSelection(
        _ environment: [String: String],
        to url: URL = selectionURL
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let body = environment
            .filter { isWritable($0.key) && isWritable($0.value) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")

        try (body.isEmpty ? "" : body + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    public static func isInstalled(in rcURL: URL) -> Bool {
        guard let text = try? String(contentsOf: rcURL, encoding: .utf8) else { return false }
        return text.contains(beginMarker)
    }

    /// Adds the snippet, replacing an older copy so repeated installs cannot stack up.
    public static func install(into rcURL: URL) throws {
        let existing = (try? String(contentsOf: rcURL, encoding: .utf8)) ?? ""
        if !existing.isEmpty {
            try ConfigBackup.snapshot(rcURL)
        }
        let cleaned = removingSnippet(from: existing)
        let separator = cleaned.isEmpty ? "" : "\n\n"
        try (cleaned + separator + snippet + "\n").write(to: rcURL, atomically: true, encoding: .utf8)
    }

    public static func uninstall(from rcURL: URL) throws {
        guard let existing = try? String(contentsOf: rcURL, encoding: .utf8),
              existing.contains(beginMarker)
        else { return }
        try ConfigBackup.snapshot(rcURL)
        let cleaned = removingSnippet(from: existing)
        try (cleaned.isEmpty ? "" : cleaned + "\n").write(to: rcURL, atomically: true, encoding: .utf8)
    }

    /// Drops every marked block, so a file that somehow gained two is left with none.
    public static func removingSnippet(from text: String) -> String {
        var output: [String] = []
        var skipping = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == beginMarker { skipping = true; continue }
            if trimmed == endMarker { skipping = false; continue }
            if !skipping { output.append(String(line)) }
        }

        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isWritable(_ value: String) -> Bool {
        !value.isEmpty
            && value.rangeOfCharacter(from: .newlines) == nil
            && !value.contains("=")
    }
}
