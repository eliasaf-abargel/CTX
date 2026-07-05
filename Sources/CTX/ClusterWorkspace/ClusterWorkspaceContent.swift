import CTXCore
import SwiftUI

struct ClusterWorkspaceContent: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch viewModel.selectedSection {
                    case .overview:
                        ClusterOverviewView(viewModel: viewModel)
                    case .secrets:
                        resourceList
                    case .namespaces, .nodes, .workloads, .pods, .services, .ingress, .configMaps, .events:
                        resourceList
                    case .logs:
                        ClusterLogsView(viewModel: viewModel)
                    case .exports:
                        ClusterExportsView(viewModel: viewModel)
                    case .diff:
                        ClusterDiffView(viewModel: viewModel)
                    case .portForward:
                        FuturePlaceholder(section: viewModel.selectedSection)
                    }
                }
                .padding(22)
                .frame(width: min(geometry.size.width, contentMaxWidth), alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.selectedSection)
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
            loadIfNeeded: { viewModel.loadSelectedSection(bypassCache: false) },
            refresh: { viewModel.loadSelectedSection(bypassCache: true) },
            selectRow: { viewModel.selectResource($0, in: viewModel.selectedSection) }
        )
        .id(viewModel.selectedSection.id)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private var scopeTitle: String {
        guard let kind = viewModel.selectedSection.resourceKind else { return "Workspace" }
        return kind.isClusterScoped ? "Cluster scoped" : viewModel.scope(for: kind).scopeTitle
    }

    /// Every namespaced row would otherwise repeat the same namespace when a single
    /// namespace is selected — the column only earns its place when rows can differ.
    private var showsNamespaceColumn: Bool {
        guard let kind = viewModel.selectedSection.resourceKind, !kind.isClusterScoped else { return false }
        return viewModel.scope(for: kind) == .allNamespaces
    }

    /// Resource-table screens are uncapped here — `CTXResourceTable` already
    /// governs its own width (per-column `maxWidth`, one flexible column that
    /// absorbs leftover space up to its own cap), so an *additional* fixed cap at
    /// this level only produced dead background on a wide/ultra-wide window
    /// without the table ever getting the chance to use that space. Non-table
    /// screens (Overview's card grid, Logs, Diff, Exports) don't have that same
    /// self-governing width logic, so they keep a generous-but-bounded cap for
    /// readability instead of stretching edge-to-edge on a very wide display.
    private var contentMaxWidth: CGFloat {
        viewModel.selectedSection.resourceKind == nil ? 1600 : .infinity
    }
}

private struct FuturePlaceholder: View {
    let section: ClusterWorkspaceSection

    var body: some View {
        CTXGlassPanel {
                    CTXEmptyStateView(
                        title: "\(section.rawValue) later",
                        message: "Reserved for a safety-reviewed workflow.",
                        systemImage: section.systemImage
                    )
        }
    }
}

