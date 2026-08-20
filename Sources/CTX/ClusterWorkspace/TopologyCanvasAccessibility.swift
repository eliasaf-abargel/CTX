import CTXCore
import SwiftUI

/// The semantic stand-in for the pills the Canvas paints.
///
/// A Canvas draws pixels, so assistive technology sees one opaque rectangle.
/// `accessibilityRepresentation` swaps this view in for it, giving every node a
/// real control without adding a rendered SwiftUI view per node to the drawing
/// path. Two details are what make it usable rather than merely present:
///
///   - The container only *groups*. Labelling it without `children: .contain`
///     turns the whole map back into a single element and the nodes stop being
///     reachable at all.
///   - Each control is placed at the frame its pill currently occupies on
///     screen, and walked in drawn order, so the VoiceOver cursor moves through
///     the map the way the map looks: left to right along the lineage, top to
///     bottom within a column.
struct TopologyCanvasAccessibility: View {
    let graph: ClusterTopologyGraph
    let layout: TopologyGraphLayout.Result
    /// Drawn order, from the hit index that already knows the columns.
    let orderedNodeIDs: [String]
    let groupsByNodeID: [String: TopologyProjectedGroup]
    let selectedNodeID: String?
    let pan: CGSize
    let scale: CGFloat
    let onSelect: (String) -> Void
    let onExpand: (String) -> Void

    var body: some View {
        let nodes = orderedNodeIDs.compactMap(graph.node)
        ZStack(alignment: .topLeading) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { position, node in
                control(node, order: nodes.count - position)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Cluster map with \(graph.nodes.count) objects and \(graph.edges.count) connections"
        )
    }

    @ViewBuilder
    private func control(_ node: TopologyGraphNode, order: Int) -> some View {
        let group = groupsByNodeID[node.id]
        let frame = viewFrame(node.id)
        Button {
            onSelect(node.id)
        } label: {
            Text(node.name)
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .accessibilitySortPriority(Double(order))
        .accessibilityLabel("\(node.kind.title), \(node.name)")
        .accessibilityValue(value(node, group: group))
        .accessibilityHint(group == nil
            ? "Selects this object and highlights its lineage."
            : "Selects this group. Use the Expand action to bring its objects onto the map.")
        .accessibilityAddTraits(node.id == selectedNodeID ? .isSelected : [])
        .topologyExpandAction(group: group) { onExpand(node.id) }
    }

    /// Graph coordinates through the same pan and zoom the Canvas draws with,
    /// so the control sits under the pill it stands for.
    private func viewFrame(_ id: String) -> CGRect {
        guard let frame = layout.frame(id) else { return .zero }
        return CGRect(
            x: frame.minX * scale + pan.width,
            y: frame.minY * scale + pan.height,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }

    private func value(
        _ node: TopologyGraphNode,
        group: TopologyProjectedGroup?
    ) -> String {
        var parts = [
            "Health \(node.health.summaryTitle)",
            "Namespace \(node.namespace)"
        ]
        if let group {
            parts.append("represents \(group.hiddenCount) objects")
        }
        if !node.subtitle.isEmpty {
            parts.append(node.subtitle)
        }
        return parts.joined(separator: ", ")
    }
}

private extension View {
    /// Only a synthetic node stands for objects that can be brought onto the
    /// map, so only a synthetic node offers the action.
    @ViewBuilder
    func topologyExpandAction(
        group: TopologyProjectedGroup?,
        action: @escaping () -> Void
    ) -> some View {
        if let group {
            accessibilityAction(named: Text("Expand \(group.hiddenCount) represented objects"), action)
        } else {
            self
        }
    }
}
