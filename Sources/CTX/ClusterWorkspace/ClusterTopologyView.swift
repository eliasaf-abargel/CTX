import AppKit
import CTXCore
import SwiftUI

struct ClusterTopologyView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CTXSectionHeader(title: "Map", subtitle: "Service relationships from loaded Kubernetes selectors")

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
                        .onHover { inside in
                            if inside {
                                NSCursor.pointingHand.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        }
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
            Text(values.isEmpty ? "None matched" : values.prefix(3).joined(separator: ", "))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
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

// MARK: - Premium Topological Vector Icons (SVG-style)

struct IngressVectorIcon: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                .background(Circle().fill(.orange.opacity(0.08)))
            
            // Outer ring
            Circle()
                .stroke(.orange.opacity(0.3), lineWidth: 0.75)
                .padding(3)
            
            // Grid lines
            Ellipse()
                .stroke(.orange.opacity(0.6), lineWidth: 1)
                .frame(width: 8)
            
            Rectangle()
                .fill(.orange.opacity(0.6))
                .frame(height: 1)
            
            Rectangle()
                .fill(.orange.opacity(0.6))
                .frame(width: 1)
        }
        .frame(width: 22, height: 22)
    }
}

struct ServiceVectorIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.blue.opacity(0.08)))
            
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let cx = w / 2
                let cy = h / 2
                
                Path { path in
                    // Center Hub
                    path.addEllipse(in: CGRect(x: cx - 2.5, y: cy - 2.5, width: 5, height: 5))
                    
                    // Lines outwards
                    path.move(to: CGPoint(x: cx, y: cy))
                    path.addLine(to: CGPoint(x: cx, y: 4))
                    
                    path.move(to: CGPoint(x: cx, y: cy))
                    path.addLine(to: CGPoint(x: cx - 5.5, y: h - 5))
                    
                    path.move(to: CGPoint(x: cx, y: cy))
                    path.addLine(to: CGPoint(x: cx + 5.5, y: h - 5))
                }
                .stroke(Color.blue, lineWidth: 1.5)
                
                // Terminal Nodes
                Circle().fill(Color.blue).frame(width: 3.5, height: 3.5).position(x: cx, y: 4)
                Circle().fill(Color.blue).frame(width: 3.5, height: 3.5).position(x: cx - 5.5, y: h - 5)
                Circle().fill(Color.blue).frame(width: 3.5, height: 3.5).position(x: cx + 5.5, y: h - 5)
            }
            .padding(2)
        }
        .frame(width: 22, height: 22)
    }
}

struct WorkloadVectorIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.purple.opacity(0.08)))
            
            // Isometric box / cube shape
            Path { path in
                let w: CGFloat = 16
                let cx: CGFloat = 8
                
                // Top
                path.move(to: CGPoint(x: cx, y: 2))
                path.addLine(to: CGPoint(x: 2, y: 5.5))
                path.addLine(to: CGPoint(x: cx, y: 9))
                path.addLine(to: CGPoint(x: w - 2, y: 5.5))
                path.closeSubpath()
                
                // Left
                path.move(to: CGPoint(x: 2, y: 5.5))
                path.addLine(to: CGPoint(x: 2, y: 12.5))
                path.addLine(to: CGPoint(x: cx, y: 16))
                path.addLine(to: CGPoint(x: cx, y: 9))
                path.closeSubpath()
                
                // Right
                path.move(to: CGPoint(x: w - 2, y: 5.5))
                path.addLine(to: CGPoint(x: w - 2, y: 12.5))
                path.addLine(to: CGPoint(x: cx, y: 16))
                path.addLine(to: CGPoint(x: cx, y: 9))
                path.closeSubpath()
            }
            .stroke(Color.purple, lineWidth: 1.25)
            .padding(3)
        }
        .frame(width: 22, height: 22)
    }
}

struct PodVectorIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.green.opacity(0.08)))
            
            // Hexagonal structure
            Path { path in
                let w: CGFloat = 16
                let cx: CGFloat = 8
                
                path.move(to: CGPoint(x: cx, y: 1.5))
                path.addLine(to: CGPoint(x: w - 2.5, y: 5))
                path.addLine(to: CGPoint(x: w - 2.5, y: 12))
                path.addLine(to: CGPoint(x: cx, y: 15.5))
                path.addLine(to: CGPoint(x: 2.5, y: 12))
                path.addLine(to: CGPoint(x: 2.5, y: 5))
                path.closeSubpath()
            }
            .stroke(Color.green, lineWidth: 1.25)
            .padding(3)
            
            Circle()
                .fill(Color.green)
                .frame(width: 4, height: 4)
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Animated Connector Lines

struct AnimatedConnectorLine: View {
    let color: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.4), radius: 2)
            
            LineShape()
                .stroke(
                    LinearGradient(colors: [color, color.opacity(0.3)], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 1.75, lineCap: .round, dash: [5, 4], dashPhase: phase)
                )
                .frame(height: 2)
            
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(color)
        }
        .frame(width: 46)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase -= 9
            }
        }
    }
}

// MARK: - Premium Node Card Container with Hover Effects

private struct TopologyNodeCard<Content: View>: View {
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

// MARK: - Premium Interactive Map View

struct InteractiveTopologyMapView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let relation: TopologyServiceRelation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Ambient neon background glow
            RadialGradient(colors: [.blue.opacity(0.06), .purple.opacity(0.04), .clear], center: .center, startRadius: 10, endRadius: 400)
                .frame(width: 600, height: 260)
                .blur(radius: 20)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TOPOLOGY DISCOVERY MAP")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .tracking(1)
                        
