import Foundation

public enum KubernetesProviderType: String, Codable, Sendable {
    case eks
    case gke
    case aks
    case local
    case unknown
}

public enum EnvironmentType: String, Codable, Sendable {
    case production
    case staging
    case development
    case admin
    case unknown
}

public struct EnvironmentDetectionResult: Codable, Equatable, Sendable {
    public var type: EnvironmentType
    public var confidence: Double
    public var source: String

    public init(type: EnvironmentType, confidence: Double, source: String) {
        self.type = type
        self.confidence = confidence
        self.source = source
    }
}

public struct ClusterMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var serverURL: String

    public init(id: String, name: String, serverURL: String = "") {
        self.id = id
        self.name = name
        self.serverURL = serverURL
    }
}

public struct KubernetesContextProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String {
        "\(kubeconfigPath):\(contextName)"
    }

    public var contextName: String
    public var clusterName: String
    public var userName: String
    public var namespace: String
    public var kubeconfigPath: String
    public var providerType: KubernetesProviderType
    public var environmentType: EnvironmentType
    public var environmentDetection: EnvironmentDetectionResult
    public var isCurrent: Bool
    public var clusterMetadata: ClusterMetadata
    public var token: String

    public init(
        contextName: String,
        clusterName: String,
        userName: String = "",
        namespace: String = "",
        kubeconfigPath: String,
        providerType: KubernetesProviderType = .unknown,
        environmentDetection: EnvironmentDetectionResult = EnvironmentDetectionResult(type: .unknown, confidence: 0, source: "none"),
        isCurrent: Bool = false,
        clusterMetadata: ClusterMetadata? = nil,
        token: String = ""
    ) {
        self.contextName = contextName
        self.clusterName = clusterName
        self.userName = userName
        self.namespace = namespace
        self.kubeconfigPath = kubeconfigPath
        self.providerType = providerType
        self.environmentType = environmentDetection.type
        self.environmentDetection = environmentDetection
        self.isCurrent = isCurrent
        self.clusterMetadata = clusterMetadata ?? ClusterMetadata(id: clusterName.isEmpty ? contextName : clusterName, name: clusterName, serverURL: "")
        self.token = token
    }
}

public extension KubernetesContextProfile {
    /// The `--kubeconfig` argument for this context, or nothing when the context
    /// came from the default location.
    ///
    /// `AGENTS.md` requires every kubectl call to preserve the kubeconfig path the
    /// context was actually discovered in. That rule was implemented as a private
    /// copy of these two helpers in eight separate services — byte-identical, and
    /// eight places to get it wrong the next time a reader is added. It belongs on
    /// the context, which is the thing that knows its own path.
    var kubeconfigArguments: [String] {
        resolvedKubeconfigPath.map { ["--kubeconfig", $0] } ?? []
    }

    /// `KUBECONFIG` for the child process, so credential plugins spawned by kubectl
    /// resolve the same file kubectl itself was pointed at.
    var kubeconfigEnvironment: [String: String] {
        resolvedKubeconfigPath.map { ["KUBECONFIG": $0] } ?? [:]
    }

    private var resolvedKubeconfigPath: String? {
        let path = kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
