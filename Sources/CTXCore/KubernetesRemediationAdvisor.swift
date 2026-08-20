import Foundation

public struct RemediationAdvice: Equatable, Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    public var category: String
    public var cause: String
    public var suggestedActions: [String]
    public var kubectlCommand: String?

    public init(
        title: String,
        category: String,
        cause: String,
        suggestedActions: [String],
        kubectlCommand: String? = nil
    ) {
        self.title = title
        self.category = category
        self.cause = cause
        self.suggestedActions = suggestedActions
        self.kubectlCommand = kubectlCommand
    }
}

public enum KubernetesRemediationAdvisor {
    public static func analyze(row: KubernetesResourceRow) -> RemediationAdvice? {
        let status = (row.cells["Status"] ?? row.cells["Ready"] ?? row.cells["Reason"] ?? "").lowercased()
        let message = (row.cells["Message"] ?? "").lowercased()

        let cleanName = row.name.components(separatedBy: ".").first ?? row.name
        let ns = row.namespace ?? "default"

        if status.contains("crash") || status.contains("backoff") {
            return RemediationAdvice(
                title: "CrashLoopBackOff",
                category: "Pod Failure",
                cause: "Container process exited repeatedly after starting.",
                suggestedActions: [],
                kubectlCommand: "kubectl logs \(cleanName) --previous -n \(ns)"
            )
        }

        if status.contains("failedscheduling") || message.contains("0/8 nodes") || message.contains("insufficient") {
            return RemediationAdvice(
                title: "Pod Scheduling Failure",
                category: "Resource Constraint",
                cause: "Insufficient CPU or Memory available across cluster nodes.",
                suggestedActions: [],
                kubectlCommand: "kubectl describe pod \(cleanName) -n \(ns)"
            )
        }

        if status.contains("failedattachvolume") || message.contains("failedattachvolume") || status.contains("pvcunbound") {
            return RemediationAdvice(
                title: "Volume Attachment Issue",
                category: "Storage",
                cause: "PersistentVolume cannot be attached to scheduled node.",
                suggestedActions: [],
                kubectlCommand: "kubectl get pvc -n \(ns)"
            )
        }

        if status.contains("imagepull") || status.contains("errimage") {
            return RemediationAdvice(
                title: "Image Pull Failure",
                category: "Registry Auth",
                cause: "Node could not pull container image (tag or auth issue).",
                suggestedActions: [],
                kubectlCommand: "kubectl describe pod \(cleanName) -n \(ns)"
            )
        }

        if row.warning {
            return RemediationAdvice(
                title: "Resource Warning",
                category: "Operational Notice",
                cause: "Resource is reporting warning conditions or non-ready state.",
                suggestedActions: [
                    "Review recent events for this object using `kubectl describe`.",
                    "Inspect log output for errors."
                ],
                kubectlCommand: "kubectl describe \(row.name) --namespace \(row.namespace ?? "default")"
            )
        }

        return nil
    }

    /// A workload-hygiene score over pod rows.
    ///
    /// Deliberately pods only. Workload rows carry no CPU or memory cells at all —
    /// the workloads list never requests them — so every workload used to lose the
    /// full 30 points for "no resource requests" that were never fetched in the
    /// first place, dragging the whole cluster's score down by construction.
    public static func workloadHygieneScore(pods: [KubernetesResourceRow]) -> Int {
        guard !pods.isEmpty else { return 100 }
        let total = pods.reduce(0) { $0 + workloadHygieneScore(pod: $1) }
        return max(0, min(100, total / pods.count))
    }

    public static func workloadHygieneScore(pod row: KubernetesResourceRow) -> Int {
        var score = 100
        let status = (row.cells["Status"] ?? row.cells["Ready"] ?? "").lowercased()
        let restarts = Int(row.cells["Restarts"] ?? "0") ?? 0

        if row.warning || status.contains("crash") || status.contains("err") {
            score -= 40
        }
        if restarts > 5 {
            score -= 20
        } else if restarts > 0 {
            score -= 10
        }
        // Requests are read from the raw cells the parser records for telemetry, not
        // from the display cells: those now render the unknown marker for a pod that
        // declares nothing, which the previous `== "-"` check silently stopped
        // recognising — so unset requests quietly stopped costing anything.
        if (row.cells["CPU Request Cores"] ?? "").isEmpty {
            score -= 15
        }
        if (row.cells["Memory Request Bytes"] ?? "").isEmpty {
            score -= 15
        }
        // A pod with no memory limit cannot be bounded by the kubelet at all.
        if (row.cells["Memory Limit"] ?? "").isEmpty {
            score -= 10
        }

        return max(0, min(100, score))
    }
}