                        HStack(spacing: 8) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .foregroundStyle(.blue)
                            Text(relation.service.name)
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Dismiss")
                }

                // Flow Diagram - Scrollable and Responsive
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 0) {
                        // Node 1: Ingress
                        ingressNode
                            .frame(width: 150)
                        
                        AnimatedConnectorLine(color: relation.ingress.isEmpty ? .secondary.opacity(0.3) : .orange)

                        // Node 2: Service
                        serviceNode
                            .frame(width: 170)

                        AnimatedConnectorLine(color: .blue)

                        // Node 3: Workload
                        workloadNode
                            .frame(width: 160)

                        AnimatedConnectorLine(color: relation.workloads.isEmpty ? .secondary.opacity(0.3) : .purple)

                        // Node 4: Pods
                        podsNode
                            .frame(width: 175)
                    }
                    .padding(.vertical, 6)
                    .frame(minWidth: 750)
                }
                .frame(maxHeight: .infinity)
                
                Divider()

                // Footer / Actions
                HStack {
                    Button {
                        viewModel.selectedPortForwardServiceID = relation.service.id
                        viewModel.selectedSection = .portForward
                        dismiss()
                    } label: {
                        Label("Port Forward to Service", systemImage: "arrowshape.turn.up.right")
                    }
                    .buttonStyle(CTXPrimaryButton())
                    
                    Spacer()
                    
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(CTXSecondaryButton())
                }
            }
            .padding(16)
        }
        .frame(width: 820, height: 330) // Capped height for compact layout with no empty vertical space
        .background(.ultraThinMaterial)
    }

    // MARK: - Nodes

    private var ingressNode: some View {
        TopologyNodeCard(tint: .orange) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    IngressVectorIcon()
                    nodeLabel(title: "Ingress", tint: .orange)
                }
                
                if relation.ingress.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("Direct Access")
                            .font(.system(size: 10, weight: .bold))
                        Text("Internal / ClusterIP")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.separator.opacity(0.12), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 4]))
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(relation.ingress) { ing in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ing.name)
                                        .font(.system(size: 10, weight: .bold))
                                        .lineLimit(1)
                                    let hosts = ing.cells["Hosts"] ?? ""
                                    Text(hosts.isEmpty ? "No hosts" : hosts)
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.orange.opacity(0.18), lineWidth: 0.75)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var serviceNode: some View {
        TopologyNodeCard(tint: .blue) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ServiceVectorIcon()
                    nodeLabel(title: "Service", tint: .blue)
                    Spacer()
                    let serviceType = relation.service.cells["Type"] ?? ""
                    if !serviceType.isEmpty && serviceType != "-" {
                        Text(serviceType)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text(relation.service.name)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                    
                    Divider().opacity(0.3)
                    
                    let ports = relation.service.cells["Ports"] ?? ""
                    if !ports.isEmpty && ports != "-" {
                        detailRow(title: "Ports", value: ports)
                    }
                    
                    let clusterIP = relation.service.cells["Cluster-IP"] ?? ""
                    if !clusterIP.isEmpty && clusterIP != "-" && clusterIP != "None" {
                        detailRow(title: "Cluster IP", value: clusterIP)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var workloadNode: some View {
        TopologyNodeCard(tint: .purple) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    WorkloadVectorIcon()
                    nodeLabel(title: "Workload", tint: .purple)
                }
                
                if relation.workloads.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("No Workload")
                            .font(.system(size: 10, weight: .bold))
                        Text("Standalone Pods")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.separator.opacity(0.12), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 4]))
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(relation.workloads) { wl in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(wl.name)
                                        .font(.system(size: 10, weight: .bold))
                                        .lineLimit(1)
                                    
                                    HStack(spacing: 4) {
                                        Text(wl.cells["Kind"] ?? "Deployment")
                                            .font(.system(size: 8, weight: .semibold))
                                            .foregroundStyle(.purple)
                                        Spacer()
                                        let status = wl.cells["Ready"] ?? wl.cells["Status"] ?? ""
                                        Text(status)
                                            .font(.system(size: 8))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.purple.opacity(0.18), lineWidth: 0.75)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var podsNode: some View {
        TopologyNodeCard(tint: .green) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    PodVectorIcon()
                    nodeLabel(title: "Pods", tint: .green)
                    Spacer()
                    Text("\(relation.pods.count) total")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                
                if relation.pods.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "circle.grid.3x3")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("No Pods")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.separator.opacity(0.12), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 4]))
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(relation.pods.prefix(4)) { pod in
                                HStack(spacing: 6) {
                                    CTXStatusDot(tint: podStatusColor(pod), isPulsing: false)
                                    Text(pod.name)
                                        .font(.system(size: 9, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            
                            if relation.pods.count > 4 {
                                Text("+ \(relation.pods.count - 4) more")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func nodeLabel(title: String, tint: Color) -> some View {
        Text(title.uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().stroke(tint.opacity(0.24), lineWidth: 0.75)
            }
    }

    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func podStatusColor(_ pod: KubernetesResourceRow) -> Color {
        let rank = PodLogSelection.rank(for: pod)
        switch rank {
        case .runningReady: return .green
        case .warning: return .red
        case .pending: return .yellow
        case .completed: return .secondary
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
