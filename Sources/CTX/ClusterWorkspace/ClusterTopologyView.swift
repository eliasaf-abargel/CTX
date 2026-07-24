import AppKit
import CTXCore
import SwiftUI

struct ClusterTopologyView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CTXSectionHeader(title: "Map", subtitle: "Service relationships from loaded Kubernetes selectors")

            ResourceSummaryPanel(
                title: "Topological Service Map",
                detail: "\(viewModel.topologyRelations.count) inter-service relationships discovered",
                badgeTitle: "\(viewModel.topologyRelations.count) services",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                tint: .blue
            )

            if viewModel.topologyRelations.isEmpty && viewModel.isLoading(section: .services) {
                CTXGlassPanel {
                    ResourceSkeletonView(title: "Loading service map")
                }
            } else if viewModel.topologyRelations.isEmpty {
                CTXGlassPanel {
                    CTXEmptyStateView(title: "No services loaded", message: "The map appears after Services are available.", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.topologyRelations) { relation in
                        TopologyServiceCard(
                            service: relation.service,
                            workloads: relation.workloads,
                            pods: relation.pods,
                            ingress: relation.ingress,
                            openHost: openHost
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectedTopologyRelation = relation
                        }
                        .help("Click to open interactive topology map")
                    }
                }
            }
        }
        .onAppear {
            viewModel.loadTopologyResources()
        }
        .sheet(item: $viewModel.selectedTopologyRelation) { relation in
            InteractiveTopologyMapView(viewModel: viewModel, relation: relation)
        }
    }

    private func openHost(_ host: String, tls: Bool) {
        let scheme = tls ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(host)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct TopologyServiceCard: View {
    let service: KubernetesResourceRow
    let workloads: [KubernetesResourceRow]
    let pods: [KubernetesResourceRow]
    let ingress: [KubernetesResourceRow]
    let openHost: (String, Bool) -> Void

    var body: some View {
        CTXGlassPanel(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                header
                relationRow
                if !hosts.isEmpty {
                    hostRow
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 30, height: 30)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(service.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text([service.namespace, service.cells["Type"], service.cells["Ports"]].compactMap(clean).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            CTXStatusBadge(title: "\(pods.count) pod\(pods.count == 1 ? "" : "s")", systemImage: "circle.grid.3x3", tint: pods.isEmpty ? .secondary : .green)
        }
    }

    private var relationRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                relationGroup(title: "Workloads", values: workloads.map(\.name), icon: "shippingbox", tint: .purple)
                relationGroup(title: "Pods", values: pods.map(\.name), icon: "circle.grid.3x3", tint: .green)
            }
            VStack(alignment: .leading, spacing: 8) {
                relationGroup(title: "Workloads", values: workloads.map(\.name), icon: "shippingbox", tint: .purple)
                relationGroup(title: "Pods", values: pods.map(\.name), icon: "circle.grid.3x3", tint: .green)
            }
        }
    }

    private func relationGroup(title: String, values: [String], icon: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            if values.isEmpty {
                Text("None matched")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(values.prefix(2)), id: \.self) { val in
                    TechBrandIconView(name: val)
                }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var hostRow: some View {
        HStack(spacing: 8) {
            ForEach(hosts, id: \.host) { item in
                Button {
                    openHost(item.host, item.tls)
                } label: {
                    Label(item.host, systemImage: item.tls ? "lock.fill" : "globe")
                        .lineLimit(1)
                }
                .buttonStyle(CTXSecondaryButton())
                .help(item.tls ? "Open https://\(item.host)" : "Open http://\(item.host)")
            }
        }
    }

    private var hosts: [(host: String, tls: Bool)] {
        ingress.flatMap { row in
            (row.cells["Hosts"] ?? "")
                .split(separator: ",")
                .map { ($0.trimmingCharacters(in: .whitespacesAndNewlines), row.cells["TLS"] == "Yes") }
        }
    }

    private func clean(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "-" else { return nil }
        return value
    }
}

// MARK: - Animated Connector Lines

struct AnimatedConnectorLine: View {
    let color: Color
    var portVector: String = ":8080"
    @State private var phase: CGFloat = 0

    var body: some View {
        VStack(spacing: 2) {
            Text(portVector)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(color.opacity(0.12), in: Capsule())

            HStack(spacing: 0) {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .shadow(color: color.opacity(0.4), radius: 2)

                LineShape()
                    .stroke(
                        LinearGradient(colors: [color, color.opacity(0.3)], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 1.75, lineCap: .round, dash: [5, 4], dashPhase: phase)
                    )
                    .frame(height: 2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(color)
            }
            .frame(width: 48)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase -= 9
            }
        }
    }
}

struct LineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}
