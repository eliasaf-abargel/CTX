import CTXCore
import SwiftUI

/// The inspector's Logs tab. For Pods, reuses the exact same `KubernetesLogsReader`
/// / ViewModel state and the exact same shared components (`CTXLogsControls`,
/// `CTXLogsViewer`) as the standalone Logs sidebar screen (`ClusterLogsView`) — no
/// second fetch implementation, no second visual implementation.
///
/// For Services and Workloads, this discovers related Pods generically via
/// `KubernetesRelatedPods` (Service `spec.selector` / workload
/// `spec.selector.matchLabels` matched against each Pod's own labels — no app name
/// or label convention assumed) and lets the user pick one, then reuses the exact
/// same logs flow as if that Pod had been selected directly.
struct CTXInspectorLogsTab: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let selection: ClusterWorkspaceResourceSelection

    /// The related Pod the user picked for a Service/Workload — scoped to this tab
    /// instance, so it resets automatically when a *different* resource is
    /// inspected (a new sheet identity), but survives switching tabs and back
    /// within the same inspection.
    @State private var selectedRelatedPodID: String?

    private var podsList: KubernetesResourceList? {
        viewModel.resourceList(for: .pods)
    }

    private var encodedSelector: String {
        selection.row.cells["Selector"] ?? ""
    }

    var body: some View {
        Group {
            if selection.kind == .pods {
                podLogs
            } else if let podRow = relatedPodRow {
                VStack(alignment: .leading, spacing: 8) {
                    backToRelatedPodsButton
                    podLogs(for: podRow)
                }
            } else {
                relatedPodsPicker
            }
        }
        .onAppear {
            if selection.kind == .pods {
                if viewModel.selectedLogPodID != selection.row.id {
                    viewModel.selectLogPod(selection.row)
                }
            } else if podsList == nil, !encodedSelector.isEmpty {
                viewModel.loadPodsForLogs()
            }
        }
    }

    private var relatedPodRow: KubernetesResourceRow? {
        guard selection.kind != .pods, let id = selectedRelatedPodID else { return nil }
        return podsList?.rows.first { $0.id == id }
    }

    private var backToRelatedPodsButton: some View {
        Button {
            selectedRelatedPodID = nil
        } label: {
            Label("Related Pods", systemImage: "chevron.left")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(CTXInlineActionButton())
        .controlSize(.small)
    }

    @ViewBuilder
    private var relatedPodsPicker: some View {
        if encodedSelector.isEmpty {
            CTXGlassPanel {
                CTXEmptyStateView(
                    title: selection.kind == .services ? "Service has no selector" : "No selector found",
                    message: selection.kind == .services
                        ? "This Service has no spec.selector, so CTX can't discover which Pods it routes to."
                        : "This workload has no spec.selector.matchLabels, so CTX can't discover its Pods.",
                    systemImage: "questionmark.circle"
                )
            }
        } else if podsList == nil {
            CTXGlassPanel {
                CTXLoadingStateView(title: "Finding related Pods", message: "Matching this resource's selector against Pods in \(viewModel.scope(for: .pods).scopeTitle.lowercased()).")
            }
        } else {
            let matches = KubernetesRelatedPods.relatedPods(selector: KubernetesRelatedPods.parseSelector(encodedSelector), pods: podsList?.rows ?? [])
            if matches.isEmpty {
                CTXGlassPanel {
                    CTXEmptyStateView(title: "No related Pods found", message: "No Pods in \(viewModel.scope(for: .pods).scopeTitle.lowercased()) match this selector right now.", systemImage: "text.alignleft")
                }
            } else {
                CTXGlassPanel(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Related Pods").font(.system(size: 12, weight: .semibold))
                        ForEach(PodLogSelection.sortedForPicker(matches)) { row in
                            Button {
                                selectedRelatedPodID = row.id
                                viewModel.selectLogPod(row)
                            } label: {
                                relatedPodRow(row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func relatedPodRow(_ row: KubernetesResourceRow) -> some View {
        HStack(spacing: 10) {
            Circle().fill(statusTint(row)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 12, weight: .semibold))
                Text([row.cells["Status"], row.cells["Ready"].map { "\($0) ready" }, row.cells["Restarts"].map { "\($0) restarts" }, row.cells["Age"]].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func statusTint(_ row: KubernetesResourceRow) -> Color {
        switch PodLogSelection.rank(for: row) {
        case .runningReady: .green
        case .warning: .red
        case .pending: .yellow
        case .completed: .secondary
        }
    }

    private var podLogs: some View {
        podLogs(for: selection.row)
    }

    private func podLogs(for row: KubernetesResourceRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CTXLogsControls(
                pods: podsList?.rows ?? [row],
                selectedPodID: viewModel.selectedLogPodID,
                containers: viewModel.logContainers,
                selectedContainer: viewModel.selectedLogContainer,
                tailLines: viewModel.logTailLines,
                copyText: viewModel.logsResult?.text,
                isLoading: viewModel.isLoadingLogs,
                onSelectPod: { viewModel.selectLogPod($0) },
                onSelectContainer: { viewModel.selectLogContainer($0) },
                onSelectTail: { viewModel.setLogTailLines($0) },
                onReload: { viewModel.reloadLogs() }
            )
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoadingLogs {
            CTXGlassPanel {
                CTXLoadingStateView(title: "Loading logs", message: "Running an inspection tail request.")
            }
        } else if let text = viewModel.logsResult?.text, !text.isEmpty {
            CTXGlassPanel(padding: 0) {
                CTXLogsViewer(rawText: text, tailLines: viewModel.logTailLines)
            }
        } else if let result = viewModel.logsResult {
            CTXLogsIssuePanel(result: result, retry: { viewModel.reloadLogs() })
        } else {
            CTXGlassPanel {
                CTXEmptyStateView(title: "No logs returned", message: "This container has not written any logs yet.", systemImage: "text.alignleft")
            }
        }
    }
}
