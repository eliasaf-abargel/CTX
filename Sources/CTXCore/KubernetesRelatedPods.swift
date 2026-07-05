import Foundation

/// Generic Service→Pods and Workload→Pods discovery via standard Kubernetes
/// label-selector matching — the same mechanism `kubectl get pods -l <selector>`
/// uses. No app name, label key, or naming convention is assumed; this only reads
/// `spec.selector` (Service) / `spec.selector.matchLabels` (Deployment/StatefulSet/
/// DaemonSet) against each Pod's own labels, all already captured onto rows by
/// `KubernetesResourceParser` as `"key=value,key2=value2"` strings.
public enum KubernetesRelatedPods {
    public struct Summary: Equatable, Sendable {
        public var total: Int
        public var healthy: Int
        public var needsAttention: Int

        public init(total: Int, healthy: Int, needsAttention: Int) {
            self.total = total
            self.healthy = healthy
            self.needsAttention = needsAttention
        }
    }

    /// Parses the `"key=value,key2=value2"` encoding back into a dictionary.
    /// Empty or malformed entries are dropped rather than throwing — a selector
    /// CTX can't fully parse should resolve to "no match," not a crash.
    public static func parseSelector(_ encoded: String) -> [String: String] {
        guard !encoded.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in encoded.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    /// A pod matches a selector when every selector key/value is present and equal
    /// among the pod's own labels. An empty selector never matches anything — a
    /// Service/Workload with no selector has no discoverable Pods, not "all Pods."
    public static func matches(podLabels: [String: String], selector: [String: String]) -> Bool {
        guard !selector.isEmpty else { return false }
        return selector.allSatisfy { podLabels[$0.key] == $0.value }
    }

    /// Filters `pods` (already-loaded rows, namespace-scoped by the caller) down to
    /// the ones whose `"Labels"` cell satisfies `selector`.
    public static func relatedPods(selector: [String: String], pods: [KubernetesResourceRow]) -> [KubernetesResourceRow] {
        guard !selector.isEmpty else { return [] }
        return pods.filter { matches(podLabels: parseSelector($0.cells["Labels"] ?? ""), selector: selector) }
    }

    public static func summary(selector: [String: String], pods: [KubernetesResourceRow]) -> Summary {
        let related = relatedPods(selector: selector, pods: pods)
        let healthy = related.filter { PodLogSelection.rank(for: $0) == .runningReady }.count
        return Summary(total: related.count, healthy: healthy, needsAttention: related.count - healthy)
    }
}
