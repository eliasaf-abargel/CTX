import CTXCore
import SwiftUI

/// Standalone Logs sidebar screen. Shares every piece of the fetch/selection
/// logic and every visual component (`CTXLogsControls`, `CTXPodPicker`,
/// `CTXLogsViewer`) with the inspector's Logs tab (`CTXInspectorLogsTab`) — no
/// duplicated implementation, just a different entry point (pick any pod vs.
/// a pod already selected).
struct ClusterLogsView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    private var podsList: KubernetesResourceList? {
        viewModel.resourceList(for: .pods)
    }

    private var pods: [KubernetesResourceRow] {
        podsList?.rows ?? []
    }

    private var isAllNamespaces: Bool {
        viewModel.selectedNamespace == .allNamespaces
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CTXSectionHeader(title: "Logs", subtitle: "Inspection tail of \(viewModel.scope(for: .pods).scopeTitle.lowercased()). No exec, no live shell.")

            ResourceSummaryPanel(
                title: "Pod Telemetry & Container Logs",
                detail: "\(pods.count) pods available for log tailing in \(viewModel.selectedNamespace.scopeTitle)",
                badgeTitle: "\(pods.count) pods",
                systemImage: "terminal.fill",
                tint: .cyan
            )

            CTXGlassPanel(padding: 14) {
                if pods.isEmpty {
                    podsEmptyState
                } else {
                    CTXLogsControls(
                        pods: pods,
                        selectedPodID: viewModel.selectedLogPodID,
                        showsNamespaceColumn: isAllNamespaces,
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
                }
            }

            content
        }
        .animation(.easeInOut(duration: 0.16), value: viewModel.isLoadingLogs)
        .animation(.easeInOut(duration: 0.16), value: viewModel.selectedLogPodID)
        .onAppear {
            if podsList == nil {
                viewModel.loadPodsForLogs()
            } else if viewModel.selectedLogPodID == nil, let onlyPod = PodLogSelection.autoSelectCandidate(from: pods) {
                viewModel.selectLogPod(onlyPod)
            }
        }
    }

    @ViewBuilder
    private var podsEmptyState: some View {
        if podsList == nil {
            CTXLoadingStateView(title: "Pods are loading", message: "Fetching pods for \(viewModel.scope(for: .pods).scopeTitle.lowercased()).")
        } else {
            CTXEmptyStateView(title: "No pods", message: "No pods in \(viewModel.scope(for: .pods).scopeTitle.lowercased()).", systemImage: "text.alignleft")
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.selectedLogPodID == nil {
            CTXGlassPanel {
                CTXEmptyStateView(title: "Select a pod", message: "Choose a pod above to load its most recent log lines.", systemImage: "text.alignleft")
            }
        } else if viewModel.isLoadingLogs {
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
