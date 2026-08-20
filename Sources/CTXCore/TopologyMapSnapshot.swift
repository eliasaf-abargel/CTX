import Foundation

/// The three controls above the map, as data.
public struct TopologyMapFilter: Equatable, Sendable {
    public let searchText: String
    public let includesInactive: Bool
    public let needsAttentionOnly: Bool

    public init(
        searchText: String = "",
        includesInactive: Bool = false,
        needsAttentionOnly: Bool = false
    ) {
        self.searchText = searchText
        self.includesInactive = includesInactive
        self.needsAttentionOnly = needsAttentionOnly
    }

    public var selector: TopologySelector? { TopologySelector(searchText) }
    public var isSearching: Bool { selector != nil }
}

/// Everything the map pane needs to decide what to draw, computed once from one
/// pair of graphs.
///
/// The counts and the empty state have to agree, and they can only agree if
/// they come from the same place. The projected graph answers "what is on
/// screen"; the unprojected source graph answers "what does the filter match".
/// Reading the first for both is what made a pod hidden inside a group report
/// "No match" for its own name a moment before the reprojection materialised
/// it.
public struct TopologyMapSnapshot: Sendable {
    /// Why the canvas has nothing to draw — or `.none`, when it does.
    public enum Vacancy: Equatable, Sendable {
        case none
        /// The filters match objects the current projection has not
        /// materialised yet. The map is behind, not empty.
        case awaitingProjection
        case noSearchMatch
        case noAttentionNeeded
        case allInactive
        case noObjects
    }

    /// The projected graph the canvas should draw, after the filters.
    public let graph: ClusterTopologyGraph
    /// Unprojected objects the filters match: the honest denominator.
    public let eligibleSourceNodeIDs: Set<String>
    /// Drawn objects that stand for exactly one real object.
    public let visibleRealCount: Int
    /// Drawn objects that stand for several: pod groups and overflow.
    public let syntheticGroupCount: Int
    public let vacancy: Vacancy

    public var eligibleCount: Int { eligibleSourceNodeIDs.count }

    /// Eligible objects the projection folded into a group or dropped for
    /// budget. Never filter exclusions — those were never eligible.
    public var projectionHiddenCount: Int { max(0, eligibleCount - visibleRealCount) }

    public init(
        projected: ClusterTopologyGraph,
        projection: TopologyProjection?,
        filter: TopologyMapFilter
    ) {
        let filtered = TopologyMapSnapshot.filtering(projected, with: filter)
        let eligible = projection.map { $0.eligibleSourceNodeIDs(filter) }
            ?? Set(filtered.nodes.map(\.id))
        let synthetic = filtered.nodes.count { projection?.groupsByNodeID[$0.id] != nil }

        graph = filtered
        eligibleSourceNodeIDs = eligible
        syntheticGroupCount = synthetic
        visibleRealCount = filtered.nodes.count - synthetic
        vacancy = TopologyMapSnapshot.vacancy(
            drawnCount: filtered.nodes.count,
            eligible: eligible,
            projected: projected,
            filter: filter
        )
    }

    private static func vacancy(
        drawnCount: Int,
        eligible: Set<String>,
        projected: ClusterTopologyGraph,
        filter: TopologyMapFilter
    ) -> Vacancy {
        if drawnCount > 0 { return .none }
        if !eligible.isEmpty { return .awaitingProjection }
        if filter.isSearching { return .noSearchMatch }
        if filter.needsAttentionOnly { return .noAttentionNeeded }
        if !filter.includesInactive, !projected.isEmpty { return .allInactive }
        return .noObjects
    }

    /// The one implementation of the toolbar's filters. `TopologyProjection`
    /// runs it over the source graph for the eligible set; the snapshot runs it
    /// over the projected graph for what to draw.
    static func filtering(
        _ graph: ClusterTopologyGraph,
        with filter: TopologyMapFilter
    ) -> ClusterTopologyGraph {
        var scoped = graph

        if !filter.includesInactive {
            let active = Set(scoped.nodes.filter {
                !$0.health.isIdle && $0.kind != .terminalGroup
            }.map(\.id))
            scoped = scoped.filtered(nodeIDs: active)
        }

        if filter.needsAttentionOnly {
            var related = Set<String>()
            for node in scoped.nodes where node.health.needsAttention {
                related.formUnion(scoped.ancestors(of: node.id))
                related.formUnion(scoped.descendants(of: node.id))
            }
            scoped = scoped.filtered(nodeIDs: related)
        }

        if let selector = filter.selector {
            scoped = scoped.filtered(nodeIDs: selector.resolve(in: scoped))
        }

        return scoped
    }
}
