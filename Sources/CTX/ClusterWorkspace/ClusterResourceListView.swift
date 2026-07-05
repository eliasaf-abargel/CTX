import CTXCore
import SwiftUI

struct ClusterResourceListView: View {
    let section: ClusterWorkspaceSection
    let scopeTitle: String
    let list: KubernetesResourceList?
    let isLoading: Bool
    let refreshError: KubernetesCommandDiagnostic?
    let selectedRow: KubernetesResourceRow?
    let showsNamespaceColumn: Bool
    let loadIfNeeded: () -> Void
    let refresh: () -> Void
    let selectRow: (KubernetesResourceRow) -> Void

    @State private var filter = ""

    private var rows: [KubernetesResourceRow] {
        guard !filter.isEmpty else { return list?.rows ?? [] }
        return (list?.rows ?? []).filter { $0.matchesFilter(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                toolbar
                compactToolbar
            }

            if isLoading && list == nil {
                CTXGlassPanel {
                    ResourceSkeletonView(title: "Loading \(section.rawValue)")
                }
            } else if let list, list.status != .reachable {
                // No good data at all (first load failed, or a stale entry was never
                // established) — the only case where the whole panel is the error.
                ResourceIssuePanel(section: section, list: list, retry: refresh)
            } else {
                if isLoading {
                    CTXInlineRefreshingIndicator(state: .refreshing)
                } else if refreshError != nil {
                    CTXInlineRefreshingIndicator(state: .failed, retry: refresh)
                }
                resourceSummaryPanel
                if rows.isEmpty {
                    CTXGlassPanel {
                        CTXEmptyStateView(title: emptyTitle, message: emptyMessage, systemImage: section.systemImage)
                    }
                } else if let kind = section.resourceKind {
                    CTXResourceTable(kind: kind, rows: rows, selectedRowID: selectedRow?.id, showsNamespaceColumn: showsNamespaceColumn, onSelect: selectRow)
                }
            }
        }
        .onAppear(perform: loadIfNeeded)
        .animation(.easeInOut(duration: 0.16), value: isLoading)
        .animation(.easeInOut(duration: 0.16), value: rows.count)
        .animation(.easeInOut(duration: 0.16), value: selectedRow?.id)
    }

