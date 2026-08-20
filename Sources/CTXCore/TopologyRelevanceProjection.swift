import Foundation

public struct TopologyProjectionOptions: Equatable, Sendable {
    public static let defaultBudget = 200
    public static let hardCeiling = 1_000

    public let budget: Int
    public let perParentCap: Int
    public let sampleNameLimit: Int
    public let expansionBatchSize: Int

    public init(
        budget: Int = defaultBudget,
        perParentCap: Int = 40,
        sampleNameLimit: Int = 5,
        expansionBatchSize: Int = 20
    ) {
        self.budget = min(max(1, budget), Self.hardCeiling)
        self.perParentCap = max(1, perParentCap)
        self.sampleNameLimit = max(1, sampleNameLimit)
        self.expansionBatchSize = max(1, expansionBatchSize)
    }
}

public struct TopologyExpansionState: Equatable, Sendable {
    public private(set) var batchesByGroupID: [String: Int]

    public init(batchesByGroupID: [String: Int] = [:]) {
        self.batchesByGroupID = batchesByGroupID.filter { $0.value > 0 }
    }

    public mutating func expand(_ groupID: String) {
        batchesByGroupID[groupID, default: 0] += 1
    }

    public mutating func collapse(_ groupID: String) {
        batchesByGroupID[groupID] = nil
    }

    public func batchCount(for groupID: String) -> Int {
        batchesByGroupID[groupID] ?? 0
    }
}

public enum TopologySyntheticNodeKind: String, Equatable, Sendable {
    case healthyPods
    case terminalPods
    case overflow
}

public struct TopologyProjectedGroup: Equatable, Sendable {
    public let nodeID: String
    public let kind: TopologySyntheticNodeKind
    public let memberNodeIDs: [String]
    public let sampleNames: [String]
    public let hiddenCount: Int
}

public struct TopologyProjection: Sendable {
    public let graph: ClusterTopologyGraph
    public let groupsByNodeID: [String: TopologyProjectedGroup]
    public var sourceNodeCount: Int { sourceGraph.nodes.count }
    public var sourceEdgeCount: Int { sourceGraph.edges.count }
    private let sourceGraph: ClusterTopologyGraph
    private let options: TopologyProjectionOptions
    private let expansion: TopologyExpansionState
    private let priorityNodeIDs: Set<String>

    fileprivate init(
        graph: ClusterTopologyGraph,
        groupsByNodeID: [String: TopologyProjectedGroup],
        sourceGraph: ClusterTopologyGraph,
        options: TopologyProjectionOptions,
        expansion: TopologyExpansionState,
        priorityNodeIDs: Set<String>
    ) {
        self.graph = graph
        self.groupsByNodeID = groupsByNodeID
        self.sourceGraph = sourceGraph
        self.options = options
        self.expansion = expansion
        self.priorityNodeIDs = priorityNodeIDs
    }

    public func searchNodeIDs(matching term: String) -> Set<String> {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return Set(sourceGraph.nodes.lazy.filter {
            $0.name.lowercased().contains(needle)
        }.map(\.id))
    }

    public func selectorNodeIDs(_ selector: TopologySelector) -> Set<String> {
        selector.resolve(in: sourceGraph)
    }

    /// Source-object IDs the UI filters match. Computing this against the
    /// unprojected graph keeps counts — and the "nothing matches" decision —
    /// independent of pod grouping and the projection budget.
    public func eligibleSourceNodeIDs(_ filter: TopologyMapFilter) -> Set<String> {
        Set(TopologyMapSnapshot.filtering(sourceGraph, with: filter).nodes.map(\.id))
    }

    /// Reprojects with hidden search/focus hits promoted to real nodes. Rebuilding
    /// the replacement map prevents a synthetic edge and its materialized member
    /// edge from representing the same membership simultaneously.
    public func materializing(nodeIDs: Set<String>) -> ClusterTopologyGraph {
        TopologyRelevanceProjector.project(
            sourceGraph,
            options: options,
            expansion: expansion,
            searchNodeIDs: priorityNodeIDs.union(nodeIDs)
        ).graph
    }
}

