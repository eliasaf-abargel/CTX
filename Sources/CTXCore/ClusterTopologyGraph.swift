import Foundation

/// The map's data model: a real directed graph of Kubernetes objects, not a
/// bundle of pre-bucketed lists.
///
/// Every edge here comes from a field Kubernetes itself owns — an Ingress
/// backend name, a Service `spec.selector`, a Pod `ownerReference`, a Pod
/// volume's `claimName`, an HPA `scaleTargetRef`. Nothing is inferred from a
/// resource's *name*. That is the whole difference between a diagram that
/// happens to look like a pipeline and one that tells you what actually calls
/// what: the previous model grouped services by their name prefix and stapled
/// every PVC in the namespace onto every service in it, which is why the same
/// pod showed up under three cards and unrelated services merged into one.
public enum TopologyGraphNodeKind: String, Sendable, Codable, CaseIterable {
    case ingress
    case service
    case workload
    case pod
    /// Several interchangeable healthy pods drawn as one node.
    case podGroup
    /// Successfully completed pods hidden from the active runtime path.
    case terminalGroup
    /// Additional siblings hidden by a projection budget or parent cap.
    case overflow
    case pvc
    case hpa

    /// The column this kind sits in. Lineage flows left to right:
    /// entrypoint → routing → controller → runtime → storage.
    public var layerFloor: Int {
        switch self {
        case .ingress, .hpa: 0
        case .service: 1
        case .workload: 2
        case .pod, .podGroup, .terminalGroup, .overflow: 3
        case .pvc: 4
        }
    }

    public var title: String {
        switch self {
        case .ingress: "Ingress"
        case .service: "Service"
        case .workload: "Workload"
        case .pod: "Pod"
        case .podGroup: "Pods"
        case .terminalGroup: "Completed Pods"
        case .overflow: "More"
        case .pvc: "PersistentVolumeClaim"
        case .hpa: "HorizontalPodAutoscaler"
        }
    }

    public var systemImage: String {
        switch self {
        case .ingress: "arrow.triangle.branch"
        case .service: "point.3.connected.trianglepath.dotted"
        case .workload: "shippingbox"
        case .pod, .podGroup: "circle.grid.3x3"
        case .terminalGroup: "checkmark.circle"
        case .overflow: "ellipsis.circle"
        case .pvc: "internaldrive"
        case .hpa: "arrow.up.and.down.square"
        }
    }

    /// Three-letter chip shown on the node, the way dbt tags a lineage node SRC
    /// / MDL / SEM. Kind is what the chip encodes; health lives elsewhere. Mixing
    /// the two onto one badge is how the old cards ended up unreadable.
    public var code: String {
        switch self {
        case .ingress: "ING"
        case .service: "SVC"
        case .workload: "WKL"
        case .pod: "POD"
        case .podGroup: "PODS"
        case .terminalGroup: "DONE"
        case .overflow: "MORE"
        case .pvc: "PVC"
        case .hpa: "HPA"
        }
    }
}

public struct TopologyGraphNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: TopologyGraphNodeKind
    public let name: String
    public let namespace: String
    /// The one line under the name — real state, never a guessed category.
    public let subtitle: String
    public let health: TopologyNodeHealthState
    public let row: KubernetesResourceRow

    public init(
        id: String,
        kind: TopologyGraphNodeKind,
        name: String,
        namespace: String,
        subtitle: String,
        health: TopologyNodeHealthState,
        row: KubernetesResourceRow
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.namespace = namespace
        self.subtitle = subtitle
        self.health = health
        self.row = row
    }

    public static func == (lhs: TopologyGraphNode, rhs: TopologyGraphNode) -> Bool {
        lhs.id == rhs.id && lhs.health == rhs.health
    }

    public static func id(kind: TopologyGraphNodeKind, rowID: String) -> String {
        "\(kind.rawValue)/\(rowID)"
    }
}

/// Why two objects are connected. Shown as the edge's label in tooltips and in
/// the inspector, so a connection can always be explained rather than just seen.
public enum TopologyGraphEdgeKind: String, Sendable, CaseIterable {
    /// Ingress rule backend → Service (`spec.rules[].http.paths[].backend.service.name`).
    case routes
    /// Service `spec.selector` ⊆ workload `spec.selector.matchLabels`. This is
    /// the edge that keeps the chain intact when a workload is scaled to zero:
    /// there are no Pods to select, but the Service still fronts that
    /// Deployment, and without this edge both cards float unconnected.
    case targets
    /// Service `spec.selector` → Pod labels. Only drawn for pods the Service
    /// reaches *without* going through a targeted workload, so a healthy
    /// Service→Deployment→Pod chain isn't also short-circuited by a redundant
    /// Service→Pod arrow across it.
    case selects
    /// Pod `ownerReferences` → Deployment / StatefulSet / DaemonSet.
    case owns
    /// Pod `spec.volumes[].persistentVolumeClaim.claimName` → PVC.
    case mounts
    /// HPA `spec.scaleTargetRef` → workload.
    case scales

