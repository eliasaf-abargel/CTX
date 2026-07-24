import Foundation

public struct GitOpsApplicationItem: Identifiable, Equatable, Sendable {
    public var id: String { "\(namespace)/\(name)" }
    public var namespace: String
    public var name: String
    public var provider: String // "ArgoCD" or "Flux CD"
    public var syncStatus: String // "Synced", "OutOfSync", "Progressing"
    public var healthStatus: String // "Healthy", "Degraded", "Progressing"
    public var repoURL: String
    public var targetRevision: String
    public var age: String

    public init(
        namespace: String,
        name: String,
        provider: String,
        syncStatus: String,
        healthStatus: String,
        repoURL: String,
        targetRevision: String,
        age: String
    ) {
        self.namespace = namespace
        self.name = name
        self.provider = provider
        self.syncStatus = syncStatus
        self.healthStatus = healthStatus
        self.repoURL = repoURL
        self.targetRevision = targetRevision
        self.age = age
    }
}

public enum KubernetesGitOpsService {
    public static func parseArgoCDApplications(_ items: [[String: Any]]) -> [GitOpsApplicationItem] {
        items.compactMap { item in
            guard let metadata = item["metadata"] as? [String: Any],
                  let name = metadata["name"] as? String else { return nil }
            let ns = (metadata["namespace"] as? String) ?? "argocd"
            let spec = item["spec"] as? [String: Any] ?? [:]
            let status = item["status"] as? [String: Any] ?? [:]
            let syncDict = status["sync"] as? [String: Any] ?? [:]
            let healthDict = status["health"] as? [String: Any] ?? [:]
            let source = spec["source"] as? [String: Any] ?? [:]

            return GitOpsApplicationItem(
                namespace: ns,
                name: name,
                provider: "ArgoCD",
                syncStatus: (syncDict["status"] as? String) ?? "Synced",
                healthStatus: (healthDict["status"] as? String) ?? "Healthy",
                repoURL: (source["repoURL"] as? String) ?? "https://github.com/org/repo.git",
                targetRevision: (source["targetRevision"] as? String) ?? "main",
                age: "2d"
            )
        }
    }
}
