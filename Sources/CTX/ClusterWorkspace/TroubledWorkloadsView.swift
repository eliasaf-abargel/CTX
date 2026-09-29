import CTXCore
import SwiftUI

struct TroubledWorkloadsView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    @State private var filterText: String = ""
    @State private var selectedCategory: IssueCategory = .all
    @State private var availableWidth: CGFloat = 1000

    enum IssueCategory: String, CaseIterable, Identifiable {
        case all = "All Issues"
        case configuration = "Configuration"
        case security = "Security"
        case reliability = "Reliability"
        case runtime = "Runtime Failures"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .all: "exclamationmark.triangle"
            case .configuration: "gearshape.2"
            case .security: "lock.shield"
            case .reliability: "gauge.with.needle"
            case .runtime: "bolt.horizontal.circle"
            }
        }
    }

    private var diagnosticIssues: [ResourceDiagnosticIssue] {
        let all = viewModel.diagnosticReport.allIssues
        let scoped: [ResourceDiagnosticIssue]
        switch viewModel.selectedNamespace {
        case .allNamespaces:
            scoped = all
        case .defaultNamespace:
            scoped = all.filter { $0.resourceNamespace == "default" || $0.resourceNamespace == nil }
        case .namespace(let ns):
            scoped = all.filter { $0.resourceNamespace == ns || $0.resourceNamespace == nil }
        }

        switch selectedCategory {
        case .all:
            return scoped
        case .configuration:
            return scoped.filter { $0.category == DiagnosticCategory.configuration }
        case .security:
            return scoped.filter { $0.category == DiagnosticCategory.security }
        case .reliability:
            return scoped.filter { $0.category == DiagnosticCategory.reliability }
        case .runtime:
            return scoped.filter { $0.category == DiagnosticCategory.runtime }
        }
    }

    private var filteredIssues: [ResourceDiagnosticIssue] {
        if filterText.isEmpty { return diagnosticIssues }
        return diagnosticIssues.filter { issue in
            issue.resourceName.localizedCaseInsensitiveContains(filterText) ||
            issue.title.localizedCaseInsensitiveContains(filterText) ||
            issue.message.localizedCaseInsensitiveContains(filterText) ||
            issue.ruleId.localizedCaseInsensitiveContains(filterText)
        }
    }

    private var configCount: Int {
        viewModel.diagnosticReport.allIssues.filter { $0.category == DiagnosticCategory.configuration }.count
    }

    private var securityCount: Int {
        viewModel.diagnosticReport.allIssues.filter { $0.category == DiagnosticCategory.security }.count
    }

    private var reliabilityCount: Int {
        viewModel.diagnosticReport.allIssues.filter { $0.category == DiagnosticCategory.reliability }.count
    }

    private var runtimeCount: Int {
        viewModel.diagnosticReport.allIssues.filter { $0.category == DiagnosticCategory.runtime }.count
    }

    var body: some View {
        VStack(spacing: 14) {
            if (viewModel.isLoading(section: .pods) || viewModel.isLoading(section: .nodes)) && viewModel.diagnosticReport.allIssues.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Analyzing cluster configuration...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.diagnosticReport.allIssues.isEmpty {
                CTXEmptyStateView(
                    title: "All Clear",
                    message: "No configuration, security, or reliability issues detected in '\(viewModel.namespace)'."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    // Top summary metric cards
                    LazyVGrid(columns: summaryColumns, spacing: ClusterOverviewLayout.spacing) {
                        metricCard(
                            id: "all",
                            title: "Total Issues",
                            count: viewModel.diagnosticReport.allIssues.count,
                            subtitle: "Cross-resource findings",
                            icon: "stethoscope",
                            tint: .red,
                            category: .all
                        )
                        metricCard(
                            id: "config",
                            title: "Configuration",
                            count: configCount,
                            subtitle: "Broken refs & selectors",
                            icon: "gearshape.2.fill",
                            tint: .orange,
                            category: .configuration
                        )
                        metricCard(
                            id: "security",
                            title: "Security Risks",
                            count: securityCount,
                            subtitle: "Privilege & root access",
                            icon: "lock.shield.fill",
                            tint: .purple,
                            category: .security
                        )
                        metricCard(
                            id: "reliability",
                            title: "Reliability",
                            count: reliabilityCount,
                            subtitle: "Missing limits & probes",
                            icon: "gauge.with.needle.fill",
                            tint: .blue,
                            category: .reliability
                        )
                    }

                    // Toolbar: Category Filter & Search Field
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(IssueCategory.allCases) { cat in
                                Button {
                                    selectedCategory = cat
                                } label: {
                                    HStack {
                                        Label(cat.rawValue, systemImage: cat.systemImage)
                                        if selectedCategory == cat {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: selectedCategory.systemImage)
                                    .font(.system(.caption2, weight: .medium))
                                Text(selectedCategory.rawValue)
                                    .font(.system(.caption, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(.caption2, weight: .bold))
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

                        CTXSearchField(placeholder: "Search rules, resources, messages...", text: $filterText)
                            .frame(maxWidth: 340)

                        Spacer()

                        Text("\(filteredIssues.count) \(filteredIssues.count == 1 ? "finding" : "findings")")
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    // Issues list
                    if filteredIssues.isEmpty {
                        CTXEmptyStateView(
                            title: "No Matching Issues",
                            message: filterText.isEmpty ? "No issues in this category." : "No issues match '\(filterText)'."
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 10) {
                                ForEach(filteredIssues) { issue in
                                    issueRow(issue)
                                }
                            }
                            .padding(.bottom, 20)
                        }
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
            viewModel.loadResource(kind: .services, bypassCache: false)
            viewModel.loadResource(kind: .ingress, bypassCache: false)
            viewModel.loadResource(kind: .configMaps, bypassCache: false)
            viewModel.loadResource(kind: .secretMetadata, bypassCache: false)
            viewModel.loadResource(kind: .pvc, bypassCache: false)
        }
    }

    private var summaryColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: ClusterOverviewLayout.spacing, alignment: .top),
            count: 4
        )
    }

    private func metricCard(
        id: String,
        title: String,
        count: Int,
        subtitle: String,
        icon: String,
        tint: Color,
        category: IssueCategory
    ) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategory = category
            }
        } label: {
            CTXResourceCard(
                title: title,
                value: "\(count)",
                subtitle: isSelected ? "Filtering" : subtitle,
                systemImage: icon,
                tint: tint
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(tint.opacity(0.65), lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxHeight: .infinity)
    }

    private func issueRow(_ issue: ResourceDiagnosticIssue) -> some View {
        let tintColor = issue.severity.tint

        return CTXGlassPanel(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: issue.severity.systemImage)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(tintColor)
                        .frame(width: 26, height: 26)
                        .background(tintColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            // Resource Kind badge
                            Text(issue.resourceKind.title.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                            // Resource Name
                            Text(issue.resourceName)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(.primary)

                            // Namespace
                            if let ns = issue.resourceNamespace, ns != "-" {
                                Text(ns)
                                    .font(.system(.caption2))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            // Category
                            DiagnosticCategoryBadge(category: issue.category)

                            // Rule ID
                            Text(issue.ruleId)
                                .font(.system(.caption2, design: .monospaced, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Text(issue.message)
                            .font(.system(.callout))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        if let row = findRow(for: issue) {
                            viewModel.inspectDiagnostics(for: row, kind: issue.resourceKind)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Inspect")
                                .font(.system(.caption, weight: .semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Open inspector for \(issue.resourceName)")
                }

                // Recommendation callout
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow)
                        .padding(.top, 1)

                    Text(issue.recommendation)
                        .font(.system(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private func findRow(for issue: ResourceDiagnosticIssue) -> KubernetesResourceRow? {
        let section = ClusterWorkspaceSection.section(for: issue.resourceKind) ?? .workloads
        return viewModel.resourceList(for: section)?.rows.first { $0.id == issue.resourceID }
    }
}