    public var label: String {
        switch self {
        case .routes: "routes to"
        case .targets: "fronts"
        case .selects: "selects"
        case .owns: "manages"
        case .mounts: "mounts"
        case .scales: "scales"
        }
    }
}

public struct TopologyGraphEdge: Identifiable, Hashable, Sendable {
    public var id: String { "\(source)|\(target)|\(kind.rawValue)" }
    public let source: String
    public let target: String
    public let kind: TopologyGraphEdgeKind

    public init(source: String, target: String, kind: TopologyGraphEdgeKind) {
        self.source = source
        self.target = target
        self.kind = kind
    }
}

public struct ClusterTopologyGraph: Sendable {
    public let nodes: [TopologyGraphNode]
    public let edges: [TopologyGraphEdge]

    private let nodesByID: [String: TopologyGraphNode]
    private let outgoing: [String: [TopologyGraphEdge]]
    private let incoming: [String: [TopologyGraphEdge]]

    public var isEmpty: Bool { nodes.isEmpty }

    public init(nodes: [TopologyGraphNode], edges: [TopologyGraphEdge]) {
        // Dedupe defensively: a node reached twice (a pod backing two Services)
        // must stay ONE node with two incoming edges — that shared fan-in is the
        // relationship the map exists to show, and the old builder destroyed it
        // by dropping the pod the second time it was seen.
        var seenNodes = Set<String>()
        var uniqueNodes: [TopologyGraphNode] = []
        for node in nodes where !seenNodes.contains(node.id) {
            seenNodes.insert(node.id)
            uniqueNodes.append(node)
        }
        var seenEdges = Set<String>()
        var uniqueEdges: [TopologyGraphEdge] = []
        for edge in edges {
            guard seenNodes.contains(edge.source), seenNodes.contains(edge.target) else { continue }
            guard edge.source != edge.target, !seenEdges.contains(edge.id) else { continue }
            seenEdges.insert(edge.id)
            uniqueEdges.append(edge)
        }

        self.nodes = uniqueNodes
        self.edges = uniqueEdges
        self.nodesByID = Dictionary(uniqueKeysWithValues: uniqueNodes.map { ($0.id, $0) })
        self.outgoing = Dictionary(grouping: uniqueEdges, by: \.source)
        self.incoming = Dictionary(grouping: uniqueEdges, by: \.target)
    }

    public func node(_ id: String) -> TopologyGraphNode? { nodesByID[id] }
    public func edgesOut(_ id: String) -> [TopologyGraphEdge] { outgoing[id] ?? [] }
    public func edgesIn(_ id: String) -> [TopologyGraphEdge] { incoming[id] ?? [] }

    /// Everything reachable upstream and downstream of `id` — dbt's `+model+`.
    /// Used to highlight one object's full blast radius without hiding the rest
    /// of the graph, so you can see both the lineage and where it sits.
    public func lineage(of id: String) -> Set<String> {
        walk(from: id) { self.edgesOut($0).map(\.target) + self.edgesIn($0).map(\.source) }
    }

    /// Everything this node depends on, walking upstream only — dbt's `+model`.
    public func ancestors(of id: String) -> Set<String> {
        walk(from: id) { self.edgesIn($0).map(\.source) }
    }

    /// Everything that depends on this node, walking downstream only — `model+`.
    public func descendants(of id: String) -> Set<String> {
        walk(from: id) { self.edgesOut($0).map(\.target) }
    }

    private func walk(from id: String, step: (String) -> [String]) -> Set<String> {
        var visited: Set<String> = [id]
        var queue = [id]
        while let current = queue.popLast() {
            for next in step(current) where !visited.contains(next) {
                visited.insert(next)
                queue.append(next)
            }
        }
        return visited
    }

    public func filtered(nodeIDs: Set<String>) -> ClusterTopologyGraph {
        ClusterTopologyGraph(
            nodes: nodes.filter { nodeIDs.contains($0.id) },
            edges: edges.filter { nodeIDs.contains($0.source) && nodeIDs.contains($0.target) }
        )
    }
}
