import CTXCore
import SwiftUI

struct TroubledWorkloadsView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    @State private var filterText: String = ""
    @State private var selectedCategory: IssueCategory = .all
    @State private var activeQuickFilter: QuickFilter? = nil

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

    private struct FilteredIssues {
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
                    // Interactive Summary KPI Cards
                    HStack(spacing: 12) {
                        MetricSummaryCard(
                            title: "Total Issues",
                            count: data.allIssues.count,
                            icon: "exclamationmark.triangle.fill",
                            color: .red,
                            isSelected: activeQuickFilter == nil && selectedCategory == .all
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                activeQuickFilter = nil
                                selectedCategory = .all
                            }
                        }

                        MetricSummaryCard(
                            title: "Crash / OOM",
                            count: data.crashCount,
                            icon: "bolt.horizontal.circle.fill",
                            color: .orange,
                            isSelected: activeQuickFilter == .crashOOM
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if activeQuickFilter == .crashOOM {
                                    activeQuickFilter = nil
                                } else {
                                    activeQuickFilter = .crashOOM
                                    selectedCategory = .all
                                }
                            }
                        }

                        MetricSummaryCard(
                            title: "Pending / NotReady",
                            count: data.pendingCount + data.troubledNodes.count,
                            icon: "clock.fill",
                            color: .yellow,
                            isSelected: activeQuickFilter == .pendingNotReady
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if activeQuickFilter == .pendingNotReady {
                                    activeQuickFilter = nil
                                } else {
                                    activeQuickFilter = .pendingNotReady
                                    selectedCategory = .all
                                }
                            }
                        }

                        MetricSummaryCard(
                            title: "Restart Spikes",
                            count: data.restartCount,
                            icon: "arrow.counterclockwise.circle.fill",
                            color: .purple,
                            isSelected: activeQuickFilter == .restartSpikes
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if activeQuickFilter == .restartSpikes {
                                    activeQuickFilter = nil
                                } else {
                                    activeQuickFilter = .restartSpikes
                                    selectedCategory = .all
                                }
                            }
                        }
                    }

                    // Toolbar (Category Menu + Search Bar)
                    HStack(spacing: 12) {
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
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text(selectedCategory.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("Search...", text: $filterText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                            if !filterText.isEmpty {
                                Button {
                                    filterText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

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
        .task {
            viewModel.loadResource(kind: .pods, bypassCache: false)
            viewModel.loadResource(kind: .nodes, bypassCache: false)
            viewModel.loadResource(kind: .workloads, bypassCache: false)
        }
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

private struct MetricSummaryCard: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count)")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isSelected ? color.opacity(0.18) : (isHovered ? Color(white: 0.18).opacity(0.8) : Color(white: 0.14).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.7) : (isHovered ? Color.white.opacity(0.2) : Color.white.opacity(0.08)), lineWidth: isSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: isSelected ? color.opacity(0.25) : Color.clear, radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
