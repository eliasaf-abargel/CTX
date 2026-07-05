import CTXCore
import Foundation

extension KubernetesContextProfile {
    static var previewProduction: KubernetesContextProfile {
        KubernetesContextProfile(
            contextName: "platform-prod",
            clusterName: "eks-platform-prod",
            userName: "sre-admin",
            namespace: "platform",
            kubeconfigPath: "/Users/example/.kube/config",
            providerType: .eks,
            environmentDetection: EnvironmentDetectionResult(type: .production, confidence: 0.9, source: "context"),
            isCurrent: true,
            clusterMetadata: ClusterMetadata(id: "eks-platform-prod", name: "eks-platform-prod", serverURL: "https://example.eks.amazonaws.com")
        )
    }
}
