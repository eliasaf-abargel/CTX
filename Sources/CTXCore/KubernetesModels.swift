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
