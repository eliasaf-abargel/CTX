import CTXCore
import SwiftUI

struct TopologyInspectorDetailView: View {
    let node: TopologyGraphNode

    private var rows: [(String, String)] {
        let cells = node.row.cells
        let candidates: [(String, String?)]
        switch node.kind {
        case .ingress:
            candidates = [
                ("Hosts", cells["Hosts"]), ("TLS", cells["TLS"]),
                ("Class", cells["Class"]), ("Age", cells["Age"])
            ]
        case .service:
            candidates = [
                ("Type", cells["Type"]), ("Cluster IP", cells["Cluster IP"]),
                ("External", cells["External"]), ("Ports", cells["Ports"]),
                ("Selector", cells["Selector"]), ("Age", cells["Age"])
            ]
        case .workload:
            candidates = [
                ("Kind", cells["Kind"]), ("Ready", cells["Ready"]),
                ("Available", cells["Available"]), ("Image", cells["Image"]),
                ("Selector", cells["Selector"]), ("Age", cells["Age"])
            ]
        case .pod:
            candidates = [
                ("Status", cells["Status"]), ("Ready", cells["Ready"]),
                ("Restarts", cells["Restarts"]), ("CPU", cells["CPU"]),
                ("Memory", cells["Memory"]), ("QoS", cells["QoS"]),
                ("Pod IP", cells["Pod IP"]), ("Node", cells["Node"]),
                ("Owner", cells["Owner"]), ("Image", cells["Image"]),
                ("Age", cells["Age"])
            ]
        case .pvc:
            candidates = [
                ("Status", cells["Status"]), ("Capacity", cells["Capacity"]),
                ("Storage class", cells["StorageClass"]), ("Access modes", cells["Access Modes"]),
                ("Volume", cells["Volume"]), ("Age", cells["Age"])
            ]
        case .hpa:
            candidates = [
                ("Scales", cells["Reference"]), ("Replicas now", cells["Replicas"]),
                ("Minimum", cells["MinPods"]), ("Maximum", cells["MaxPods"]),
                ("Age", cells["Age"])
            ]
        case .podGroup, .terminalGroup, .overflow:
            candidates = []
        }
        return candidates.compactMap { title, value in
            guard let value, !value.isEmpty, value != "-" else { return nil }
            return (title, value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TopologyInspectorSectionTitle(text: "DETAILS")
            if rows.isEmpty {
                Text("No additional fields reported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.0) { title, value in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(value)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.head)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct TopologyInspectorSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption2, weight: .bold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}
