import CTXCore
import SwiftUI

struct TopologyNodeInspectorView: View {
    let node: TopologyGraphNode
    let graph: ClusterTopologyGraph
    let group: TopologyProjectedGroup?
    let canCollapse: Bool
    let onSelect: (String) -> Void
    let onOpenInspector: () -> Void
    let onPortForward: (() -> Void)?
    let onShowPods: (() -> Void)?
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onResetExpansion: (() -> Void)?
    let onClose: () -> Void

    private var incoming: [(TopologyGraphEdge, TopologyGraphNode)] {
        graph.edgesIn(node.id).compactMap { edge in
            graph.node(edge.source).map { (edge, $0) }
        }
    }

    private var outgoing: [(TopologyGraphEdge, TopologyGraphNode)] {
        graph.edgesOut(node.id).compactMap { edge in
            graph.node(edge.target).map { (edge, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    health
                    if let group {
                        groupSummary(group)
                    } else {
                        TopologyInspectorDetailView(node: node)
                    }
                    connections
                    actions
                }
                .padding(14)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: node.kind.systemImage)
                .foregroundStyle(node.kind.topologyTint)
                .frame(width: 28, height: 28)
                .background(node.kind.topologyTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.system(size: 12, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("\(node.kind.title) · \(node.namespace)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close inspector (Esc)")
            .accessibilityLabel("Close inspector")
        }
    }

    private var health: some View {
        VStack(alignment: .leading, spacing: 6) {
            TopologyInspectorSectionTitle(text: "HEALTH")
            HStack(spacing: 7) {
                CTXStatusDot(tint: node.health.topologyTint, isPulsing: node.health.isFailed)
                Text(node.health.summaryTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(node.health.topologyTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let reason, let details, let exitCode, let restarts) = node.health {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reason).font(.system(size: 10, weight: .bold, design: .monospaced))
                    if let exitCode { Text("Exit code \(exitCode)") }
                    if restarts > 0 { Text("\(restarts) restarts") }
                    Text(details)
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func groupSummary(_ group: TopologyProjectedGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TopologyInspectorSectionTitle(text: "GROUP")
            Text("\(group.hiddenCount) objects represented")
                .font(.system(size: 12, weight: .semibold))
            if !group.sampleNames.isEmpty {
                Text("Samples")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(group.sampleNames.prefix(5), id: \.self) {
                    Text($0)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: 7) {
                Button("Expand 20", action: onExpand)
                    .buttonStyle(CTXSecondaryButton())
                if canCollapse {
                    Button("Collapse", action: onCollapse)
                        .buttonStyle(CTXSecondaryButton())
                }
            }
            if let onResetExpansion {
                Button("Reset all expansion", action: onResetExpansion)
                    .buttonStyle(CTXInlineActionButton())
            }
        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 7) {
            TopologyInspectorSectionTitle(text: "CONNECTIONS")
            if incoming.isEmpty && outgoing.isEmpty {
                Text("No visible connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(incoming, id: \.0.id) { edge, neighbour in
                    connection(neighbour, label: "\(neighbour.name) \(edge.kind.label) this", inbound: true)
                }
                ForEach(outgoing, id: \.0.id) { edge, neighbour in
                    connection(neighbour, label: "\(edge.kind.label) \(neighbour.name)", inbound: false)
                }
            }
        }
    }

    private func connection(_ neighbour: TopologyGraphNode, label: String, inbound: Bool) -> some View {
        Button { onSelect(neighbour.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: inbound ? "arrow.left" : "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                Image(systemName: neighbour.kind.systemImage)
                    .foregroundStyle(neighbour.kind.topologyTint)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
            }
            .padding(.vertical, 5)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Select \(neighbour.name)")
        .accessibilityLabel(label)
        .accessibilityHint("Selects \(neighbour.name) on the map")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if group == nil {
                Button {
                    onOpenInspector()
                } label: {
                    Label("Open in Inspector", systemImage: "sidebar.trailing")
                }
                .buttonStyle(CTXSecondaryButton())
            }
            if let onShowPods {
                Button(action: onShowPods) {
                    Label("Show in Pods", systemImage: "circle.grid.3x3")
                }
                .buttonStyle(CTXSecondaryButton())
            }
            if let onPortForward {
                Button(action: onPortForward) {
                    Label("Port Forward", systemImage: "arrowshape.turn.up.right")
                }
                .buttonStyle(CTXSecondaryButton())
            }
        }
    }
}
