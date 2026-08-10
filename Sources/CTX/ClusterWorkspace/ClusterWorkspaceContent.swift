import CTXCore
import SwiftUI

struct ClusterWorkspaceContent: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    var body: some View {
        // Each section gets its own identity — SwiftUI discards and recreates the
        // view tree on section change instead of scroll-resetting a shared
        // ScrollView, which was the main cause of the freeze on large clusters.
        Group {
            switch viewModel.selectedSection {
            case .overview:
                ScrollView {
                    ClusterOverviewView(viewModel: viewModel)
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .issues:
                ScrollView {
                    TroubledWorkloadsView(viewModel: viewModel)
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .logs:
                ScrollView {
                    ClusterLogsView(viewModel: viewModel)
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .topology:
                ScrollView {
                    ClusterTopologyView(viewModel: viewModel)
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .exports:
                ScrollView {
                    ClusterExportsView(viewModel: viewModel)
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .diff:
                ScrollView {
                    ClusterDiffView(viewModel: viewModel)
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .portForward:
                ScrollView {
                    ClusterPortForwardView(viewModel: viewModel)
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            default:
                // The page scrolls as one: toolbar, summary and table together.
                // Giving the table its own vertical scroll view instead would let
                // the `LazyVStack` be genuinely lazy, but a nested scroll view
                // broke the layout of every list screen — headers pushed into the
                // middle of the panel, content jumping. Row count is bounded below
                // instead, which is the same protection without the layout risk.
                ScrollView {
                    resourceList
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // Fresh view identity per section → instant zero-stutter tab switching.
        .id(viewModel.selectedSection)
        // Both Overview and Nodes read live utilisation, so the poll follows either.
        .task(id: viewModel.selectedSection) {
            if viewModel.selectedSection == .nodes {
                viewModel.startTelemetryUpdates()
            }
        }
        .sheet(item: $viewModel.presentation) { presentation in
            CTXResourceInspector(viewModel: viewModel, selection: presentation.selection, activeTab: presentation.tab)
        }
    }

    private var resourceList: some View {
        ClusterResourceListView(
            section: viewModel.selectedSection,
            scopeTitle: scopeTitle,
            list: viewModel.resourceList(for: viewModel.selectedSection),
            isLoading: viewModel.isLoading(section: viewModel.selectedSection),
            refreshError: viewModel.refreshError(for: viewModel.selectedSection),
            selectedRow: viewModel.selectedResource(for: viewModel.selectedSection),
            showsNamespaceColumn: showsNamespaceColumn,
            emptyMessageOverride: emptyMessageOverride,
            notice: sectionNotice,
            loadIfNeeded: { viewModel.loadSelectedSection(bypassCache: false) },
            refresh: { viewModel.loadSelectedSection(bypassCache: true) },
            selectRow: { viewModel.selectResource($0, in: viewModel.selectedSection) }
        )
        .id(viewModel.selectedSection.id)
    }

    private var sectionNotice: String? {
        switch viewModel.selectedSection {
        case .helm: return viewModel.helmSourceNotice
        case .gitops: return viewModel.gitOpsSourceNotice
        default: return nil
        }
    }

    /// GitOps and Helm need to explain *why* they are empty — no controller
    /// installed is a different situation from a controller that reports nothing,
    /// and both differ from a filter that matched nothing.
    private var emptyMessageOverride: String? {
        switch viewModel.selectedSection {
        case .gitops: return viewModel.gitOpsEmptyMessage
        case .helm: return viewModel.helmEmptyMessage
        default: return nil
        }
    }

    private var scopeTitle: String {
        // GitOps is cluster-wide by nature: the controller's resources live in its
        // own namespace while the workloads land elsewhere.
        if viewModel.selectedSection == .gitops { return "Cluster scoped" }
        if viewModel.selectedSection == .helm { return viewModel.selectedNamespace.scopeTitle }
        guard let kind = viewModel.selectedSection.resourceKind else { return "Workspace" }
        return kind.isClusterScoped ? "Cluster scoped" : viewModel.scope(for: kind).scopeTitle
    }

    private var showsNamespaceColumn: Bool {
        if viewModel.selectedSection == .gitops { return true }
        if viewModel.selectedSection == .helm { return viewModel.selectedNamespace == .allNamespaces }
        guard let kind = viewModel.selectedSection.resourceKind, !kind.isClusterScoped else { return false }
        return viewModel.scope(for: kind) == .allNamespaces
    }
}
