import Foundation

public enum KubernetesProfileAdapter {
    public static func cloudProfile(from context: KubernetesContextProfile) -> CloudProfile {
        CloudProfile(
            provider: .kubernetes,
            name: context.contextName,
            accountID: context.clusterName,
            roleName: context.userName,
            region: context.namespace
        )
    }
}
