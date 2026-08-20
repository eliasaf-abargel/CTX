import Foundation

/// What the map's layout is derived from: which objects exist and how they are
/// connected. Two graphs that share this identity lay out identically, so the
/// canvas may redraw one as the other without recomputing positions or
/// refitting the viewport.
///
/// Node names are deliberately absent even though the layout breaks ordering
/// ties by name: a Kubernetes object's name is part of its node id, so a rename
/// is a new id and shows up here anyway.
public struct TopologyStructuralIdentity: Hashable, Sendable {
    public let nodeIDs: [String]
    public let edgeIDs: [String]

    public init(_ graph: ClusterTopologyGraph) {
        nodeIDs = graph.nodes.map(\.id).sorted()
        edgeIDs = graph.edges.map(\.id).sorted()
    }
}

/// What is painted on top of an unchanged layout: the label, the one-line
/// summary and the status mark. A pod that starts crash-looping changes this
/// and not the structure, so its pill recolours in place instead of sending the
/// whole map back to its fitted position.
public struct TopologyPresentationIdentity: Hashable, Sendable {
    public let nodeDescriptors: [String]

    public init(_ graph: ClusterTopologyGraph) {
        nodeDescriptors = graph.nodes.map {
            "\($0.id)|\($0.name)|\($0.subtitle)|\(Self.token(for: $0.health))"
        }.sorted()
    }

    private static func token(for health: TopologyNodeHealthState) -> String {
        switch health {
        case .healthy:
            "healthy"
        case .idle(let reason):
            "idle|\(reason)"
        case .degraded(let reason):
            "degraded|\(reason)"
        case .failed(let reason, let details, let exitCode, let restartCount):
            "failed|\(reason)|\(details)|\(exitCode.map(String.init) ?? "-")|\(restartCount)"
        }
    }
}
