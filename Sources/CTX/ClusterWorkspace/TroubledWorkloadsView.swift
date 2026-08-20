import CTXCore
import SwiftUI

struct TroubledWorkloadsView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    @State private var filterText: String = ""
    @State private var selectedCategory: IssueCategory = .all
    @State private var activeQuickFilter: QuickFilter? = nil
    /// Measured locally: this screen is not inside the Overview, so it cannot
    /// inherit that measurement, but it uses the same grid so the two screens agree
    /// on column count at the same width.
    @State private var availableWidth: CGFloat = 1000

    enum IssueCategory: String, CaseIterable, Identifiable {
        case all = "All Issues"
        case pods = "Pods"
        case nodes = "Nodes"
        case workloads = "Workloads"

        var id: String { rawValue }
    }

    enum QuickFilter {
        case crashOOM
        case pendingNotReady
        case restartSpikes
    }

    private var podsList: KubernetesResourceList {
        viewModel.resourceList(for: .pods) ?? KubernetesResourceList(kind: .pods, columns: [], rows: [], status: .notChecked)
    }

    private var nodesList: KubernetesResourceList {
        viewModel.resourceList(for: .nodes) ?? KubernetesResourceList(kind: .nodes, columns: [], rows: [], status: .notChecked)
    }

    private var workloadsList: KubernetesResourceList {
        viewModel.resourceList(for: .workloads) ?? KubernetesResourceList(kind: .workloads, columns: [], rows: [], status: .notChecked)
    }

    struct FilteredIssues {
        let troubledPods: [KubernetesResourceRow]
        let troubledNodes: [KubernetesResourceRow]
        let troubledWorkloads: [KubernetesResourceRow]
        let allIssues: [KubernetesResourceRow]
        let crashCount: Int
        let pendingCount: Int
        let restartCount: Int
    }

    private var filteredData: FilteredIssues {
        let pods = podsList.rows.filter { isTroubledPod($0) }
        let nodes = nodesList.rows.filter { isTroubledNode($0) }
        let workloads = workloadsList.rows.filter { isTroubledWorkload($0) }
        let all = pods + nodes + workloads

        var crash = 0
        var pending = 0
        var restart = 0

        for row in pods {
            let status = (row.cells["Status"] ?? "").lowercased()
            if status.contains("crash") || status.contains("oom") || status.contains("err") || status.contains("failed") {
                crash += 1
            }
            if status.contains("pending") || status.contains("containercreating") {
                pending += 1
            }
            if let restarts = Int(row.cells["Restarts"] ?? "0"), restarts > 0 {
                restart += 1
            }
        }

        return FilteredIssues(
            troubledPods: pods,
            troubledNodes: nodes,
            troubledWorkloads: workloads,
            allIssues: all,
            crashCount: crash,
            pendingCount: pending,
            restartCount: restart
        )
    }

    private var currentFilteredRows: [KubernetesResourceRow] {
        let data = filteredData
        var baseRows: [KubernetesResourceRow]
        switch selectedCategory {
        case .all:
            baseRows = data.allIssues
        case .pods:
            baseRows = data.troubledPods
        case .nodes:
            baseRows = data.troubledNodes
        case .workloads:
            baseRows = data.troubledWorkloads
        }

        if let quick = activeQuickFilter {
            switch quick {
            case .crashOOM:
                baseRows = baseRows.filter { row in
                    let status = (row.cells["Status"] ?? "").lowercased()
                    return status.contains("crash") || status.contains("oom") || status.contains("err") || status.contains("failed")
                }
            case .pendingNotReady:
                baseRows = baseRows.filter { row in
                    let status = (row.cells["Status"] ?? row.cells["Ready"] ?? "").lowercased()
                    return status.contains("pending") || status.contains("containercreating") || status.contains("notready")
                }
            case .restartSpikes:
                baseRows = baseRows.filter { row in
                    let restarts = Int(row.cells["Restarts"] ?? "0") ?? 0
                    return restarts > 0
                }
            }
        }

        if filterText.isEmpty {
            return baseRows
        }
        return baseRows.filter { $0.matchesFilter(filterText) }
    }

    var body: some View {
        let data = filteredData
        return VStack(spacing: 14) {
            if (viewModel.isLoading(section: .pods) || viewModel.isLoading(section: .nodes)) && data.allIssues.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Scanning cluster...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if data.allIssues.isEmpty {
                CTXEmptyStateView(
                    title: "All Clear",
                    message: "All monitored pods, nodes, and workloads in '\(viewModel.namespace)' are healthy."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    // Four tiles, one row, always.
                    //
                    // They use the Overview's card, but not the Overview's three
                    // columns: four does not divide by three, so the fourth tile
                    // dropped onto a second row on its own next to a gap. A row of
                    // summary tiles is a single unit — it either fits on one line or
                    // it is not a row — so this grid is sized to the tile count
                    // rather than to a shared column rhythm.
                    LazyVGrid(columns: IssueSummaryTile.columns, spacing: ClusterOverviewLayout.spacing) {
                        ForEach(IssueSummaryTile.tiles(for: data)) { tile in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    apply(tile)
                                }
                            } label: {
                                CTXResourceCard(
                                    title: tile.title,
                                    value: "\(tile.count)",
                                    subtitle: isActive(tile) ? "Filtering" : tile.subtitle,
                                    systemImage: tile.icon,
                                    tint: tile.tint
                                )
                                .overlay {
                                    if isActive(tile) {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(tile.tint.opacity(0.55), lineWidth: 1.5)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxHeight: .infinity)
                        }
                    }

                    HStack(spacing: 10) {
                        Menu {
                            ForEach(IssueCategory.allCases) { cat in
                                Button {
                                    selectedCategory = cat
                                    activeQuickFilter = nil
                                } label: {
                                    HStack {
                                        Text(cat.rawValue)
                                        if selectedCategory == cat {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 11, weight: .medium))
                                Text(selectedCategory.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .ctxGlassCard(cornerRadius: 8)
                        .fixedSize()

                        // The shared field. The hand-rolled one hardcoded
                        // `Color(white: 0.12)`, so it ignored the theme and sat at a
                        // different height and corner radius from every other search
                        // box in the app.
                        CTXSearchField(placeholder: "Search issues...", text: $filterText)
                            .frame(maxWidth: 320)

                        Spacer()
                    }

                    // Native CTX Resource Table
                    if currentFilteredRows.isEmpty {
                        CTXEmptyStateView(
                            title: "No Matching Issues",
                            message: filterText.isEmpty ? "No issues found for this filter." : "No issues match '\(filterText)'."
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        CTXResourceTable(
                            section: targetSectionForCategory,
                            rows: currentFilteredRows,
                            selectedRowID: viewModel.selectedResource(for: targetSectionForCategory)?.id,
                            showsNamespaceColumn: true,
                            onSelect: { row in
                                viewModel.selectResource(row, in: sectionForRow(row, data: data))
                            }
                        )
                    }
                }
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, width in
                        guard abs(width - availableWidth) > 1 else { return }
                        availableWidth = width
                    }
            }
        )
        .task {
            viewModel.loadResource(kind: .pods, bypassCache: false)
            viewModel.loadResource(kind: .nodes, bypassCache: false)
            viewModel.loadResource(kind: .workloads, bypassCache: false)
        }
    }

    private func isActive(_ tile: IssueSummaryTile) -> Bool {
        guard let filter = tile.filter else {
            return activeQuickFilter == nil && selectedCategory == .all
        }
        return activeQuickFilter == filter
    }

    /// Tapping the active tile clears it, so the tiles behave like toggles rather
    /// than a selection you cannot get out of.
    private func apply(_ tile: IssueSummaryTile) {
        guard let filter = tile.filter else {
            activeQuickFilter = nil
            selectedCategory = .all
            return
        }
        activeQuickFilter = activeQuickFilter == filter ? nil : filter
        selectedCategory = .all
    }

    private var targetSectionForCategory: ClusterWorkspaceSection {
        switch selectedCategory {
        case .all, .pods: .pods
        case .nodes: .nodes
        case .workloads: .workloads
        }
    }

    private func sectionForRow(_ row: KubernetesResourceRow, data: FilteredIssues) -> ClusterWorkspaceSection {
        if data.troubledNodes.contains(where: { $0.id == row.id }) { return .nodes }
        if data.troubledWorkloads.contains(where: { $0.id == row.id }) { return .workloads }
        return .pods
    }

    private func isTroubledPod(_ row: KubernetesResourceRow) -> Bool {
        if row.warning { return true }
        let status = (row.cells["Status"] ?? "").lowercased()
        let restarts = Int(row.cells["Restarts"] ?? "0") ?? 0
        if status.contains("running") && restarts == 0 { return false }
        if status.contains("completed") { return false }
        return true
    }

    private func isTroubledNode(_ row: KubernetesResourceRow) -> Bool {
        if row.warning { return true }
        let status = (row.cells["Status"] ?? row.cells["Ready"] ?? "").lowercased()
        return !status.contains("ready") || status.contains("notready")
    }

    private func isTroubledWorkload(_ row: KubernetesResourceRow) -> Bool {
        if row.warning { return true }
        let ready = row.cells["Ready"] ?? ""
        if ready.contains("/") {
            let parts = ready.split(separator: "/")
            if parts.count == 2, let current = Int(parts[0]), let desired = Int(parts[1]), current < desired {
                return true
            }
        }
        return false
    }
}

/// The four issue tiles as data, so the view renders them through the shared
/// `CTXResourceCard` instead of a second card implementation that had to be kept
/// looking like the first one by hand.
struct IssueSummaryTile: Identifiable {
    /// One column per tile, so the four always share a single row and split the
    /// available width evenly between them.
    static var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: ClusterOverviewLayout.spacing, alignment: .top),
            count: 4
        )
    }

    let id: String
    let title: String
    let subtitle: String
    let count: Int
    let icon: String
    let tint: Color
    let filter: TroubledWorkloadsView.QuickFilter?

    static func tiles(for data: TroubledWorkloadsView.FilteredIssues) -> [IssueSummaryTile] {
        [
            IssueSummaryTile(
                id: "all", title: "Total Issues", subtitle: "Everything needing attention",
                count: data.allIssues.count, icon: "exclamationmark.triangle.fill", tint: .red, filter: nil
            ),
            IssueSummaryTile(
                id: "crash", title: "Crash / OOM", subtitle: "Restarting or killed",
                count: data.crashCount, icon: "bolt.horizontal.circle.fill", tint: .orange, filter: .crashOOM
            ),
            IssueSummaryTile(
                id: "pending", title: "Pending / NotReady", subtitle: "Waiting to become ready",
                count: data.pendingCount + data.troubledNodes.count, icon: "clock.fill", tint: .yellow, filter: .pendingNotReady
            ),
            IssueSummaryTile(
                id: "restarts", title: "Restart Spikes", subtitle: "Repeatedly restarted",
                count: data.restartCount, icon: "arrow.counterclockwise.circle.fill", tint: .purple, filter: .restartSpikes
            )
        ]
    }
}
