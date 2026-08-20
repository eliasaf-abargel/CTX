import CTXCore
import SwiftUI

struct ClusterOverviewView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    @State private var expandedCard: String?
    @State private var availableWidth: CGFloat = 1000

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                CTXSectionHeader(title: "Overview")
                Spacer()
                CTXLastUpdatedLabel(date: viewModel.lastRefreshed)
            }

            ClusterTelemetryView(viewModel: viewModel)

            healthScorePanel

            LazyVGrid(columns: cardColumns(for: availableWidth), spacing: ClusterOverviewLayout.spacing) {
                ForEach(viewModel.overviewMetrics) { metric in
                    Button {
                        activate(metric)
                    } label: {
                        metricCard(metric)
                    }
                    .buttonStyle(.plain)
                    .frame(maxHeight: .infinity)
                    .help(helpText(for: metric))
                }
            }

            if expandedCard == "API" {
                apiDetailPanel
            } else if expandedCard == "RBAC" {
                rbacDetailPanel
            }

            // Neither branch had a `.transition`, so swapping the loading panel
            // for the (usually taller) diagnostic card — e.g. the moment an SSO
            // check finishes and fails — snapped instantly instead of animating,
            // which reads as the whole screen suddenly jumping. Only clusters
            // that actually hit a notice ever show this swap, matching reports
            // that it "doesn't happen on every cluster".
            if viewModel.isRefreshingOverview {
                CTXGlassPanel(padding: 14) {
                    CTXLoadingStateView(title: "Refreshing", message: "Running inspection checks.")
                }
                .transition(.opacity)
            } else if let notice = viewModel.overviewNotice {
                CTXDiagnosticCard(
                    systemImage: notice.systemImage,
                    tint: notice.tint,
                    title: notice.title,
                    message: notice.message,
                    diagnosticSummary: "\(notice.commandHint)\n\(notice.diagnostics)",
                    retry: { viewModel.refreshOverview() }
                )
                .transition(.opacity)
            }
        }
        // Fills the pane at any width; the column count adapts instead of the
        // content sitting capped and centred with empty margins beside it.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Read from the layout directly rather than routed through a preference.
        // A width that stays on its default is not a cosmetic problem: it puts
        // three 170pt columns in a 580pt pane, and every title and subtitle on
        // the screen truncates at once.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, width in
                        guard abs(width - availableWidth) > 1 else { return }
                        availableWidth = width
                    }
            }
        )
        .environment(\.overviewColumnWidth, availableWidth)
        .animation(.easeInOut(duration: 0.16), value: expandedCard)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isRefreshingOverview)
        .animation(.easeInOut(duration: 0.2), value: viewModel.overviewNotice != nil)
    }

    /// Namespaces/Nodes/Pods/Events navigate straight to their screen. API and
    /// RBAC have no dedicated screen — a full navigation target would be a fake
    /// destination, so they expand an inline detail panel instead.
    private func activate(_ metric: ClusterWorkspaceMetric) {
        if let target = metric.targetSection {
            viewModel.selectedSection = target
            return
        }
        expandedCard = expandedCard == metric.title ? nil : metric.title
    }

    private func helpText(for metric: ClusterWorkspaceMetric) -> String {
        if let target = metric.targetSection { return "Open \(target.rawValue)" }
        return "Show \(metric.title) details"
    }

    private func metricCard(_ metric: ClusterWorkspaceMetric) -> some View {
        CTXResourceCard(
            title: metric.title,
            value: metric.value,
            subtitle: metric.subtitle,
            systemImage: metric.systemImage,
            tint: metric.tint
        )
    }

    private var apiDetailPanel: some View {
        let diagnostic = viewModel.overviewSummary.diagnostics.first { $0.commandKind == "API" }
        return CTXGlassPanel(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("API health").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let diagnostic {
                        CTXDiagnosticsButton(summary: diagnostic.safeSummary)
                    }
                }
                Text(viewModel.overviewSummary.apiStatus.cardSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let diagnostic {
                    Text(diagnostic.safeSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var rbacDetailPanel: some View {
        CTXGlassPanel(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Read permissions").font(.system(size: 12, weight: .semibold))
                ForEach(viewModel.overviewSummary.rbac, id: \.resource) { permission in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(permission.allowed == true ? Color.green : (permission.allowed == false ? Color.red : Color.secondary))
                            .frame(width: 6, height: 6)
                        Text(permission.resource)
                            .font(.caption)
                        Spacer()
                        Text(permission.allowed == true ? "Allowed" : (permission.allowed == false ? "Denied" : "Unknown"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Scores what CTX has actually read. The title and subtitle name the four
    /// measured signals exactly — no claim about checks the advisor does not run.
    private var healthScorePanel: some View {
        let pods = viewModel.resourceList(for: .pods)?.rows ?? []
        let score = KubernetesRemediationAdvisor.workloadHygieneScore(pods: pods)
        let color: Color = score >= 85 ? .green : (score >= 60 ? .orange : .red)

        return CTXGlassPanel(padding: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(color.opacity(0.2), lineWidth: 5)
                        .frame(width: 44, height: 44)
                    Circle()
                        .trim(from: 0, to: CGFloat(score) / 100.0)
                        .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                    Text("\(score)%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Pod Hygiene Score")
                            .font(.system(size: 12, weight: .semibold))
                        CTXStatusBadge(title: score >= 85 ? "Optimal" : "Attention Recommended", systemImage: "shield.checkered", tint: color)
                    }
                    Text(pods.isEmpty
                         ? "Waiting for the pod list."
                         : "\(pods.count) pods in \(viewModel.telemetryScopeLabel), scored on restarts, failing state, and whether they declare CPU and memory requests and a memory limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

/// The Overview's single grid.
///
/// Everything on the screen — the three telemetry gauges and the nine metric cards —
/// is laid out on these columns, so their edges line up vertically all the way down.
func cardColumns(for width: CGFloat) -> [GridItem] {
    Array(
        repeating: GridItem(.flexible(), spacing: ClusterOverviewLayout.spacing, alignment: .top),
        count: ClusterOverviewLayout.columnCount(for: width)
    )
}

enum ClusterOverviewLayout {
    static let spacing: CGFloat = 12

    /// Three columns whenever the window is wide enough, then two, then one.
    ///
    /// Fixed counts rather than `.adaptive`, and the *same* count for the telemetry
    /// gauges and the metric cards, because that is what makes the screen read as one
    /// grid: every card edge lines up vertically all the way down. Three is also the
    /// only multi-column count that divides the nine metric cards evenly, so the last
    /// row is never a lonely leftover.
    ///
    /// The thresholds are the widths at which a column is still wide enough for
    /// a card's title, number and subtitle to sit unabbreviated: roughly 300pt
    /// of column for three, 250pt for two. Below that a single column reads
    /// better than two cramped ones.
    static func columnCount(for width: CGFloat) -> Int {
        if width >= 1000 { return 3 }
        if width >= 580 { return 2 }
        return 1
    }
}

/// Carries the Overview's measured width down to the telemetry grid, so both grids
/// resolve to the same column count from a single measurement.
private struct OverviewColumnWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1000
}

extension EnvironmentValues {
    var overviewColumnWidth: CGFloat {
        get { self[OverviewColumnWidthKey.self] }
        set { self[OverviewColumnWidthKey.self] = newValue }
    }
}
