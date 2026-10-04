import Foundation

public struct KubeConfigDiscoveryResult: Sendable {
    public var contexts: [KubernetesContextProfile]
    public var currentContext: String
    public var currentContextByPath: [String: String]
    public var errors: [KubeConfigDiscoveryError]

    public init(
        contexts: [KubernetesContextProfile],
        currentContext: String = "",
        currentContextByPath: [String: String] = [:],
        errors: [KubeConfigDiscoveryError] = []
    ) {
        self.contexts = contexts
        self.currentContext = currentContext
        self.currentContextByPath = currentContextByPath
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
        customPath: @escaping @Sendable () -> String? = { UserDefaults.standard.string(forKey: CTXDefaultsKey.kubeconfigPath) }
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
        var currentContextByPath: [String: String] = [:]

        for url in deduplicated(paths) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                errors.append(KubeConfigDiscoveryError(path: url.path, message: "Configuration file is unavailable"))
                continue
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errors.append(KubeConfigDiscoveryError(path: url.path, message: "Configuration file is empty"))
                    continue
                }
                let parsed = parse(text, path: url.path)
                if firstCurrentContext.isEmpty {
                    firstCurrentContext = parsed.currentContext
                }
                currentContextByPath[url.path] = parsed.currentContext
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

        try? LocalDiagnostics.shared.record(step: "kubeconfig_discovery", outcome: errors.isEmpty ? "success" : "read_error", count: contexts.count)
        return KubeConfigDiscoveryResult(
            contexts: contexts,
            currentContext: firstCurrentContext,
            currentContextByPath: currentContextByPath,
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
        var clusters: [String: KubeClusterRecord] = [:]
        var users: [String: KubeCredentialMetadata] = [:]

        var section = ""
        var itemIndent: Int?
        var currentContextName = ""
        var currentCluster = ""
        var currentUser = ""
        var currentNamespace = ""
        var currentClusterName = ""
        var currentServer = ""
        var currentSkipTLSVerification = false
        var currentUserName = ""
        var currentCredentialKind: KubernetesCredentialKind = .none
        var currentUserHasCredentials = false
        var currentAWSProfile: String?
        var nextArgIsAWSProfile = false
        var inAWSProfileEnv = false

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
            clusters[currentClusterName] = KubeClusterRecord(
                server: currentServer,
                skipTLSVerification: currentSkipTLSVerification
            )
            currentClusterName = ""
            currentServer = ""
            currentSkipTLSVerification = false
        }