    private var subtitle: String {
        guard let list else { return "Inspection data" }
        let count = filter.isEmpty ? "\(list.rows.count) items" : "\(rows.count) of \(list.rows.count) items"
        return "\(count) · \(scopeTitle) · \(list.loadedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 10) {
            CTXSectionHeader(title: section.rawValue, subtitle: subtitle)
            Spacer()
            CTXSearchField(placeholder: "Filter", text: $filter)
                .frame(width: 230)
                .help("Filter loaded \(section.rawValue.lowercased()). This does not run kubectl.")
        }
    }

    private var compactToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            CTXSectionHeader(title: section.rawValue, subtitle: subtitle)
            CTXSearchField(placeholder: "Filter", text: $filter)
                .help("Filter loaded \(section.rawValue.lowercased()). This does not run kubectl.")
        }
    }

    @ViewBuilder
    private var resourceSummaryPanel: some View {
        if let list, list.status == .reachable {
            switch section {
            case .namespaces:
                let summary = KubernetesNamespacesSummary.summarize(rows: rows, status: list.status, activeNamespace: "")
                ResourceSummaryPanel(
                    title: "Namespaces",
                    detail: "\(summary.count ?? rows.count) namespaces configured in this cluster",
                    badgeTitle: countTitle(summary.count ?? rows.count, noun: "namespace"),
                    systemImage: section.systemImage,
                    tint: .purple
                )
            case .nodes:
                let summary = KubernetesNodesSummary.summarize(rows: rows, status: list.status)
                let unhealthy = summary.notReady ?? 0
                ResourceSummaryPanel(
                    title: unhealthy > 0 ? "Nodes need attention" : "Nodes healthy",
                    detail: "\(summary.ready ?? rows.count) ready · \(unhealthy) not ready",
                    badgeTitle: countTitle(summary.total ?? rows.count, noun: "node"),
                    systemImage: section.systemImage,
                    tint: unhealthy > 0 ? .orange : .green
                )
            case .pods:
                let summary = KubernetesPodsSummary.summarize(rows: rows, status: list.status)
                ResourceSummaryPanel(
                    title: summary.failing > 0 ? "Pods need attention" : "Pods healthy",
                    detail: "\(summary.running) running · \(summary.pending) pending · \(summary.failed) failed · \(summary.crashLoopBackOff) backoff",
                    badgeTitle: countTitle(summary.total ?? rows.count, noun: "pod"),
                    systemImage: section.systemImage,
                    tint: summary.failing > 0 ? .orange : .green
                )
            case .workloads:
                let summary = KubernetesWorkloadsSummary.summarize(rows: rows, status: list.status)
                ResourceSummaryPanel(
                    title: summary.unhealthy > 0 ? "Workloads need attention" : "Workloads healthy",
                    detail: "\(summary.healthy) healthy · \(summary.unhealthy) needs attention",
                    badgeTitle: countTitle(summary.total ?? rows.count, noun: "workload"),
                    systemImage: section.systemImage,
                    tint: summary.unhealthy > 0 ? .orange : .green
                )
            case .services:
                let summary = KubernetesServicesSummary.summarize(rows: rows, status: list.status)
                ResourceSummaryPanel(
                    title: summary.exposed > 0 ? "Service exposure" : "Internal services",
                    detail: "\(summary.exposed) exposed · \(max((summary.total ?? rows.count) - summary.exposed, 0)) internal",
                    badgeTitle: countTitle(summary.total ?? rows.count, noun: "service"),
                    systemImage: section.systemImage,
                    tint: .blue
                )
            case .ingress:
                let summary = KubernetesIngressSummary.summarize(rows: rows, status: list.status)
                ResourceSummaryPanel(
                    title: summary.routed > 0 ? "Ingress routing" : "No routed ingress",
                    detail: "\(summary.routed) routed · \(summary.tls) TLS",
                    badgeTitle: countTitle(summary.total ?? rows.count, noun: "ingress"),
                    systemImage: section.systemImage,
                    tint: summary.routed > 0 ? .blue : .secondary
                )
            case .configMaps:
                let summary = KubernetesConfigMapsSummary.summarize(rows: rows, status: list.status)
                ResourceSummaryPanel(
                    title: "ConfigMaps",
                    detail: "Storing a total of \(summary.totalKeys) configuration keys",
                    badgeTitle: countTitle(summary.total ?? rows.count, noun: "configMap"),
                    systemImage: section.systemImage,
                    tint: .teal
                )
            case .secrets:
                let summary = KubernetesSecretsSummary.summarize(rows: rows, status: list.status)
                ResourceSummaryPanel(
                    title: "Secrets",
                    detail: "Storing a total of \(summary.totalKeys) encrypted keys",
                    badgeTitle: countTitle(summary.total ?? rows.count, noun: "secret"),
                    systemImage: section.systemImage,
                    tint: .indigo
                )
            case .events:
                EventSummaryPanel(summary: KubernetesEventsSummary.summarize(rows: rows, status: list.status), eventCount: rows.count)
            default:
                EmptyView()
            }
        }
    }

    private func countTitle(_ count: Int, noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }

    private var emptyTitle: String {
        filter.isEmpty ? "No resources" : "No matches"
    }

    private var emptyMessage: String {
        filter.isEmpty ? "No \(section.rawValue.lowercased()) in \(scopeTitle)." : "No loaded rows match this filter."
    }
}

private struct ResourceSummaryPanel: View {
    let title: String
    let detail: String
    let badgeTitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        CTXGlassPanel(padding: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 10)
                CTXStatusBadge(title: badgeTitle, systemImage: systemImage, tint: tint)
            }
        }
    }
}

private struct EventSummaryPanel: View {
    let summary: KubernetesEventsSummary
    let eventCount: Int

    private var warningCount: Int {
        summary.warningCount ?? 0
    }

    private var title: String {
        if summary.topWarningCount > 1 {
            return "Repeated warning"
        }
        if warningCount > 0 {
            return "Latest warning"
        }
        return "No warning events"
    }

    private var detail: String {
        if summary.topWarningCount > 1, let reason = summary.topWarningReason, let object = summary.topWarningObject {
            return "\(summary.topWarningCount)x \(reason) · \(object)"
        }
        if let reason = summary.latestWarningReason, let object = summary.latestWarningObject {
            return [reason, object, summary.latestWarningLastSeen].compactMap { $0 }.joined(separator: " · ")
        }
        return "\(eventCount) events loaded"
    }

    private var tint: Color {
        warningCount > 0 ? .orange : .green
    }

    var body: some View {
        CTXGlassPanel(padding: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: warningCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 10)
                CTXStatusBadge(title: warningBadgeTitle, systemImage: "waveform.path.ecg", tint: tint)
            }
        }
    }

    private var warningBadgeTitle: String {
        warningCount == 1 ? "1 warning" : "\(warningCount) warnings"
    }
}
