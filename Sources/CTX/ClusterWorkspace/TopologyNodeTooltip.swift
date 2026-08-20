import CTXCore
import SwiftUI

/// What the pill cannot show: the untruncated name, and every connection the
/// object takes part in stated in words rather than as a line on the canvas.
enum TopologyNodeTooltip {
    private static let connectionLimit = 5

    static func text(for node: TopologyGraphNode, in graph: ClusterTopologyGraph) -> String {
        var lines = ["\(node.kind.title)/\(node.name)", node.subtitle, node.health.summaryTitle]
        for edge in graph.edgesIn(node.id).prefix(connectionLimit) {
            if let other = graph.node(edge.source) { lines.append("← \(other.name) \(edge.kind.label) this") }
        }
        for edge in graph.edgesOut(node.id).prefix(connectionLimit) {
            if let other = graph.node(edge.target) { lines.append("→ \(edge.kind.label) \(other.name)") }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
