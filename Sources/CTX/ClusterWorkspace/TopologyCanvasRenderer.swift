import CTXCore
import SwiftUI

struct TopologyCanvasRenderer {
    let graph: ClusterTopologyGraph
    let layout: TopologyGraphLayout.Result
    let labels: [String: String]
    let scale: CGFloat
    let highlighted: Set<String>?
    let selectedNodeID: String?
    let hoveredNodeID: String?

    func draw(in context: GraphicsContext) {
        drawEdges(in: context)
        drawNodes(in: context)
    }

    private func drawEdges(in context: GraphicsContext) {
        for edge in graph.edges {
            guard let (start, end) = layout.anchors(from: edge.source, to: edge.target) else { continue }
            let isLit = highlighted.map { $0.contains(edge.source) && $0.contains(edge.target) } ?? true
            let leadsToFault = graph.node(edge.target)?.health.needsAttention == true
            let color: Color = !isLit
                ? .secondary
                : leadsToFault ? .red : (highlighted == nil ? .secondary : .accentColor)
            context.stroke(
                curve(from: start, to: end),
                with: .color(color.opacity(isLit ? (highlighted == nil ? 0.34 : 0.85) : 0.07)),
                style: StrokeStyle(
                    lineWidth: (isLit && highlighted != nil ? 1.6 : 1) / max(scale, 0.35),
                    lineCap: .round
                )
            )
        }
    }

    private func drawNodes(in context: GraphicsContext) {
        for node in graph.nodes {
            guard let frame = layout.frame(node.id) else { continue }
            let isAnchor = node.id == selectedNodeID
            let isHovered = node.id == hoveredNodeID
            let alpha = (highlighted?.contains(node.id) ?? true) ? 1.0 : 0.22
            let pill = Path(roundedRect: frame, cornerRadius: 6, style: .continuous)

            context.fill(
                pill,
                with: .color(isAnchor
                    ? Color.accentColor.opacity(0.18 * alpha)
                    : Color.primary.opacity((isHovered ? 0.10 : 0.055) * alpha))
            )
            context.stroke(
                pill,
                with: .color(border(node, isAnchor: isAnchor, isHovered: isHovered).opacity(alpha)),
                lineWidth: (isAnchor ? 1.8 : 1) / max(scale, 0.5)
            )

            let chip = CGRect(x: frame.minX + 8, y: frame.midY - 8, width: 30, height: 16)
            let tint = node.kind.topologyTint
            context.fill(
                Path(roundedRect: chip, cornerRadius: 4, style: .continuous),
                with: .color(tint.opacity(0.18 * alpha))
            )
            context.draw(
                Text(node.kind.code)
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(tint.opacity(alpha)),
                at: CGPoint(x: chip.midX, y: chip.midY)
            )
            // `context.draw(_:at:anchor:)` draws at the text's own natural width with
            // no clipping — it doesn't take a `some View` with `.lineLimit`/
            // `.truncationMode` either, only a literal `Text`. So the string itself is
            // pre-truncated to what actually fits between the kind chip and the health
            // badge; without this, any name longer than that (most generated pod names,
            // once a hash suffix is added) painted straight through the node's border
            // and into whatever was next to it on the canvas.
            let labelStartX = chip.maxX + 7
            let labelWidth = max(0, frame.maxX - 24 - labelStartX)
            context.draw(
                Text(Self.truncatedForCanvas(labels[node.id] ?? node.name, maxWidth: labelWidth))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(alpha)),
                at: CGPoint(x: labelStartX, y: frame.midY),
                anchor: .leading
            )

            if node.issueCount > 0 {
                let badge = CGRect(x: frame.maxX - 20, y: frame.midY - 7, width: 14, height: 14)
                context.fill(Path(ellipseIn: badge), with: .color(Color.orange.opacity(0.95 * alpha)))
                context.draw(
                    Text("\(node.issueCount)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(alpha)),
                    at: CGPoint(x: badge.midX, y: badge.midY)
                )
            } else if !node.health.isHealthy {
                let dot = CGRect(x: frame.maxX - 14, y: frame.midY - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: dot), with: .color(node.health.topologyTint.opacity(alpha)))
            }
        }
    }

    /// A character-count estimate rather than real glyph measurement — this runs
    /// once per node on every canvas redraw, including during pan/zoom, so
    /// measuring actual text width there would cost far more than the few
    /// points of slack this estimate can be off by.
    private static func truncatedForCanvas(_ text: String, maxWidth: CGFloat, fontSize: CGFloat = 11) -> String {
        guard maxWidth > 0 else { return "" }
        let averageGlyphWidth = fontSize * 0.56
        let budget = max(1, Int(maxWidth / averageGlyphWidth))
        guard text.count > budget else { return text }
        guard budget > 1 else { return "…" }
        return String(text.prefix(budget - 1)) + "…"
    }

    private func curve(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        let reach = max((end.x - start.x) * 0.5, 26)
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + reach, y: start.y),
            control2: CGPoint(x: end.x - reach, y: end.y)
        )
        return path
    }

    private func border(_ node: TopologyGraphNode, isAnchor: Bool, isHovered: Bool) -> Color {
        if isAnchor { return .accentColor }
        if node.issueCount > 0 { return Color.orange.opacity(0.7) }
        if node.health.needsAttention { return node.health.topologyTint.opacity(0.7) }
        return .primary.opacity(isHovered ? 0.3 : 0.13)
    }
}
