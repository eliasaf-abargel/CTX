import Foundation

public enum KubeConfigPaths {
    public static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kube")
            .appendingPathComponent("config")
    }
}

public enum KubeConfigParser {
    public struct Result: Sendable {
        public var currentContext: String
        public var contexts: [CloudProfile]
    }

    /// Parses a kubeconfig YAML for its context names and the current context.
    /// Within the top-level `contexts:` block, the only `name:` keys are the
    /// context names (cluster/user/namespace live under a nested `context:` map),
    /// so capturing them is reliable without a full YAML parser.
    public static func parse(_ text: String) -> Result {
        var current = ""
        var names: [String] = []
        var inContexts = false

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let indent = raw.prefix(while: { $0 == " " }).count
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if indent == 0 {
                if trimmed.hasPrefix("current-context:") {
                    current = value(after: "current-context:", in: trimmed)
                    inContexts = false
                    continue
                } else if trimmed.hasPrefix("contexts:") {
                    inContexts = true
                    continue
                } else if !trimmed.hasPrefix("-") {
                    inContexts = false
                    continue
                }
            }

            guard inContexts else { continue }

            if trimmed.hasPrefix("- name:") {
                names.append(value(after: "- name:", in: trimmed))
            } else if trimmed.hasPrefix("name:") {
                names.append(value(after: "name:", in: trimmed))
            }
        }

        let contexts = Array(Set(names))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { CloudProfile(provider: .kubernetes, name: $0) }

        return Result(currentContext: current, contexts: contexts)
    }

    private static func value(after key: String, in line: String) -> String {
        var v = String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        if v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }
}
