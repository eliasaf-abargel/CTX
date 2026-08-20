import CoreGraphics

/// Where an arrow key goes on the map.
///
/// Connections first, geometry second: left and right follow an edge, because on
/// a lineage map the object to the right of a Service is the workload it selects
/// rather than whatever happens to be painted nearby. Only when nothing is
/// connected in that direction does the caret fall back to the nearest node the
/// layout put there, which is also all up and down can ever mean.
public enum TopologyKeyboardNavigation {
    /// The node the caret moves to, or `nil` when the press has nowhere to go.
    ///
    /// A press with no caret yet is a landing, not a move: it returns the first
    /// node in visual order. Resolving a starting node and stepping off it in
    /// the same press would skip the node the user was about to be given.
    public static func next(
        from current: String?,
        toward direction: TopologyHitIndex.Direction,
        in graph: ClusterTopologyGraph,
        layout: TopologyGraphLayout.Result,
        hitIndex: TopologyHitIndex
    ) -> String? {
        guard let current else { return hitIndex.orderedNodeIDs.first }
        return connected(to: current, toward: direction, in: graph, layout: layout)
            ?? hitIndex.neighbor(of: current, toward: direction)
    }

    /// The connected node closest to the same row, so following a chain does not
    /// jump across the graph when a node has several dependents.
    private static func connected(
        to id: String,
        toward direction: TopologyHitIndex.Direction,
        in graph: ClusterTopologyGraph,
        layout: TopologyGraphLayout.Result
    ) -> String? {
        let candidates: [String]
        switch direction {
        case .left: candidates = graph.edgesIn(id).map(\.source)
        case .right: candidates = graph.edgesOut(id).map(\.target)
        case .up, .down: return nil
        }
        guard let source = layout.frame(id) else { return candidates.first }
        return candidates.min {
            abs((layout.frame($0)?.midY ?? 0) - source.midY)
                < abs((layout.frame($1)?.midY ?? 0) - source.midY)
        }
    }
}
