import Foundation

public struct KubeConfigDiscoveryResult: Sendable {
    public var contexts: [KubernetesContextProfile]
    public var currentContext: String
    public var errors: [KubeConfigDiscoveryError]

    public init(
        contexts: [KubernetesContextProfile],
        currentContext: String = "",
        errors: [KubeConfigDiscoveryError] = []
    ) {
        self.contexts = contexts
        self.currentContext = currentContext
        self.errors = errors
    }
}

public struct KubeConfigDiscoveryError: Error, Equatable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public final class KubeConfigDiscoveryService: Sendable {
    private let environment: @Sendable () -> [String: String]
    private let customPath: @Sendable () -> String?

    public init(
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        customPath: @escaping @Sendable () -> String? = { UserDefaults.standard.string(forKey: "customKubeconfigPath") }
    ) {
        self.environment = environment
        self.customPath = customPath
    }

    public func discover() -> KubeConfigDiscoveryResult {
        discover(paths: candidatePaths())
    }

    public func discover(paths: [URL]) -> KubeConfigDiscoveryResult {
        var contextsByName: [String: KubernetesContextProfile] = [:]
        var errors: [KubeConfigDiscoveryError] = []
        var firstCurrentContext = ""

        for url in deduplicated(paths) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let parsed = parse(text, path: url.path)
                if firstCurrentContext.isEmpty {
                    firstCurrentContext = parsed.currentContext
                }
                for context in parsed.contexts {
                    if contextsByName[context.contextName] == nil {
                        contextsByName[context.contextName] = context
                    }
                }
            } catch {
                errors.append(KubeConfigDiscoveryError(path: url.path, message: error.localizedDescription))
            }
        }

        let contexts = contextsByName.values.sorted {
            if $0.contextName == $1.contextName {
                return $0.kubeconfigPath.localizedStandardCompare($1.kubeconfigPath) == .orderedAscending
            }
            return $0.contextName.localizedStandardCompare($1.contextName) == .orderedAscending
        }

        return KubeConfigDiscoveryResult(
            contexts: contexts,
            currentContext: firstCurrentContext,
            errors: errors
        )
    }

    public func candidatePaths() -> [URL] {
        if let custom = customPath()?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return [URL(fileURLWithPath: expandedHome(custom))]
        }

        if let kubeconfig = environment()["KUBECONFIG"]?.trimmingCharacters(in: .whitespacesAndNewlines), !kubeconfig.isEmpty {
            return kubeconfig
                .split(separator: ":")
                .map { URL(fileURLWithPath: expandedHome(String($0))) }
        }

        return [KubeConfigPaths.defaultConfigURL]
    }

    private func parse(_ text: String, path: String) -> KubeConfigDiscoveryResult {
        var currentContext = ""
        var contexts: [String: KubeContextRecord] = [:]
        var clusters: [String: String] = [:]

        var section = ""
        var currentContextName = ""
        var currentCluster = ""
        var currentUser = ""
        var currentNamespace = ""
        var currentClusterName = ""
        var currentServer = ""

        func commitContext() {
            guard !currentContextName.isEmpty else { return }
            contexts[currentContextName] = KubeContextRecord(
                name: currentContextName,
                cluster: currentCluster,
                user: currentUser,
                namespace: currentNamespace
            )
            currentContextName = ""
            currentCluster = ""
            currentUser = ""
            currentNamespace = ""
        }

        func commitCluster() {
            guard !currentClusterName.isEmpty else { return }
            clusters[currentClusterName] = currentServer
            currentClusterName = ""
            currentServer = ""
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let indent = raw.prefix(while: { $0 == " " }).count
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if indent == 0 {
                if trimmed.hasPrefix("current-context:") {
                    commitContext()
                    commitCluster()
                    currentContext = value(after: "current-context:", in: trimmed)
                    section = ""
                    continue
                }
                if trimmed == "contexts:" {
                    commitContext()
                    commitCluster()
                    section = "contexts"
                    continue
                }
                if trimmed == "clusters:" {
                    commitContext()
                    commitCluster()
                    section = "clusters"
                    continue
                }
                if !trimmed.hasPrefix("-") {
                    commitContext()
                    commitCluster()
                    section = ""
                    continue
                }
                // A top-level "- " line always starts a new list item under
                // contexts:/clusters:, whichever key leads it — `aws eks
                // update-kubeconfig` and merged kubeconfigs write "- cluster:"
                // or "- context:" first and put `name:` on a later sibling
                // line, not "- name:" as the opening key. Flushing here (rather
                // than only when the opener happens to be "- name:") is what
                // makes both orderings parse correctly.
                switch section {
                case "contexts": commitContext()
                case "clusters": commitCluster()
                default: break
                }
            }

            switch section {
            case "contexts":
                if trimmed.hasPrefix("- name:") {
                    currentContextName = value(after: "- name:", in: trimmed)
                } else if trimmed.hasPrefix("name:") {
                    currentContextName = value(after: "name:", in: trimmed)
                } else if trimmed.hasPrefix("cluster:") {
                    currentCluster = value(after: "cluster:", in: trimmed)
                } else if trimmed.hasPrefix("user:") {
                    currentUser = value(after: "user:", in: trimmed)
                } else if trimmed.hasPrefix("namespace:") {
                    currentNamespace = value(after: "namespace:", in: trimmed)
                }
            case "clusters":
                if trimmed.hasPrefix("- name:") {
                    currentClusterName = value(after: "- name:", in: trimmed)
                } else if trimmed.hasPrefix("name:") {
                    currentClusterName = value(after: "name:", in: trimmed)
                } else if trimmed.hasPrefix("server:") {
                    currentServer = value(after: "server:", in: trimmed)
                }
            default:
                continue
            }
        }

        commitContext()
        commitCluster()

        let profiles = contexts.values.map { record in
            let server = clusters[record.cluster] ?? ""
            let environment = EnvironmentDetector.detect(contextName: record.name, clusterName: record.cluster)
            let provider = KubernetesProviderDetector.detect(
                contextName: record.name,
                clusterName: record.cluster,
                serverURL: server
            )
            return KubernetesContextProfile(
                contextName: record.name,
                clusterName: record.cluster,
                userName: record.user,
                namespace: record.namespace,
                kubeconfigPath: path,
                providerType: provider,
                environmentDetection: environment,
                isCurrent: record.name == currentContext,
                clusterMetadata: ClusterMetadata(id: record.cluster.isEmpty ? record.name : record.cluster, name: record.cluster, serverURL: server)
            )
        }

        return KubeConfigDiscoveryResult(contexts: profiles, currentContext: currentContext)
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    private func expandedHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
    }

    private func value(after key: String, in line: String) -> String {
        var value = String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}

private struct KubeContextRecord {
    var name: String
    var cluster: String
    var user: String
    var namespace: String
}
