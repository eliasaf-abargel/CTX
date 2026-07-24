import CTXCore
import SwiftUI

struct TopologyNodeCard<Content: View>: View {
    let tint: Color
    let content: Content
    @State private var isHovered = false

    init(tint: Color, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(10)
            .frame(height: 145)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHovered ? tint : tint.opacity(0.24), lineWidth: isHovered ? 1.5 : 1)
            }
            .shadow(color: tint.opacity(isHovered ? 0.18 : 0.04), radius: isHovered ? 10 : 4, x: 0, y: isHovered ? 4 : 2)
            .scaleEffect(isHovered ? 1.025 : 1.0)
            .onHover { hovering in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.72)) {
                    isHovered = hovering
                }
            }
    }
}

extension InteractiveTopologyMapView {
    var ingressNode: some View {
        TopologyNodeCard(tint: .orange) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    IngressVectorIcon()
                    nodeLabel(title: "Ingress", tint: .orange)
                }

                if relation.ingress.isEmpty {
                    emptyCard(title: "Direct Access", subtitle: "Internal / ClusterIP")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(relation.ingress) { ing in
                                itemCard(title: ing.name, subtitle: ing.cells["Hosts"] ?? "No hosts", tint: .orange)
                            }
                        }
                    }
                }
            }
        }
    }

    var serviceNode: some View {
        TopologyNodeCard(tint: .blue) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ServiceVectorIcon()
                    nodeLabel(title: "Service", tint: .blue)
                    Spacer()
                    if let type = relation.service.cells["Type"], type != "-" {
                        Text(type)
                            .font(.system(size: 7, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(relation.service.name)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                    Divider().opacity(0.3)
                    if let ports = relation.service.cells["Ports"], ports != "-" {
                        detailRow(title: "Ports", value: ports)
                    }
                }
            }
        }
    }

    var workloadNode: some View {
        TopologyNodeCard(tint: .purple) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    WorkloadVectorIcon()
                    nodeLabel(title: "Workload", tint: .purple)
                }

                if relation.workloads.isEmpty {
                    emptyCard(title: "No Workload", subtitle: "Standalone Pods")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(relation.workloads) { wl in
                                itemCard(title: wl.name, subtitle: "\(wl.cells["Kind"] ?? "Workload") · \(wl.cells["Ready"] ?? "")", tint: .purple)
                            }
                        }
                    }
                }
            }
        }
    }

    var podsNode: some View {
        TopologyNodeCard(tint: .green) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    PodVectorIcon()
                    nodeLabel(title: "Pod Group", tint: .green)
                    Spacer()
                    Text("\(relation.pods.count) pods")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                if relation.pods.isEmpty {
                    emptyCard(title: "No Pods", subtitle: "0 pods running")
                } else {
                    let running = relation.pods.filter { ($0.cells["Status"] ?? "").lowercased().contains("run") }.count
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            CTXStatusDot(tint: running == relation.pods.count ? .green : .orange, isPulsing: false)
                            Text("\(running)/\(relation.pods.count) Pods Healthy")
                                .font(.system(size: 10, weight: .bold))
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(relation.pods.prefix(3)) { pod in
                                    Text(pod.name)
                                        .font(.system(size: 8, design: .monospaced))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var networkIngressNode: some View {
        TopologyNodeCard(tint: .orange) {
            VStack(alignment: .leading, spacing: 6) {
                nodeLabel(title: "Public Ingress Routes", tint: .orange)
                detailRow(title: "Hosts", value: relation.ingress.compactMap { $0.cells["Hosts"] }.joined(separator: ", "))
                detailRow(title: "TLS", value: relation.ingress.compactMap { $0.cells["TLS"] }.contains("Yes") ? "Enabled (HTTPS)" : "Disabled (HTTP)")
            }
        }
    }

    var networkServiceNode: some View {
        TopologyNodeCard(tint: .blue) {
            VStack(alignment: .leading, spacing: 6) {
                nodeLabel(title: "Service Endpoints", tint: .blue)
                detailRow(title: "Cluster IP", value: relation.service.cells["Cluster IP"] ?? "None")
                detailRow(title: "Target Ports", value: relation.service.cells["Ports"] ?? "-")
            }
        }
    }

    var networkEndpointsNode: some View {
        TopologyNodeCard(tint: .cyan) {
            VStack(alignment: .leading, spacing: 6) {
                nodeLabel(title: "Target Pod IPs", tint: .cyan)
                detailRow(title: "Active Pods", value: "\(relation.pods.count) Target Pods")
            }
        }
    }

    var storagePvcNode: some View {
        TopologyNodeCard(tint: .green) {
            VStack(alignment: .leading, spacing: 6) {
                nodeLabel(title: "Storage Claims (PVC)", tint: .green)
                detailRow(title: "Bound Status", value: "Bound (Capacity 10Gi)")
                detailRow(title: "Access Mode", value: "ReadWriteOnce")
            }
        }
    }

    var storageClassNode: some View {
        TopologyNodeCard(tint: .teal) {
            VStack(alignment: .leading, spacing: 6) {
                nodeLabel(title: "Storage Class & PV", tint: .teal)
                detailRow(title: "Provisioner", value: "ebs.csi.aws.com")
                detailRow(title: "Volume Type", value: "gp3 (SSD)")
            }
        }
    }

    func emptyCard(title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 10, weight: .bold))
            Text(subtitle).font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    func itemCard(title: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .bold)).lineLimit(1)
            Text(subtitle).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    func nodeLabel(title: String, tint: Color) -> some View {
        Text(title.uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.12), in: Capsule())
    }

    func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value).font(.system(size: 9, design: .monospaced)).lineLimit(1)
        }
    }
}
