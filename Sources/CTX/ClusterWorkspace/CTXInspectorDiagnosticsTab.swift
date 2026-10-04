import CTXCore
import SwiftUI

struct DiagnosticEvaluatedCheck: Identifiable {
    var id: String { title }
    let title: String
    let subtitle: String
    let status: CheckStatus
    let icon: String

    enum CheckStatus {
        case passed
        case warning
        case info

        var tint: Color {
            switch self {
            case .passed: .green
            case .warning: .orange
            case .info: .blue
            }
        }
    }
}

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
            VStack(alignment: .leading, spacing: 16) {
                if issues.isEmpty {
                    cleanSummaryCard
                } else {
                    summaryHeader
                    ForEach(issues) { issue in
                        issueCard(issue)
                    }
                }

                if !evaluatedChecks.isEmpty {
                    Divider().opacity(0.3)
                    evaluatedChecksSection
                }



                if !matchingEvents.isEmpty {
                    Divider().opacity(0.3)
                    recentEventsSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

    }



    // MARK: - Clean State Header

    private var cleanSummaryCard: some View {
        CTXGlassPanel(padding: 16) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .frame(width: 44, height: 44)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("All Health & Security Checks Passing")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(Color.primary)

                    Text("Resource passed cross-resource validation, probe checks, security standards, and reference integrity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Healthy")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.green)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12), in: Capsule())
            }
        }
    }

    // MARK: - Issue Header

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

    // MARK: - Issue Card

    private func issueCard(_ issue: ResourceDiagnosticIssue) -> some View {
        let tintColor = issue.severity.tint
        let guide = KubernetesDiagnosticGuide.guide(for: issue.ruleId)
        let hasSpecTab = CTXInspectorTab.visibleTabs(for: selection.kind).contains(.spec)

        return CTXGlassPanel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: issue.severity.systemImage)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(tintColor)
                        .frame(width: 28, height: 28)
                        .background(tintColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
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

                        HStack(spacing: 6) {
                            Text("Spec Target:")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(guide.specPath)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                                .textSelection(.enabled)
                        }
                        .padding(.top, 2)
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 6) {
                        if hasSpecTab {
                            Button {
                                viewModel.selectInspectorTab(.spec)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 10))
                                    Text("Spec & Config")
                                        .font(.system(.caption2, weight: .semibold))
                                }
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("Jump to visual Spec & Config tab")
                        }

                        Button {
                            viewModel.selectInspectorTab(.yaml)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "curlybraces")
                                    .font(.system(size: 10))
                                Text("Manifest")
                                    .font(.system(.caption2, weight: .semibold))
                            }
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("View YAML spec for this resource")
                    }
                }

                if let yamlFix = guide.suggestedYAML {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.accentColor)
                            Text("Suggested YAML Configuration")
                                .font(.system(.caption2, weight: .bold))
                                .foregroundStyle(.primary)
                            Spacer()
                            CTXCopyIconButton(value: yamlFix)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(yamlFix)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.15), lineWidth: 0.75)
                    }
                }

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

    // MARK: - Evaluated Checks Section

    private var evaluatedChecksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HEALTH & COMPLIANCE AUDIT")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)

            VStack(spacing: 6) {
                ForEach(evaluatedChecks) { check in
                    HStack(spacing: 10) {
                        Image(systemName: check.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(check.status.tint)
                            .frame(width: 22, height: 22)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.primary)
                            Text(check.subtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: check.status == .passed ? "checkmark" : "exclamationmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(check.status.tint)
                            .padding(4)
                            .background(check.status.tint.opacity(0.12), in: Circle())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private var evaluatedChecks: [DiagnosticEvaluatedCheck] {
        var checks: [DiagnosticEvaluatedCheck] = []

        // 1. Pods & Replicas Health
        if let ready = selection.row.cells["Ready"], !ready.isEmpty {
            let parts = ready.split(separator: "/")
            let isReady = parts.count == 2 && parts[0] == parts[1] && parts[0] != "0"
            checks.append(DiagnosticEvaluatedCheck(
                title: "Workload Replicas & Availability",
                subtitle: "\(ready) Pods ready · \(selection.row.cells["Available"] ?? parts[0].description) available",
                status: isReady ? .passed : .warning,
                icon: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            ))
        } else if let status = selection.row.cells["Status"], !status.isEmpty {
            let isRunning = status.lowercased() == "running" || status.lowercased() == "active"
            checks.append(DiagnosticEvaluatedCheck(
                title: "Pod Runtime Phase",
                subtitle: "Phase: \(status) · Restarts: \(selection.row.cells["Restarts"] ?? "0")",
                status: isRunning ? .passed : .warning,
                icon: isRunning ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            ))
        }

        // 2. Probes
        if let probes = selection.row.cells["Probes"], !probes.isEmpty {
            let hasLiveness = probes.contains("liveness")
            let hasReadiness = probes.contains("readiness")
            if hasLiveness && hasReadiness {
                checks.append(DiagnosticEvaluatedCheck(
                    title: "Container Probes",
                    subtitle: "Liveness and Readiness health probes active",
                    status: .passed,
                    icon: "checkmark.circle.fill"
                ))
            } else {
                let missing = !hasLiveness ? "Liveness" : "Readiness"
                checks.append(DiagnosticEvaluatedCheck(
                    title: "Container Probes",
                    subtitle: "\(missing) probe not configured in pod template",
                    status: .warning,
                    icon: "exclamationmark.triangle.fill"
                ))
            }
        }

        // 3. Security Standards
        let security = selection.row.cells["Security"] ?? ""
        if security.contains("privileged") {
            checks.append(DiagnosticEvaluatedCheck(
                title: "Security Context",
                subtitle: "Container runs in privileged mode (host root privileges)",
                status: .warning,
                icon: "exclamationmark.shield.fill"
            ))
        } else if security.contains("runAsRoot") {
            checks.append(DiagnosticEvaluatedCheck(
                title: "Security Context",
                subtitle: "Container runs as root user (UID 0)",
                status: .warning,
                icon: "exclamationmark.shield.fill"
            ))
        } else {
            checks.append(DiagnosticEvaluatedCheck(
                title: "Security Context",
                subtitle: "Non-privileged · Restricted root execution",
                status: .passed,
                icon: "shield.lefthalf.filled.badge.checkmark"
            ))
        }

        // 4. Resource Allocation
        let hasLimits = selection.row.cells["HasLimits"]
        if hasLimits == "true" {
            checks.append(DiagnosticEvaluatedCheck(
                title: "Resource Limits",
                subtitle: "CPU & Memory quota limits enforced",
                status: .passed,
                icon: "gauge.with.needle.fill"
            ))
        } else if hasLimits == "false" {
            checks.append(DiagnosticEvaluatedCheck(
                title: "Resource Limits",
                subtitle: "No limits set · Container can consume unbounded node memory",
                status: .warning,
                icon: "gauge.with.needle"
            ))
        }

        // 5. Config & Secrets
        let configMaps = selection.row.cells["ConfigMaps"] ?? ""
        let secrets = selection.row.cells["Secrets"] ?? ""
        let configCount = configMaps.isEmpty ? 0 : configMaps.split(separator: ",").count
        let secretCount = secrets.isEmpty ? 0 : secrets.split(separator: ",").count
        if configCount > 0 || secretCount > 0 {
            checks.append(DiagnosticEvaluatedCheck(
                title: "Bound Dependencies",
                subtitle: "\(configCount) ConfigMap\(configCount == 1 ? "" : "s") · \(secretCount) Secret\(secretCount == 1 ? "" : "s") referenced",
                status: .passed,
                icon: "link.circle.fill"
            ))
        }

        return checks
    }



    // MARK: - Recent Events Section

    private var recentEventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT CLUSTER EVENTS")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(matchingEvents.count) recorded")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            VStack(spacing: 6) {
                ForEach(matchingEvents.prefix(6)) { event in
                    let isWarning = (event.cells["Type"] ?? "").lowercased() == "warning"
                    let reason = event.cells["Reason"] ?? "Event"
                    let age = event.cells["Age"] ?? event.cells["Last"] ?? ""
                    let message = event.cells["Message"] ?? ""

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isWarning ? Color.orange : Color.blue)
                            .frame(width: 20, height: 20)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(reason)
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(isWarning ? Color.orange : Color.primary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background((isWarning ? Color.orange : Color.blue).opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                                if !age.isEmpty {
                                    Text(age)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if !message.isEmpty {
                                Text(message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private var matchingEvents: [KubernetesResourceRow] {
        guard let eventList = viewModel.resourceList(for: .events) else { return [] }
        let resourceName = selection.row.name.lowercased()
        let resourceNamespace = selection.row.namespace?.lowercased()
        return eventList.rows.filter { row in
            if let ns = resourceNamespace, let rowNs = row.namespace?.lowercased(), !rowNs.isEmpty, rowNs != ns {
                return false
            }
            let object = (row.cells["Object"] ?? "").lowercased()
            let message = (row.cells["Message"] ?? "").lowercased()
            return object.contains(resourceName) || message.contains(resourceName)
        }
    }
}
