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
    /// Set by sections that can explain their own emptiness better than the generic
    /// "there are none here" — GitOps distinguishes "no controller installed" from
    /// "installed but reporting nothing".
    var emptyMessageOverride: String? = nil
    /// A short caveat shown above the table, for when the data is real but came from
    /// a degraded source (e.g. Helm read from storage Secrets because the CLI is absent).
    var notice: String? = nil
    /// An active "only the rows this summary counted" filter, with the control that
    /// clears it.
    var focus: ResourceFocus? = nil
    var clearFocus: (() -> Void)? = nil
    let loadIfNeeded: () -> Void
    let refresh: () -> Void
    let selectRow: (KubernetesResourceRow) -> Void

    @State private var filter = ""
    /// The filtered rows, computed once per change rather than once per read.
    ///
    /// `rows` was a computed property that scanned the whole list, and `body` read
    /// it five times — for the subtitle, the empty check, the count, the summary
    /// panel, and the table. On a namespace with a few thousand pods that was five
    /// full passes for every keystroke in the search field.
    @State private var rows: [KubernetesResourceRow] = []

    /// The table shares the page's scroll view, so its `LazyVStack` has no vertical
    /// viewport to be lazy against and every row it is handed is built. Until the
    /// table owns its own scrolling, the row count is what bounds the work.
    static let rowCap = 500

    private var visibleRows: [KubernetesResourceRow] {
        rows.count > Self.rowCap ? Array(rows.prefix(Self.rowCap)) : rows
    }

    private func recomputeRows() {
        // Focus first, then the search box: the chip narrows the list to the rows a
        // summary counted, and typing searches within that.
        var baseRows = list?.rows ?? []
        if let focus, focus.section == section {
            baseRows = baseRows.filter(focus.matches)
        }
        rows = KubernetesResourceRow.filtered(baseRows, matching: filter)
    }

    private var emptyTitle: String {
        filter.isEmpty ? "No \(section.rawValue)" : "No matching \(section.rawValue.lowercased())"
    }

    private var emptyMessage: String {
        guard filter.isEmpty else { return "No \(section.rawValue.lowercased()) match '\(filter)'." }
        return emptyMessageOverride ?? "There are no \(section.rawValue.lowercased()) in the selected namespace scope."
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
                if let focus, focus.section == section, let clearFocus {
                    ResourceFocusChip(focus: focus, matchCount: rows.count, clear: clearFocus)
                }
                if let notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                resourceSummaryPanel
                if rows.isEmpty {
                    CTXGlassPanel {
                        CTXEmptyStateView(title: emptyTitle, message: emptyMessage, systemImage: section.systemImage)
                    }
                } else {
                    if rows.count > Self.rowCap {
                        Text("Showing the first \(Self.rowCap) of \(rows.count) \(section.rawValue.lowercased()). Narrow the list with the search field.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    CTXResourceTable(section: section, rows: visibleRows, selectedRowID: selectedRow?.id, showsNamespaceColumn: showsNamespaceColumn, onSelect: selectRow)
                }
            }
        }
        // Claims the full width it is offered.
        //
        // A `VStack` sizes to its widest child, and the widest child here is the
        // table — which sizes itself from a width it measures off its own frame,
        // starting at a 900pt default. Without this the two fed each other: the
        // table stayed at its default width, the stack shrank to match, and the
        // measurement never grew, so a full-screen window showed a table sized for a
        // small one with dead space beside it — and, because the resolver sheds
        // low-priority columns to fit, silently dropped Restarts and Node as well.
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            recomputeRows()
            loadIfNeeded()
        }
        .onChange(of: filter) { _, _ in recomputeRows() }
        .onChange(of: focus) { _, _ in recomputeRows() }
        .onChange(of: list?.loadedAt) { _, _ in recomputeRows() }
        .onChange(of: list?.rows.count) { _, _ in recomputeRows() }
        .animation(.easeInOut(duration: 0.12), value: isLoading)
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
            CTXSearchField(placeholder: "Search...", text: $filter)
                .frame(width: 230)
                .help("Search loaded \(section.rawValue.lowercased()) by name, namespace, or status.")
        }
    }

    private var compactToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            CTXSectionHeader(title: section.rawValue, subtitle: subtitle)
            CTXSearchField(placeholder: "Search...", text: $filter)
                .frame(width: 230)
                .help("Search loaded \(section.rawValue.lowercased()) by name, namespace, or status.")
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
            case .cronjobs:
                ResourceSummaryPanel(
                    title: "CronJobs Schedule",
                    detail: "\(rows.count) automated scheduled jobs configured in this scope",
                    badgeTitle: countTitle(rows.count, noun: "cronjob"),
                    systemImage: section.systemImage,
                    tint: .orange
                )
            case .gitops:
                let providers = Set(rows.compactMap { $0.cells["Provider"] }).sorted()
                let outOfSync = rows.filter { ($0.cells["Status"] ?? "").lowercased() == "outofsync" }.count
                ResourceSummaryPanel(
                    title: outOfSync > 0 ? "Applications out of sync" : "GitOps applications",
                    detail: providers.isEmpty
                        ? "\(rows.count) applications"
                        : "\(providers.joined(separator: " · ")) · \(rows.count - outOfSync) synced · \(outOfSync) out of sync",
                    badgeTitle: countTitle(rows.count, noun: "app"),
                    systemImage: section.systemImage,
                    tint: outOfSync > 0 ? .orange : .indigo
                )
            case .helm:
                let failed = rows.filter { !["deployed", "superseded"].contains(($0.cells["Status"] ?? "").lowercased()) }.count
                ResourceSummaryPanel(
                    title: failed > 0 ? "Releases need attention" : "Helm releases",
                    detail: "\(rows.count - failed) deployed · \(failed) not deployed",
                    badgeTitle: countTitle(rows.count, noun: "release"),
                    systemImage: section.systemImage,
                    tint: failed > 0 ? .orange : .cyan
                )
            case .events:
                EventSummaryPanel(summary: KubernetesEventsSummary.summarize(rows: rows, status: list.status), eventCount: rows.count)
            default:
                ResourceSummaryPanel(
                    title: section.rawValue,
                    detail: "\(rows.count) items loaded",
                    badgeTitle: countTitle(rows.count, noun: "item"),
                    systemImage: section.systemImage,
                    tint: .blue
                )
            }
        }
    }

    private func countTitle(_ count: Int, noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

struct ResourceSummaryPanel: View {
    let title: String
    let detail: String
    let badgeTitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        CTXGlassPanel(padding: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(.caption, weight: .semibold))
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
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(.caption, weight: .semibold))
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
