import CTXCore
import SwiftUI

struct ClusterWorkspaceContent: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    private static let topAnchorID = "ClusterWorkspaceContent.top"

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch viewModel.selectedSection {
                        case .overview:
                            ClusterOverviewView(viewModel: viewModel)
                        case .secrets:
                            resourceList
                        case .namespaces, .nodes, .workloads, .pods, .cronjobs, .services, .ingress, .configMaps, .events, .gitops, .helm:
                            resourceList
                        case .logs:
                            ClusterLogsView(viewModel: viewModel)
                        case .topology:
                            ClusterTopologyView(viewModel: viewModel)
                        case .exports:
                            ClusterExportsView(viewModel: viewModel)
                        case .diff:
                            ClusterDiffView(viewModel: viewModel)
                        case .portForward:
                            ClusterPortForwardView(viewModel: viewModel)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(Self.topAnchorID)
                }
                // The whole switch shares ONE ScrollView, so its scroll offset was
                // never reset on its own when the section changed. Scrolling down in
                // a tall section (a long resource list, the topology map, ...) and
                // then switching to a shorter one (e.g. Overview) left that old
                // offset in place, showing the new section's content as if already
                // scrolled partway down it — everything above the leftover offset
                // (the header, the first row of cards, the top of the sidebar list)
                // renders above the visible viewport, colliding with the window's
                // own title bar. Only `resourceList` had a per-section `.id` before,
                // so this only misfired when leaving *other* sections. Explicitly
                // scrolling to a fixed anchor on every switch (same pattern as the
                // Logs auto-scroll-to-bottom below) resets position without also
                // resetting each section's own view identity/state — an earlier
                // version of this fix used `.id(selectedSection)` on the whole
                // switch, which incidentally wiped Exports' in-progress bulk-export
                // selection every time you left and came back to it.
                .onChange(of: viewModel.selectedSection) { _, _ in
                    withTransaction(Transaction(animation: nil)) {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
                .onAppear {
                    withTransaction(Transaction(animation: nil)) {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
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
            showIssuesOnly: viewModel.showIssuesOnly,
            loadIfNeeded: { viewModel.loadSelectedSection(bypassCache: false) },
            refresh: { viewModel.loadSelectedSection(bypassCache: true) },
            selectRow: { viewModel.selectResource($0, in: viewModel.selectedSection) }
        )
        .id(viewModel.selectedSection.id)
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
