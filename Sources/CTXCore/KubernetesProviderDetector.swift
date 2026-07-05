import Foundation

public enum KubernetesProviderDetector {
    public static func detect(contextName: String, clusterName: String, serverURL: String) -> KubernetesProviderType {
        let haystack = [contextName, clusterName, serverURL].joined(separator: " ").lowercased()

        if haystack.contains("eks") || haystack.contains("amazonaws.com") {
            return .eks
        }
        if haystack.contains("gke") || haystack.contains("google") || haystack.contains("gcp") {
            return .gke
        }
        if haystack.contains("aks") || haystack.contains("azmk8s") || haystack.contains("azure") {
            return .aks
        }
        if haystack.contains("kind-")
            || haystack.contains("minikube")
            || haystack.contains("docker-desktop")
            || haystack.contains("127.0.0.1")
            || haystack.contains("localhost") {
            return .local
        }

        return .unknown
    }
}
