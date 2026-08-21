import Foundation

public final class KubeConfigMutationService: Sendable {
    internal let kubectl: any KubectlRunning & KubectlConfigurationCommandBuilding
    internal let providerEnvironment: @Sendable () -> [String: String]

    public init(
        kubectl: any KubectlRunning & KubectlConfigurationCommandBuilding = KubectlRunner(),
        providerEnvironment: @escaping @Sendable () -> [String: String] = {
            ProviderCommandEnvironment.overrides()
        }
    ) {
        self.kubectl = kubectl
        self.providerEnvironment = providerEnvironment
    }

    @discardableResult
    public func useContext(_ name: String, kubeconfigPath: String? = nil) async -> CommandResult {
        await run(["config", "use-context", name], kubeconfigPath: kubeconfigPath)
    }

    @discardableResult
    public func clearCurrentContext(kubeconfigPath: String? = nil) async -> CommandResult {
        await run(["config", "unset", "current-context"], kubeconfigPath: kubeconfigPath)
    }

    public func addContext(name: String, server: String, cluster: String, user: String, namespace: String, credential: KubeConfigCredential, skipTLSVerification: Bool = false, kubeconfigPath: String? = nil) async throws {
        try validate(name: name, server: server)
        let clusterName = cluster.isEmpty ? "\(name)-cluster" : cluster
        let userName = user.isEmpty ? "\(name)-user" : user

        try await setCluster(name: clusterName, server: server, skipTLSVerification: skipTLSVerification, kubeconfigPath: kubeconfigPath, failurePrefix: "Failed to configure cluster")
        try await setCredentials(userName, clusterName: clusterName, credential: credential, kubeconfigPath: kubeconfigPath, failurePrefix: "Failed to configure credentials")
        try await setContext(
            name: name,
            cluster: clusterName,
            user: credential == .internalProxy ? "" : userName,
            namespace: namespace,
            clearNamespaceWhenEmpty: false,
            kubeconfigPath: kubeconfigPath,
            failurePrefix: "Failed to configure context"
        )
    }

    public func duplicateContext(
        sourceName: String,
        newName: String,
        cluster: String,
        user: String,
        namespace: String,
        kubeconfigPath: String
    ) async throws {
        let sourceName = normalizedName(sourceName)
        let newName = normalizedName(newName)
        guard !sourceName.isEmpty else {
            throw KubeConfigMutationError.invalid("Source context name is required")
        }
        guard !newName.isEmpty else {
            throw KubeConfigMutationError.invalid("Context name is required")
        }
        guard sourceName != newName else {
            throw KubeConfigMutationError.invalid("Duplicate context name must differ from the source")
        }
        guard !cluster.isEmpty else {
            throw KubeConfigMutationError.invalid("Source context cluster is required")
        }
        guard !kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KubeConfigMutationError.invalid("Source kubeconfig path is required")
        }

        try await setContext(
            name: newName,
            cluster: cluster,
            user: user,
            namespace: namespace,
            clearNamespaceWhenEmpty: false,
            kubeconfigPath: kubeconfigPath,
            failurePrefix: "Failed to duplicate context"
        )
    }

    public func updateContext(
        oldName: String,
        newName: String,
        server: String,
        cluster: String,
        user: String,
        namespace: String,
        credentialUpdate: KubeConfigCredentialUpdate,
        skipTLSVerification: Bool? = nil,
        kubeconfigPath: String? = nil
    ) async throws {
        try validate(name: newName, server: server)
        try validate(credentialUpdate: credentialUpdate)
        if oldName != newName {
            let result = await run(["config", "rename-context", oldName, newName], kubeconfigPath: kubeconfigPath)
            try requireSuccess(result, "Failed to rename context")
        }

        let clusterName = cluster.isEmpty ? "\(newName)-cluster" : cluster
        let userName = user.isEmpty ? "\(newName)-user" : user
        try await setCluster(name: clusterName, server: server, skipTLSVerification: skipTLSVerification, kubeconfigPath: kubeconfigPath, failurePrefix: "Failed to update cluster")
        switch credentialUpdate {
        case .preserveExisting:
            break
        case .replace(let credential):
            // Overwrite in place. Unsetting the user first — as this used to do —
            // meant a failed or interrupted write left the context with no
            // credential at all, and because a duplicated context shares its
            // source's user entry, it took the source's credential down with it.
            // `set-credentials` rewrites only the field being replaced, so a
            // failure here leaves what was already there untouched.
            try await setCredentials(userName, clusterName: clusterName, credential: credential, isReplacement: true, kubeconfigPath: kubeconfigPath, failurePrefix: "Failed to update credentials")
        case .remove:
            try await removeCredentials(userName, kubeconfigPath: kubeconfigPath, failurePrefix: "Failed to remove credentials")
        }
        let contextUser = switch credentialUpdate {
        case .replace(.internalProxy), .remove: ""
        default: userName
        }
        try await setContext(name: newName, cluster: clusterName, user: contextUser, namespace: namespace, clearNamespaceWhenEmpty: true, clearUserWhenEmpty: credentialUpdate != .preserveExisting, kubeconfigPath: kubeconfigPath, failurePrefix: "Failed to update context")

        if case .replace(.bearerToken) = credentialUpdate {
            try await clearStaleExecPlugin(for: userName, kubeconfigPath: kubeconfigPath)
        }
    }

    public func deleteContext(_ name: String, kubeconfigPath: String? = nil) async throws {
        let result = await run(["config", "delete-context", name], kubeconfigPath: kubeconfigPath)
        try requireSuccess(result, "Failed to delete context")
    }

    public func resolveServer(for clusterName: String, kubeconfigPath: String? = nil) async -> String {
        let result = await run([
            "config", "view",
            "-o", "json"
        ], kubeconfigPath: kubeconfigPath)
        guard result.exitCode == 0,
              let data = result.output.data(using: .utf8),
              let config = try? JSONDecoder().decode(KubeConfigServerLookup.self, from: data) else {
            return ""
        }
        return config.clusters?.first(where: { $0.name == clusterName })?.cluster.server ?? ""
    }

}

private struct KubeConfigServerLookup: Decodable {
    struct NamedCluster: Decodable {
        struct Cluster: Decodable {
            let server: String?
        }
        let name: String
        let cluster: Cluster
    }
    let clusters: [NamedCluster]?
}
