import Foundation

public enum KubeConfigPaths {
    public static var configURL: URL {
        if let path = UserDefaults.standard.string(forKey: "customKubeconfigPath"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
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
        var contextsDict: [String: CloudProfile] = [:]
        var inContexts = false

        var currentName = ""
        var currentCluster = ""
        var currentUser = ""
        var currentNamespace = ""

        let commitCurrentContext = {
            guard !currentName.isEmpty else { return }
            contextsDict[currentName] = CloudProfile(
                provider: .kubernetes,
                name: currentName,
                accountID: currentCluster,
                roleName: currentUser,
                region: currentNamespace
            )
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let indent = raw.prefix(while: { $0 == " " }).count
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if indent == 0 {
                if trimmed.hasPrefix("current-context:") {
                    current = value(after: "current-context:", in: trimmed)
                    commitCurrentContext()
                    currentName = ""
                    currentCluster = ""
                    currentUser = ""
                    currentNamespace = ""
                    inContexts = false
                    continue
                } else if trimmed.hasPrefix("contexts:") {
                    inContexts = true
                    continue
                } else if !trimmed.hasPrefix("-") {
                    commitCurrentContext()
                    currentName = ""
                    currentCluster = ""
                    currentUser = ""
                    currentNamespace = ""
                    inContexts = false
                    continue
                }
            }

            guard inContexts else { continue }

            if trimmed.hasPrefix("- name:") {
                commitCurrentContext()
                currentCluster = ""
                currentUser = ""
                currentNamespace = ""
                currentName = value(after: "- name:", in: trimmed)
            } else if trimmed.hasPrefix("- context:") {
                commitCurrentContext()
                currentName = ""
                currentCluster = ""
                currentUser = ""
                currentNamespace = ""
            } else if trimmed.hasPrefix("name:") {
                if currentName.isEmpty {
                    currentName = value(after: "name:", in: trimmed)
                }
            } else if trimmed.hasPrefix("cluster:") {
                currentCluster = value(after: "cluster:", in: trimmed)
            } else if trimmed.hasPrefix("user:") {
                currentUser = value(after: "user:", in: trimmed)
            } else if trimmed.hasPrefix("namespace:") {
                currentNamespace = value(after: "namespace:", in: trimmed)
            }
        }

        commitCurrentContext()

        let contexts = contextsDict.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

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