public enum TopologyRelevanceProjector {
    public static func project(
        _ source: ClusterTopologyGraph,
        options: TopologyProjectionOptions = TopologyProjectionOptions(),
        expansion: TopologyExpansionState = TopologyExpansionState(),
        searchNodeIDs: Set<String> = [],
        focusedNodeID: String? = nil
    ) -> TopologyProjection {
        let priority = searchNodeIDs.union(focusedNodeID.map { [$0] } ?? [])
        let pods = source.nodes.filter { $0.kind == .pod }
        let buckets = Dictionary(grouping: pods) { relationshipKey(for: $0, in: source) }
        var replacement: [String: String] = [:]
        var groups: [TopologyGraphNode] = []
        var metadata: [String: TopologyProjectedGroup] = [:]

        for (key, members) in buckets {
            let sorted = members.sorted { isMoreRelevant($0, than: $1, priority: priority) }
            let terminal = sorted.filter(\.health.isIdle)
            addGroup(
                members: terminal,
                key: key,
                kind: .terminalPods,
                nodeKind: .terminalGroup,
                initiallyVisible: 0,
                options: options,
                expansion: expansion,
                priority: priority,
                replacement: &replacement,
                nodes: &groups,
                metadata: &metadata
            )

            let healthy = sorted.filter { $0.health.isHealthy }
            if healthy.count > options.perParentCap {
                addGroup(
                    members: healthy,
                    key: key,
                    kind: .healthyPods,
                    nodeKind: .podGroup,
                    initiallyVisible: options.perParentCap,
                    options: options,
                    expansion: expansion,
                    priority: priority,
                    replacement: &replacement,
                    nodes: &groups,
                    metadata: &metadata
                )
            }

            let actionable = sorted.filter { !$0.health.isHealthy && !$0.health.isIdle }
            if actionable.count > options.perParentCap {
                addGroup(
                    members: actionable,
                    key: key,
                    kind: .overflow,
                    nodeKind: .overflow,
                    initiallyVisible: options.perParentCap,
                    options: options,
                    expansion: expansion,
                    priority: priority,
                    replacement: &replacement,
                    nodes: &groups,
                    metadata: &metadata
                )
            }
        }

        var projectedNodes = source.nodes.filter { replacement[$0.id] == nil } + groups
        var projectedEdges = source.edges.map {
            TopologyGraphEdge(
                source: replacement[$0.source] ?? $0.source,
                target: replacement[$0.target] ?? $0.target,
                kind: $0.kind
            )
        }

        if projectedNodes.count > options.budget {
            let retained = Set(projectedNodes.sorted {
                isMoreRelevant($0, than: $1, priority: priority)
            }.prefix(options.budget).map(\.id))
            projectedNodes.removeAll { !retained.contains($0.id) }
            projectedEdges.removeAll { !retained.contains($0.source) || !retained.contains($0.target) }
            metadata = metadata.filter { retained.contains($0.key) }
        }

        return TopologyProjection(
            graph: ClusterTopologyGraph(nodes: projectedNodes, edges: projectedEdges),
            groupsByNodeID: metadata,
            sourceGraph: source,
            options: options,
            expansion: expansion,
            priorityNodeIDs: priority
        )
    }

    private static func addGroup(
        members: [TopologyGraphNode],
        key: String,
        kind: TopologySyntheticNodeKind,
        nodeKind: TopologyGraphNodeKind,
        initiallyVisible: Int,
        options: TopologyProjectionOptions,
        expansion: TopologyExpansionState,
        priority: Set<String>,
        replacement: inout [String: String],
        nodes: inout [TopologyGraphNode],
        metadata: inout [String: TopologyProjectedGroup]
    ) {
        guard !members.isEmpty else { return }
        let stableKey = String(key.utf8.reduce(UInt64(1469598103934665603)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }, radix: 16)
        let groupID = "\(nodeKind.rawValue)/\(stableKey)"
        let expanded = expansion.batchCount(for: groupID) * options.expansionBatchSize
        let priorityMembers = members.filter { priority.contains($0.id) }
        let ordinary = members.filter { !priority.contains($0.id) }
        let visibleIDs = Set(priorityMembers.map(\.id) + ordinary.prefix(initiallyVisible + expanded).map(\.id))
        let hidden = members.filter { !visibleIDs.contains($0.id) }
        guard !hidden.isEmpty else { return }

        hidden.forEach { replacement[$0.id] = groupID }
        let samples = hidden.prefix(options.sampleNameLimit).map(\.name)
        let namespace = hidden[0].namespace
        let label = kind == .terminalPods ? "completed pods" : "pods"
        let health: TopologyNodeHealthState = switch kind {
        case .terminalPods: .idle(reason: "Completed")
        case .overflow where hidden.contains(where: { $0.health.needsAttention }):
            .degraded(reason: "\(hidden.count) hidden pods need attention")
        case .healthyPods, .overflow: .healthy
        }
        nodes.append(TopologyGraphNode(
            id: groupID,
            kind: nodeKind,
            name: "\(hidden.count) \(label)",
            namespace: namespace,
            subtitle: samples.joined(separator: ", ") + (hidden.count > samples.count ? "…" : ""),
            health: health,
            row: KubernetesResourceRow(id: groupID, cells: [
                "Namespace": namespace,
                "Name": "\(hidden.count) \(label)",
                "SyntheticKind": kind.rawValue,
                "Pods": samples.joined(separator: ", ")
            ])
        ))
        metadata[groupID] = TopologyProjectedGroup(
            nodeID: groupID,
            kind: kind,
            memberNodeIDs: hidden.map(\.id),
            sampleNames: samples,
            hiddenCount: hidden.count
        )
    }

    private static func relationshipKey(for node: TopologyGraphNode, in graph: ClusterTopologyGraph) -> String {
        let parents = graph.edgesIn(node.id).map(\.source).sorted().joined(separator: ",")
        let children = graph.edgesOut(node.id).map(\.target).sorted().joined(separator: ",")
        let owner = node.row.cells["Owner"] ?? ""
        return "\(node.namespace)|\(owner)|\(parents)|\(children)"
    }

    private static func rank(_ node: TopologyGraphNode, priority: Set<String>) -> (Int, String) {
        if priority.contains(node.id) { return (0, node.id) }
        if node.health.needsAttention { return (1, node.id) }
        if node.kind != .pod { return (2, node.id) }
        if node.health.isHealthy { return (3, node.id) }
        if node.health.isIdle { return (5, node.id) }
        return (4, node.id)
    }

    private static func isMoreRelevant(
        _ lhs: TopologyGraphNode,
        than rhs: TopologyGraphNode,
        priority: Set<String>
    ) -> Bool {
        let left = rank(lhs, priority: priority)
        let right = rank(rhs, priority: priority)
        return left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
    }
}
