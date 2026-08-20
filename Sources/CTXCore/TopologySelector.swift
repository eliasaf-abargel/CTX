import Foundation

/// A dbt-style selector over the graph: `name` highlights, `name+` adds
/// everything downstream, `+name` everything upstream, `+name+` the full
/// lineage. This is the tool that answers "what breaks if this goes"; the
/// four tabbed pseudo-views it replaced could not answer it at all.
public struct TopologySelector {
    public let term: String
    public let upstream: Bool
    public let downstream: Bool

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        upstream = text.hasPrefix("+")
        if upstream { text.removeFirst() }
        downstream = text.hasSuffix("+")
        if downstream { text.removeLast() }
        guard !text.isEmpty else { return nil }
        term = text
    }

    /// Nodes the selector picks out. A bare term matches by name; the `+`
    /// forms expand each match along the real edges.
    public func resolve(in graph: ClusterTopologyGraph) -> Set<String> {
        let seeds = graph.nodes.filter { $0.name.lowercased().contains(term) }
        guard !seeds.isEmpty else { return [] }
        var result = Set(seeds.map(\.id))
        for seed in seeds {
            if upstream { result.formUnion(graph.ancestors(of: seed.id)) }
            if downstream { result.formUnion(graph.descendants(of: seed.id)) }
        }
        return result
    }
}
