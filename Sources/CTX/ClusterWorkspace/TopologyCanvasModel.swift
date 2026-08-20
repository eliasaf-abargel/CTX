import CTXCore
import SwiftUI

/// Layout and labels prepared before the Canvas's first drawing pass.
///
/// Built in `init` and held by `@StateObject`, whose autoclosure means the
/// layout and hit index run once for the view's structural lifetime. Computing
/// either in `onAppear` would produce an empty first frame.
final class TopologyCanvasModel: ObservableObject {
    let layout: TopologyGraphLayout.Result
    let hitIndex: TopologyHitIndex
    @Published private(set) var labels: [String: String]

    init(graph: ClusterTopologyGraph) {
        let layout = TopologyGraphLayout.layout(graph)
        self.layout = layout
        hitIndex = TopologyHitIndex(layout: layout)
        labels = Self.labels(for: graph)
    }

    /// Presentation-only updates must not disturb the stable layout.
    func refreshLabels(for graph: ClusterTopologyGraph) {
        labels = Self.labels(for: graph)
    }

    private static func labels(for graph: ClusterTopologyGraph) -> [String: String] {
        graph.nodes.reduce(into: [:]) { $0[$1.id] = fit(name: $1.name) }
    }

    /// Trim from the front because Kubernetes names differ most at their tail.
    private static func fit(name: String) -> String {
        let budget = 24
        guard name.count > budget else { return name }
        return "…" + name.suffix(budget - 1)
    }
}
