import CTXCore
import SwiftUI

struct ClusterOverviewView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    @State private var expandedCard: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                CTXSectionHeader(title: "Overview")
                Spacer()
                CTXLastUpdatedLabel(date: viewModel.lastRefreshed)
            }

            ClusterTelemetryView(viewModel: viewModel)

            healthScorePanel

            LazyVGrid(columns: cardColumns(minimum: 210), spacing: 12) {
                ForEach(viewModel.overviewMetrics) { metric in
                    Button {
                        activate(metric)
                    } label: {
                        metricCard(metric)
                    }
                    .buttonStyle(.plain)
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

    private var healthScorePanel: some View {
        let pods = viewModel.resourceList(for: .pods)?.rows ?? []
        let workloads = viewModel.resourceList(for: .workloads)?.rows ?? []
        let score = KubernetesRemediationAdvisor.calculateSecurityHealthScore(rows: pods + workloads)
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
                        Text("Workload Security & Reliability Score")
                            .font(.system(size: 12, weight: .semibold))
                        CTXStatusBadge(title: score >= 85 ? "Optimal" : "Attention Recommended", systemImage: "shield.checkered", tint: color)
                    }
                    Text("\(pods.count) pods & \(workloads.count) workloads analyzed for resource limits, security contexts, and container isolation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

func cardColumns(minimum: CGFloat) -> [GridItem] {
    [GridItem(.adaptive(minimum: minimum, maximum: 340), spacing: 12, alignment: .top)]
}
