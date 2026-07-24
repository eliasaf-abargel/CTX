import AppKit
import CTXCore
import SwiftUI

enum TopologyViewMode: String, CaseIterable, Identifiable {
    case resources = "Resources"
    case network = "Network Traffic"
    case storage = "Storage PVCs"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .resources: "point.3.connected.trianglepath.dotted"
        case .network: "bolt.horizontal.fill"
        case .storage: "internaldrive.fill"
        }
    }
}

struct InteractiveTopologyMapView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let relation: TopologyServiceRelation
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMode: TopologyViewMode = .resources
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastDragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            RadialGradient(colors: [.blue.opacity(0.08), .purple.opacity(0.05), .clear], center: .center, startRadius: 10, endRadius: 500)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                header
                modePicker
                diagramCanvas
                Divider()
                footer
            }
            .padding(16)
        }
        .frame(minWidth: 1000, idealWidth: 1150, maxWidth: 1400, minHeight: 600, idealHeight: 680, maxHeight: 900)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("INTERACTIVE CLUSTER TOPOLOGY MAP")
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
            zoomControls
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    private var modePicker: some View {
        Picker("", selection: $selectedMode) {
            ForEach(TopologyViewMode.allCases) { mode in
                Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 360)
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation { scale = max(0.6, scale - 0.15) }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(CTXSecondaryButton())
            .help("Zoom Out")

            Text("\(Int(scale * 100))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 38)

            Button {
                withAnimation { scale = min(1.8, scale + 0.15) }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(CTXSecondaryButton())
            .help("Zoom In")

            Button {
                withAnimation {
                    scale = 1.0
                    offset = .zero
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(CTXSecondaryButton())
            .help("Reset Zoom & Position")
        }
    }

    private var diagramCanvas: some View {
        GeometryReader { _ in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                HStack(alignment: .center, spacing: 0) {
                    switch selectedMode {
                    case .resources:
                        ingressNode.frame(width: 150)
                        AnimatedConnectorLine(color: relation.ingress.isEmpty ? .secondary.opacity(0.3) : .orange)
                        serviceNode.frame(width: 170)
                        AnimatedConnectorLine(color: .blue)
                        workloadNode.frame(width: 160)
                        AnimatedConnectorLine(color: relation.workloads.isEmpty ? .secondary.opacity(0.3) : .purple)
                        podsNode.frame(width: 175)

                    case .network:
                        networkIngressNode.frame(width: 170)
                        AnimatedConnectorLine(color: .orange)
                        networkServiceNode.frame(width: 190)
                        AnimatedConnectorLine(color: .blue)
                        networkEndpointsNode.frame(width: 190)

                    case .storage:
                        workloadNode.frame(width: 160)
                        AnimatedConnectorLine(color: .purple)
                        storagePvcNode.frame(width: 190)
                        AnimatedConnectorLine(color: .green)
                        storageClassNode.frame(width: 160)
                    }
                }
                .padding(.vertical, 12)
                .frame(minWidth: 780)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    DragGesture()
                        .onChanged { val in
                            offset = CGSize(
                                width: lastDragOffset.width + val.translation.width,
                                height: lastDragOffset.height + val.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastDragOffset = offset
                        }
                )
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                viewModel.selectedPortForwardServiceID = relation.service.id
                viewModel.selectedSection = .portForward
                dismiss()
            } label: {
                Label("Port Forward Service", systemImage: "arrowshape.turn.up.right")
            }
            .buttonStyle(CTXPrimaryButton())

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(CTXSecondaryButton())
        }
    }
}
