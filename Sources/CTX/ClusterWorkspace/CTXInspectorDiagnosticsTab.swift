import CTXCore
import SwiftUI

struct CTXInspectorDiagnosticsTab: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let selection: ClusterWorkspaceResourceSelection

    private var issues: [ResourceDiagnosticIssue] {
        viewModel.diagnostics(for: selection.row.id)
    }

    private var errors: [ResourceDiagnosticIssue] {
        issues.filter { $0.severity == .error }
    }

    private var warnings: [ResourceDiagnosticIssue] {
        issues.filter { $0.severity == .warning }
    }

    private var infos: [ResourceDiagnosticIssue] {
        issues.filter { $0.severity == .info }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if issues.isEmpty {
                    cleanState
                } else {
                    summaryHeader
                    ForEach(issues) { issue in
                        issueCard(issue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cleanState: some View {
        CTXGlassPanel(padding: 24) {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .frame(width: 56, height: 56)
                    .background(Color.green.opacity(0.12), in: Circle())

                Text("No Misconfigurations Found")
                    .font(.system(.headline, weight: .bold))

                Text("This resource passed cross-resource validation checks, including service selectors, secret and config references, security contexts, probes, and resource limits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "stethoscope")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("\(issues.count) \(issues.count == 1 ? "Issue" : "Issues") Detected")
                    .font(.system(.subheadline, weight: .bold))
            }

            Spacer()

            if !errors.isEmpty {
                severityPill(count: errors.count, title: "Errors", color: .red, icon: "xmark.octagon.fill")
            }
            if !warnings.isEmpty {
                severityPill(count: warnings.count, title: "Warnings", color: .orange, icon: "exclamationmark.triangle.fill")
            }
            if !infos.isEmpty {
                severityPill(count: infos.count, title: "Recommendations", color: .blue, icon: "info.circle.fill")
            }
        }
        .padding(.horizontal, 4)
    }

    private func severityPill(count: Int, title: String, color: Color, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text("\(count) \(title)")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func issueCard(_ issue: ResourceDiagnosticIssue) -> some View {
        let tintColor = issue.severity.tint

        return CTXGlassPanel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: issue.severity.systemImage)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(tintColor)
                        .frame(width: 28, height: 28)
                        .background(tintColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(issue.title)
                                .font(.system(.body, weight: .semibold))
                                .foregroundStyle(Color.primary)

                            DiagnosticCategoryBadge(category: issue.category)

                            Text(issue.ruleId)
                                .font(.system(.caption2, design: .monospaced, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Text(issue.message)
                            .font(.system(.callout))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    Button {
                        viewModel.selectInspectorTab(.yaml)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 10))
                            Text("View Spec")
                                .font(.system(.caption2, weight: .semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("View YAML spec for this resource")
                }

                // Actionable recommendation box
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.yellow)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recommendation")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(.primary)

                        Text(issue.recommendation)
                            .font(.system(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 0.75)
                }
            }
        }
    }

}
