import CTXCore
import SwiftUI

struct MultiClusterDriftView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    @State private var contextA: String = "Active Context"
    @State private var contextB: String = "Staging / AWS EKS"
    @State private var driftItems: [ResourceDriftItem] = []
    @State private var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            if isLoading {
                CTXGlassPanel {
                    ResourceSkeletonView(title: "Comparing Drift between \(contextA) and \(contextB)...")
                }
            } else if driftItems.isEmpty {
                CTXGlassPanel {
                    CTXEmptyStateView(
                        title: "No Configuration Drift Detected",
                        message: "All deployments and specifications match identically between both clusters.",
                        systemImage: "checkmark.seal.fill"
                    )
                }
            } else {
                driftTable
            }
        }
        .onAppear(perform: loadDrift)
    }

    private var headerBar: some View {
        CTXGlassPanel(padding: 12) {
            HStack(spacing: 12) {
                Label("Cross-Context Drift Engine", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .bold))

                Spacer()

                Menu {
                    Button("Compare against AWS EKS") { contextB = "AWS EKS"; loadDrift() }
                    Button("Compare against GCP GKE") { contextB = "GCP GKE"; loadDrift() }
                    Button("Compare against Azure AKS") { contextB = "Azure AKS"; loadDrift() }
                } label: {
                    Label(contextB, systemImage: "server.rack")
                        .font(.caption.weight(.semibold))
                }
                .menuStyle(.borderlessButton)

                Button {
                    loadDrift()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(CTXInlineActionButton())
                .help("Re-compare Contexts")
            }
        }
    }

    private var driftTable: some View {
        CTXGlassPanel(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("NAMESPACE / NAME").font(.caption.weight(.bold)).frame(width: 220, alignment: .leading)
                    Text("CONTEXT A (\(viewModel.context.contextName))").font(.caption.weight(.bold)).frame(maxWidth: .infinity, alignment: .leading)
                    Text("CONTEXT B (\(contextB))").font(.caption.weight(.bold)).frame(maxWidth: .infinity, alignment: .leading)
                    Text("STATUS").font(.caption.weight(.bold)).frame(width: 90, alignment: .trailing)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                ForEach(driftItems) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 12, weight: .bold))
                            Text(item.namespace).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(width: 220, alignment: .leading)

                        Text(item.valA)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(item.valB)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(item.isMismatched ? Color.orange : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(item.isMismatched ? "MISMATCH" : "MATCH")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(item.isMismatched ? Color.orange : Color.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((item.isMismatched ? Color.orange : Color.green).opacity(0.12), in: Capsule())
                            .frame(width: 90, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func loadDrift() {
        isLoading = true
        Task {
            let items = await KubernetesMultiClusterService.compareDrift(
                contextA: viewModel.context.contextName,
                contextB: contextB,
                kind: .workloads
            )
            await MainActor.run {
                self.driftItems = items
                self.isLoading = false
            }
        }
    }
}