        func commitUser() {
            guard !currentUserName.isEmpty else { return }
            users[currentUserName] = KubeCredentialMetadata(
                kind: currentCredentialKind,
                isPresent: currentUserHasCredentials,
                awsProfile: currentAWSProfile
            )
            currentUserName = ""
            currentCredentialKind = .none
            currentUserHasCredentials = false
            currentAWSProfile = nil
            nextArgIsAWSProfile = false
            inAWSProfileEnv = false
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
                    commitUser()
                    currentContext = value(after: "current-context:", in: trimmed)
                    section = ""
                    continue
                }
                if trimmed.hasPrefix("contexts:") {
                    commitContext()
                    commitCluster()
                    commitUser()
                    section = "contexts"
                    itemIndent = nil
                    continue
                }
                if trimmed.hasPrefix("clusters:") {
                    commitContext()
                    commitCluster()
                    commitUser()
                    section = "clusters"
                    itemIndent = nil
                    continue
                }
                if trimmed.hasPrefix("users:") {
                    commitContext()
                    commitCluster()
                    commitUser()
                    section = "users"
                    itemIndent = nil
                    continue
                }
                if !trimmed.hasPrefix("-") {
                    commitContext()
                    commitCluster()
                    commitUser()
                    section = ""
                    itemIndent = nil
                    continue
                }
            }

            if let itemIndent, indent <= itemIndent && trimmed.hasPrefix("-") {
                if section == "contexts" {
                    commitContext()
                } else if section == "clusters" {
                    commitCluster()
                } else if section == "users" {
                    commitUser()
                }
            }

            if itemIndent == nil && trimmed.hasPrefix("-") {
                itemIndent = indent
            }

            switch section {
            case "contexts":
                if trimmed.hasPrefix("- name:") {
                    commitContext()
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
                    commitCluster()
                    currentClusterName = value(after: "- name:", in: trimmed)
                } else if trimmed.hasPrefix("name:") {
                    currentClusterName = value(after: "name:", in: trimmed)
                } else if trimmed.hasPrefix("server:") {
                    currentServer = value(after: "server:", in: trimmed)
                } else if trimmed.hasPrefix("insecure-skip-tls-verify:") {
                    currentSkipTLSVerification = value(after: "insecure-skip-tls-verify:", in: trimmed).lowercased() == "true"
                }
            case "users":
                if trimmed.hasPrefix("- name:") {
                    commitUser()
                    currentUserName = value(after: "- name:", in: trimmed)
                } else if trimmed.hasPrefix("name:") {
                    currentUserName = value(after: "name:", in: trimmed)
                } else if trimmed.hasPrefix("token:") {
                    currentCredentialKind = .bearerToken
                    currentUserHasCredentials = !value(after: "token:", in: trimmed).isEmpty
                } else if trimmed.hasPrefix("tokenFile:") || trimmed.hasPrefix("token-file:") {
                    currentCredentialKind = .tokenFile
                    currentUserHasCredentials = true
                } else if trimmed.hasPrefix("exec:") || trimmed.hasPrefix("command:") {
                    currentCredentialKind = .execPlugin
                    currentUserHasCredentials = true
                } else if trimmed.hasPrefix("client-certificate")
                    || trimmed.hasPrefix("client-key") {
                    currentCredentialKind = .clientCertificate
                    currentUserHasCredentials = true
                } else if trimmed.hasPrefix("username:") || trimmed.hasPrefix("password:") {
                    currentCredentialKind = .basicAuth
                    currentUserHasCredentials = true
                } else if trimmed.hasPrefix("auth-provider:") {
                    currentCredentialKind = .authProvider
                    currentUserHasCredentials = true
                }

                if nextArgIsAWSProfile {
                    nextArgIsAWSProfile = false
                    let candidate = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) : trimmed
                    if !candidate.hasPrefix("-") && !candidate.isEmpty {
                        currentAWSProfile = value(after: "", in: candidate)
                    }
                } else if inAWSProfileEnv && trimmed.hasPrefix("value:") {
                    let candidate = value(after: "value:", in: trimmed)
                    if !candidate.isEmpty {
                        currentAWSProfile = candidate
                    }
                    inAWSProfileEnv = false
                } else if trimmed == "- --profile" || trimmed == "--profile" {
                    nextArgIsAWSProfile = true
                } else if trimmed.hasPrefix("- --profile=") || trimmed.hasPrefix("--profile=") {
                    let prefix = trimmed.hasPrefix("- --profile=") ? "- --profile=" : "--profile="
                    let candidate = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    if !candidate.isEmpty {
                        currentAWSProfile = value(after: "", in: candidate)
                    }
                } else if trimmed.contains("AWS_PROFILE") {
                    inAWSProfileEnv = true
                }
            default:
                continue
            }
        }

        commitContext()
        commitCluster()
        commitUser()

        let profiles = contexts.values.map { record in
            let cluster = clusters[record.cluster] ?? KubeClusterRecord()
            let server = cluster.server
            let environment = EnvironmentDetector.detect(contextName: record.name, clusterName: record.cluster)
            let provider = KubernetesProviderDetector.detect(
                contextName: record.name,
                clusterName: record.cluster,
                serverURL: server
            )
            let credential = users[record.user] ?? KubeCredentialMetadata()
            return KubernetesContextProfile(
                contextName: record.name,
                clusterName: record.cluster,
                userName: record.user,
                namespace: record.namespace,
                kubeconfigPath: path,
                providerType: provider,
                environmentDetection: environment,
                isCurrent: record.name == currentContext,
                clusterMetadata: ClusterMetadata(id: record.cluster.isEmpty ? record.name : record.cluster, name: record.cluster, serverURL: server),
                credentialKind: credential.kind,
                hasCredentials: credential.isPresent,
                skipTLSVerification: cluster.skipTLSVerification,
                linkedAWSProfile: credential.awsProfile
            )
        }

        return KubeConfigDiscoveryResult(
            contexts: profiles,
            currentContext: currentContext,
            currentContextByPath: [path: currentContext]
        )
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

private struct KubeCredentialMetadata {
    var kind: KubernetesCredentialKind = .none
    var isPresent = false
    var awsProfile: String? = nil
}

private struct KubeClusterRecord {
    var server = ""
    var skipTLSVerification = false
}
