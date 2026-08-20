import Foundation

/// Reads the cross-object references a resource row carries in its cells, so
/// the graph builder can resolve them against the rows it already holds.
enum TopologyRowReferences {
    /// The controller a pod belongs to, read from its `ownerReferences` chain.
    /// The `Owner` cell is either `"Kind/name"` or, for Deployments,
    /// `"ReplicaSet/name-abc123 -> Deployment/name"` — the Deployment on the
    /// right is the one users think of as the owner, so the last hop wins.
    static func owner(
        of pod: KubernetesResourceRow,
        workloadsByKey: [String: KubernetesResourceRow]
    ) -> KubernetesResourceRow? {
        let owner = pod.cells["Owner"] ?? ""
        guard owner != "-", !owner.isEmpty else { return nil }
        let last = owner.components(separatedBy: "->").last?.trimmingCharacters(in: .whitespaces) ?? owner
        guard let slash = last.firstIndex(of: "/") else { return nil }
        let name = String(last[last.index(after: slash)...])
        return workloadsByKey["\(pod.ns)/\(name)"]
    }

    /// The names listed in a comma-separated cell, with the "-" placeholder the
    /// table uses for "none" dropped.
    static func names(in value: String?) -> [String] {
        (value ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "-" }
    }
}

extension KubernetesResourceRow {
    /// Rows are keyed `namespace/name`; cluster-scoped rows fall back to "default"
    /// so key construction stays total.
    var ns: String { namespace ?? "default" }
}
