import CTXCore
import SwiftUI

struct ClusterTopologyView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    @State private var scale: CGFloat = 1
    @State private var command: TopologyMapCommand?
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedNodeID: String?
    @State private var needsAttentionOnly = false
    @State private var showsInactive = false

    private var projection: TopologyProjection? { viewModel.topologyProjection }

    /// Taken from the view model, not from the text field. The projection is
    /// built for the committed selector, so filtering the drawn graph by
    /// anything else describes a map that does not exist — including for the
    /// frame after a namespace switch clears the selector while the field still
    /// holds the old term.
    private var filter: TopologyMapFilter {
        TopologyMapFilter(
            searchText: viewModel.topologySelectorText,
            includesInactive: showsInactive,
            needsAttentionOnly: needsAttentionOnly
        )
    }

    var body: some View {
        // Built once per pass and handed down, so the toolbar's counts and the
        // canvas's empty state can never describe two different maps.
        let snapshot = TopologyMapSnapshot(
            projected: viewModel.topologyGraph,
            projection: projection,
            filter: filter
        )

        return VStack(spacing: 0) {
            TopologyToolbarView(
                searchText: $searchText,
                needsAttentionOnly: $needsAttentionOnly,
                showsInactive: $showsInactive,
                scale: scale,
                counts: TopologyCountSummary(snapshot),
                command: $command
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            TopologyResponsiveInspectorLayout(
                isPresented: selectedNode(in: snapshot) != nil,
                canvas: {
                    canvas(snapshot)
                },
                inspector: {
                    inspector(snapshot)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            searchText = viewModel.topologySelectorText
            viewModel.loadTopologyResources()
        }
        // Typing is not a reason to drop the selection: the inspector describes
        // an object, and that object is still the same one three keystrokes into
        // a search that has not been committed yet. If the committed filter does
        // remove it, the node-list check below clears the selection then.
        .onChange(of: searchText) { _, value in
            scheduleSelectorUpdate(value)
        }
        .onChange(of: viewModel.topologyScopeID) { _, _ in
            // The scope, not the selector: switching to a namespace while the
            // committed selector is empty leaves the text unchanged, and the
            // term the user half-typed for the previous namespace would
            // otherwise stay in the field and land 180ms later.
            searchTask?.cancel()
            searchTask = nil
            searchText = ""
            selectedNodeID = nil
        }
        .onChange(of: viewModel.topologySelectorText) { _, value in
            guard value != searchText else { return }
            searchTask?.cancel()
            searchText = value
            selectedNodeID = nil
        }
        .onChange(of: snapshot.graph.nodes.map(\.id)) { _, ids in
            if let selectedNodeID, !ids.contains(selectedNodeID) {
                self.selectedNodeID = nil
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
        // Escape reaches here from anywhere in the pane that does not handle it
        // first, so it still dismisses the inspector when focus is on one of the
        // inspector's own buttons rather than on the canvas.
        .onExitCommand {
            selectedNodeID = nil
        }
        .background {
            zoomShortcuts
        }
    }

    /// Mounted by the pane rather than by the toolbar, because the toolbar shows
    /// one of three layouts: a shortcut attached to a button in the wide layout
    /// vanishes the moment the window narrows, and one attached to a branch
    /// `ViewThatFits` merely measures can fire twice.
    private var zoomShortcuts: some View {
        HStack {
            Button("") { command = .zoomIn }
                .keyboardShortcut("+", modifiers: .command)
            Button("") { command = .zoomOut }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { command = .fit }
                .keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func canvas(_ snapshot: TopologyMapSnapshot) -> some View {
        Group {
            switch snapshot.vacancy {
            case .none:
                ClusterDAGGraphView(
                    graph: snapshot.graph,
                    groupsByNodeID: projection?.groupsByNodeID ?? [:],
                    onExpandGroup: { viewModel.expandTopologyGroup($0) },
                    scale: $scale,
                    command: $command,
                    selectedNodeID: $selectedNodeID
                )
            case .awaitingProjection:
                // The filters do match something; the projection just has not
                // caught up. Saying "no match" here would be a lie the next
                // frame corrects.
                ResourceSkeletonView(
                    title: "Bringing \(snapshot.eligibleCount) matching object\(snapshot.eligibleCount == 1 ? "" : "s") into view"
                )
                .padding(22)
            case .noSearchMatch:
                CTXEmptyStateView(
                    title: "No match for “\(viewModel.topologySelectorText)”",
                    message: "Try another object name, or clear the lineage search.",
                    systemImage: "magnifyingglass"
                )
            case .noAttentionNeeded:
                CTXEmptyStateView(
                    title: "No objects need attention",
                    message: "Clear the filter to see the full active map.",
                    systemImage: "checkmark.circle"
                )
            case .allInactive:
                CTXEmptyStateView(
                    title: "All objects are inactive",
                    message: "Turn on Show inactive to include completed or scaled-to-zero objects.",
                    systemImage: "moon.zzz"
                )
            case .noObjects:
                // "Nothing to map" is a claim about the namespace, so it waits
                // until every source list is in and a build has actually
                // published its verdict.
                if viewModel.isTopologyPending {
                    ResourceSkeletonView(title: "Building the service map")
                        .padding(22)
                } else {
                    CTXEmptyStateView(
                        title: "Nothing to map",
                        message: "The map appears once Services, Workloads and Pods have loaded.",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
    }

    @ViewBuilder
    private func inspector(_ snapshot: TopologyMapSnapshot) -> some View {
        if let inspected = selectedNode(in: snapshot) {
            TopologyNodeInspectorView(
                node: inspected,
                graph: snapshot.graph,
                group: projection?.groupsByNodeID[inspected.id],
                canCollapse: viewModel.topologyExpansionState.batchCount(for: inspected.id) > 0,
                onSelect: { selectedNodeID = $0 },
                onOpenInspector: { openInspector(inspected) },
                onPortForward: inspected.kind == .service ? { openPortForward(inspected) } : nil,
                onShowPods: projection?.groupsByNodeID[inspected.id].map { group in
                    { showPods(group) }
                },
                onExpand: { viewModel.expandTopologyGroup(inspected.id) },
                onCollapse: { viewModel.collapseTopologyGroup(inspected.id) },
                onResetExpansion: viewModel.topologyExpansionState.batchesByGroupID.isEmpty
                    ? nil
                    : { viewModel.resetTopologyExpansion() },
                onClose: { selectedNodeID = nil }
            )
        }
    }

    private func selectedNode(in snapshot: TopologyMapSnapshot) -> TopologyGraphNode? {
        selectedNodeID.flatMap(snapshot.graph.node)
    }

    private func openInspector(_ node: TopologyGraphNode) {
        guard let section = node.kind.workspaceSection else { return }
        viewModel.selectResource(node.row, in: section)
    }

    private func openPortForward(_ node: TopologyGraphNode) {
        viewModel.selectPortForwardService(node.row)
        viewModel.selectedSection = .portForward
    }

    private func scheduleSelectorUpdate(_ value: String) {
        searchTask?.cancel()
        guard value != viewModel.topologySelectorText else { return }
        // The scope is captured, not read at commit time: a term typed for one
        // namespace must never be applied to the next, however the reset and
        // this sleep interleave.
        let scope = viewModel.topologyScopeID
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled,
                  scope == viewModel.topologyScopeID,
                  value != viewModel.topologySelectorText else { return }
            viewModel.setTopologySelector(value)
        }
    }

    private func showPods(_ group: TopologyProjectedGroup) {
        let rowIDs = Set(group.memberNodeIDs.compactMap { id -> String? in
            guard id.hasPrefix("pod/") else { return nil }
            return String(id.dropFirst("pod/".count))
        })
        guard !rowIDs.isEmpty else { return }
        viewModel.resourceFocus = ResourceFocus(
            section: .pods,
            title: "\(group.hiddenCount) pods represented on the map",
            ids: rowIDs
        )
        viewModel.selectedSection = .pods
    }
}

private extension TopologyGraphNodeKind {
    var workspaceSection: ClusterWorkspaceSection? {
        switch self {
        case .ingress: .ingress
        case .service: .services
        case .workload: .workloads
        case .pod: .pods
        case .pvc: .storage
        case .hpa: .hpa
        case .podGroup, .terminalGroup, .overflow: nil
        }
    }
}
