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

    @discardableResult
    public func useContext(_ name: String) async -> CommandResult {
        await runner.run(["kubectl", "config", "use-context", name])
    }

    @discardableResult
    public func clearCurrentContext() async -> CommandResult {
        await runner.run(["kubectl", "config", "unset", "current-context"])
    }

    public func addContext(name: String, server: String, cluster: String, user: String, namespace: String, token: String?) async throws {
        try await addContext(name: name, server: server, cluster: cluster, user: user, namespace: namespace, credential: .bearerToken(token))
    }

    public func addContext(name: String, server: String, cluster: String, user: String, namespace: String, credential: KubeConfigCredential) async throws {
        try validate(name: name, server: server)
        let clusterName = cluster.isEmpty ? "\(name)-cluster" : cluster
        let userName = user.isEmpty ? "\(name)-user" : user

        try await setCluster(name: clusterName, server: server, failurePrefix: "Failed to configure cluster")
        try await setCredentials(userName, clusterName: clusterName, credential: credential, failurePrefix: "Failed to configure credentials")
        try await setContext(
            name: name,
            cluster: clusterName,
            user: credential == .internalProxy ? "" : userName,
            namespace: namespace,
            clearNamespaceWhenEmpty: false,
            failurePrefix: "Failed to configure context"
        )
    }

    public func updateContext(oldName: String, newName: String, server: String, cluster: String, user: String, namespace: String, token: String?) async throws {
        try validate(name: newName, server: server)
        if oldName != newName {
            let result = await runner.run(["kubectl", "config", "rename-context", oldName, newName])
            try requireSuccess(result, "Failed to rename context")
        }

        let clusterName = cluster.isEmpty ? "\(newName)-cluster" : cluster
        let userName = user.isEmpty ? "\(newName)-user" : user
        try await setCluster(name: clusterName, server: server, failurePrefix: "Failed to update cluster")
        try await setCredentials(userName, token: token, failurePrefix: "Failed to update credentials")
        try await setContext(name: newName, cluster: clusterName, user: userName, namespace: namespace, clearNamespaceWhenEmpty: true, failurePrefix: "Failed to update context")
    }

    public func deleteContext(_ name: String) async throws {
        let result = await runner.run(["kubectl", "config", "delete-context", name])
        try requireSuccess(result, "Failed to delete context")
    }

    public func resolveServer(for clusterName: String) async -> String {
        let result = await runner.run([
            "kubectl", "config", "view",
            "-o", "jsonpath={.clusters[?(@.name==\"\(clusterName)\")].cluster.server}"
        ])
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

    private func setCluster(name: String, server: String, failurePrefix: String) async throws {
        var args = [
            "kubectl", "config", "set-cluster", name,
            "--server=\(server)"
        ]
        if server.lowercased().contains("https") {
            args.append("--insecure-skip-tls-verify=true")
        }
        let result = await runner.run(args)
        try requireSuccess(result, failurePrefix)
    }

    private func setCredentials(_ userName: String, token: String?, failurePrefix: String) async throws {
        try await setCredentials(userName, clusterName: "", credential: .bearerToken(token), failurePrefix: failurePrefix)
    }

    private func setCredentials(_ userName: String, clusterName: String, credential: KubeConfigCredential, failurePrefix: String) async throws {
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
        let result = await runner.run(args)
        try requireSuccess(result, failurePrefix)
    }

    private func setContext(name: String, cluster: String, user: String, namespace: String, clearNamespaceWhenEmpty: Bool, failurePrefix: String) async throws {
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
        let result = await runner.run(args)
        try requireSuccess(result, failurePrefix)
    }

    private func requireSuccess(_ result: CommandResult, _ prefix: String) throws {
        guard result.exitCode == 0 else {
            throw KubeConfigMutationError.invalid("\(prefix): \(KubernetesDiagnosticClassifier.sanitize(result.output))")
        }
    }
}
