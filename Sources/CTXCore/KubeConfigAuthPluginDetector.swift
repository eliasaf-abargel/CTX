import Foundation

/// Answers one narrow diagnostic question: does this kubeconfig user entry use
/// an exec-based credential plugin (`aws`, `gke-gcloud-auth-plugin`, a custom SSO
/// helper, etc.)? That's a real, common source of slow `kubectl` calls that CTX
/// has no way to see inside of — the plugin runs as a child of `kubectl` itself,
/// not of CTX — so the most CTX can honestly do is surface *whether one is
/// configured at all*, as one candidate explanation among several.
///
/// Only ever reads the plugin's `command:` name (e.g. `"aws"`) — never its
/// `args:` or `env:`, which could reference role ARNs, profile names, or other
/// values not needed to answer this yes/no question.
public enum KubeConfigAuthPluginDetector {
    public struct Result: Equatable, Sendable {
        public let hasExecPlugin: Bool
        public let command: String?
    }

    /// Scans a kubeconfig's `users:` block for the entry named `userName` and
    /// reports whether it configures `exec:` credentials.
    public static func detect(in text: String, userName: String) -> Result {
        guard !userName.isEmpty else { return Result(hasExecPlugin: false, command: nil) }

        var inUsersBlock = false
        var inTargetUser = false
        var inExecBlock = false
        var command: String?

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = raw.prefix(while: { $0 == " " }).count

            // `kubectl config view`'s own output (and most real kubeconfigs) writes
            // list items at the *same* indent as their parent key — `users:` then
            // `- name: ...` both at column 0 — so a 0-indent line is only a new
            // top-level key when it doesn't start a list item.
            if indent == 0, !trimmed.hasPrefix("-") {
                inUsersBlock = trimmed == "users:"
                if !inUsersBlock {
                    inTargetUser = false
                    inExecBlock = false
                }
                continue
            }
            guard inUsersBlock else { continue }

            if trimmed.hasPrefix("- name:") {
                let name = trimmed.dropFirst("- name:".count).trimmingCharacters(in: .whitespaces)
                inTargetUser = unquoted(name) == userName
                inExecBlock = false
                continue
            }
            guard inTargetUser else { continue }

            if trimmed == "exec:" {
                inExecBlock = true
                continue
            }
            if inExecBlock, trimmed.hasPrefix("command:") {
                command = unquoted(trimmed.dropFirst("command:".count).trimmingCharacters(in: .whitespaces))
                return Result(hasExecPlugin: true, command: command)
            }
        }
        return Result(hasExecPlugin: false, command: nil)
    }

    private static func unquoted(_ value: String) -> String {
        var v = value
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        if v.hasPrefix("'"), v.hasSuffix("'"), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        return v
    }
}
