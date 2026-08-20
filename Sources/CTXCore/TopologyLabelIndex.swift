import Foundation

/// Inverted namespace/label index used by topology relationship matching.
///
/// Selector queries intersect posting lists before validating the small
/// candidate set. This avoids repeatedly scanning every pod for every Service
/// or unresolved workload while preserving Kubernetes subset semantics.
struct TopologyLabelIndex {
    private let rowsByID: [String: KubernetesResourceRow]
    private let labelsByID: [String: [String: String]]
    private let postings: [String: [Label: Set<String>]]

    init(
        rows: [KubernetesResourceRow],
        isCancelled: () -> Bool = { false },
        labels: (KubernetesResourceRow) -> [String: String]
    ) {
        var rowsByID: [String: KubernetesResourceRow] = [:]
        var labelsByID: [String: [String: String]] = [:]
        var postings: [String: [Label: Set<String>]] = [:]

        for row in rows {
            guard !isCancelled() else { break }
            let parsed = labels(row)
            rowsByID[row.id] = row
            labelsByID[row.id] = parsed
            for (key, value) in parsed {
                postings[row.topologyNamespace, default: [:]][Label(key: key, value: value), default: []].insert(row.id)
            }
        }

        self.rowsByID = rowsByID
        self.labelsByID = labelsByID
        self.postings = postings
    }

    func matching(namespace: String, selector: [String: String]) -> [KubernetesResourceRow] {
        guard !selector.isEmpty else { return [] }
        let namespacePostings = postings[namespace] ?? [:]
        let candidateSets = selector
            .map { namespacePostings[Label(key: $0.key, value: $0.value)] ?? [] }
            .sorted { $0.count < $1.count }
        guard var candidates = candidateSets.first, !candidates.isEmpty else { return [] }
        for posting in candidateSets.dropFirst() {
            candidates.formIntersection(posting)
            if candidates.isEmpty { return [] }
        }

        return candidates.compactMap { id in
            guard let labels = labelsByID[id],
                  KubernetesRelatedPods.matches(podLabels: labels, selector: selector)
            else { return nil }
            return rowsByID[id]
        }
        .sorted { $0.id < $1.id }
    }

    private struct Label: Hashable {
        let key: String
        let value: String
    }
}

extension KubernetesResourceRow {
    var topologyNamespace: String { namespace ?? "default" }
}
