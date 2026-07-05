import Foundation

public enum KubeConfigMutationError: LocalizedError, Equatable, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

public enum KubeConfigCredential: Equatable, Sendable {
    case internalProxy
    case bearerToken(String?)
    case awsEKS(region: String, profile: String?)
}

public final class KubeConfigMutationService: Sendable {
    private let runner: any CloudCommandRunning

    public init(runner: any CloudCommandRunning = CloudCommandRunner()) {
        self.runner = runner
    }

    /// Every mutation below targets `kubeconfigPath` explicitly (when given) instead
    /// of relying on `kubectl`'s own default resolution — otherwise a context created
    /// or edited while the app is scoped to a custom kubeconfig path (Settings ›
    /// "customKubeconfigPath", or a multi-file `KUBECONFIG`) silently lands in the
    /// wrong file: the write "succeeds" but the app, which reads back from the
    /// configured path, never sees it.
    private func run(_ arguments: [String], kubeconfigPath: String?) async -> CommandResult {
        var args = arguments
        if let path = kubeconfigPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            args.insert(contentsOf: ["--kubeconfig", path], at: 1)
        }
        return await runner.run(args)
    }

    @discardableResult
    public func useContext(_ name: String, kubeconfigPath: String? = nil) async -> CommandResult {
        await run(["kubectl", "config", "use-context", name], kubeconfigPath: kubeconfigPath)
    }

    @discardableResult
    public func clearCurrentContext(kubeconfigPath: String? = nil) async -> CommandResult {
        await run(["kubectl", "config", "unset", "current-context"], kubeconfigPath: kubeconfigPath)
    }

    public func addContext(name: String, server: String, cluster: String, user: String, namespace: String, token: String?, kubeconfigPath: String? = nil) async throws {
        try await addContext(name: name, server: server, cluster: cluster, user: user, namespace: namespace, credential: .bearerToken(token), kubeconfigPath: kubeconfigPath)
    }

    public func addContext(name: String, server: String, cluster: String, user: String, namespace: String, credential: KubeConfigCredential, kubeconfigPath: String? = nil) async throws {
        try validate(name: name, server: server)
        let clusterName = cluster.isEmpty ? "\(name)-cluster" : cluster
        let userName = user.isEmpty ? "\(name)-user" : user

        try await setCluster(name: clusterName, server: server, kubeconfigPath: kubeconfigPath, failurePrefix: "Failed to configure cluster")
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

    public func updateContext(oldName: String, newName: String, server: String, cluster: String, user: String, namespace: String, token: String?, kubeconfigPath: String? = nil) async throws {
        try validate(name: newName, server: server)
        if oldName != newName {
            let result = await run(["kubectl", "config", "rename-context", oldName, newName], kubeconfigPath: kubeconfigPath)
            try requireSuccess(result, "Failed to rename context")
        }

        let clusterName = cluster.isEmpty ? "\(newName)-cluster" : cluster
        let userName = user.isEmpty ? "\(newName)-user" : user
        try await setCluster(name: clusterName, server: server, kubeconfigPath: kubeconfigPath, failurePrefix: "Failed to update cluster")
        try await setCredentials(userName, token: token, kubeconfigPath: kubeconfigPath, failurePrefix: "Failed to update credentials")
        try await setContext(name: newName, cluster: clusterName, user: userName, namespace: namespace, clearNamespaceWhenEmpty: true, kubeconfigPath: kubeconfigPath, failurePrefix: "Failed to update context")
    }

    public func deleteContext(_ name: String, kubeconfigPath: String? = nil) async throws {
        let result = await run(["kubectl", "config", "delete-context", name], kubeconfigPath: kubeconfigPath)
        try requireSuccess(result, "Failed to delete context")
    }

    public func resolveServer(for clusterName: String, kubeconfigPath: String? = nil) async -> String {
        let result = await run([
            "kubectl", "config", "view",
            "-o", "jsonpath={.clusters[?(@.name==\"\(clusterName)\")].cluster.server}"
        ], kubeconfigPath: kubeconfigPath)
        return result.exitCode == 0 ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private func validate(name: String, server: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KubeConfigMutationError.invalid("Context name is required")
        }
        guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KubeConfigMutationError.invalid("API server URL is required")
        }
    }

    private func setCluster(name: String, server: String, kubeconfigPath: String?, failurePrefix: String) async throws {
        var args = [
            "kubectl", "config", "set-cluster", name,
            "--server=\(server)"
        ]
        if server.lowercased().contains("https") {
            args.append("--insecure-skip-tls-verify=true")
        }
        let result = await run(args, kubeconfigPath: kubeconfigPath)
        try requireSuccess(result, failurePrefix)
    }

    private func setCredentials(_ userName: String, token: String?, kubeconfigPath: String?, failurePrefix: String) async throws {
        try await setCredentials(userName, clusterName: "", credential: .bearerToken(token), kubeconfigPath: kubeconfigPath, failurePrefix: failurePrefix)
    }

    private func setCredentials(_ userName: String, clusterName: String, credential: KubeConfigCredential, kubeconfigPath: String?, failurePrefix: String) async throws {
        let args: [String]
        switch credential {
        case .internalProxy:
            return
        case .bearerToken(let token):
            guard let token, !token.isEmpty else { return }
            args = [
                "kubectl", "config", "set-credentials", userName,
                "--token=\(token)"
            ]
        case .awsEKS(let region, let profile):
            let region = region.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clusterName.isEmpty else {
                throw KubeConfigMutationError.invalid("Cluster name is required for AWS EKS authentication")
            }
            guard !region.isEmpty else {
                throw KubeConfigMutationError.invalid("AWS region is required for EKS authentication")
            }
            var execArgs = [
                "kubectl", "config", "set-credentials", userName,
                "--exec-command=aws",
                "--exec-api-version=client.authentication.k8s.io/v1beta1",
                "--exec-interactive-mode=Never",
                "--exec-arg=eks",
                "--exec-arg=get-token",
                "--exec-arg=--cluster-name",
                "--exec-arg=\(clusterName)",
                "--exec-arg=--region",
                "--exec-arg=\(region)"
            ]
            if let profile = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty {
                execArgs.append("--exec-arg=--profile")
                execArgs.append("--exec-arg=\(profile)")
            }
            args = execArgs
        }
        let result = await run(args, kubeconfigPath: kubeconfigPath)
        try requireSuccess(result, failurePrefix)
    }

    private func setContext(name: String, cluster: String, user: String, namespace: String, clearNamespaceWhenEmpty: Bool, kubeconfigPath: String?, failurePrefix: String) async throws {
        var args = [
            "kubectl", "config", "set-context", name,
            "--cluster=\(cluster)"
        ]
        if !user.isEmpty {
            args.append("--user=\(user)")
        }
        if !namespace.isEmpty {
            args.append("--namespace=\(namespace)")
        } else if clearNamespaceWhenEmpty {
            args.append("--namespace=")
        }
        let result = await run(args, kubeconfigPath: kubeconfigPath)
        try requireSuccess(result, failurePrefix)
    }

    private func requireSuccess(_ result: CommandResult, _ prefix: String) throws {
        guard result.exitCode == 0 else {
            throw KubeConfigMutationError.invalid("\(prefix): \(KubernetesDiagnosticClassifier.sanitize(result.output))")
        }
    }
}
