import CTXCore
import SwiftUI

extension ClusterWorkspaceViewModel {
    var connectionStatusTitle: String {
        overviewSummary.apiStatus.shortLabel
    }

    var connectionStatusTint: Color {
        overviewSummary.apiStatus.tint
    }

    var rbacStatusTitle: String {
        let known = overviewSummary.rbac.filter { $0.allowed != nil }
        guard !known.isEmpty else { return "RBAC unknown" }
        let allowed = known.filter { $0.allowed == true }.count
        return "RBAC \(allowed)/\(overviewSummary.rbac.count)"
    }

    var rbacStatusTint: Color {
        overviewSummary.rbac.contains { $0.allowed == false } ? .orange : overviewSummary.apiStatus.tint
    }

    var lastRefreshedText: String {
        guard let lastRefreshed else { return "Not refreshed" }
        return lastRefreshed.formatted(date: .omitted, time: .shortened)
    }

    var overviewMetrics: [ClusterWorkspaceMetric] {
        [
            ClusterWorkspaceMetric(title: "API", value: overviewSummary.apiStatus.cardValue, subtitle: overviewSummary.apiStatus.cardSubtitle, systemImage: "antenna.radiowaves.left.and.right", tint: overviewSummary.apiStatus.tint),
            ClusterWorkspaceMetric(title: "Namespaces", value: countText(overviewSummary.namespaces.count, status: overviewSummary.namespaces.status), subtitle: namespaceSubtitle, systemImage: "square.stack.3d.up", tint: overviewSummary.namespaces.status.tint, targetSection: .namespaces),
            ClusterWorkspaceMetric(title: "Nodes", value: countText(overviewSummary.nodes.total, status: overviewSummary.nodes.status), subtitle: nodesSubtitle, systemImage: "server.rack", tint: overviewSummary.nodes.status.tint, targetSection: .nodes),
            ClusterWorkspaceMetric(title: "Pods", value: countText(overviewSummary.pods.total, status: overviewSummary.pods.status), subtitle: podsSubtitle, systemImage: "circle.grid.3x3", tint: overviewSummary.pods.status.tint, targetSection: .pods),
            ClusterWorkspaceMetric(title: "Workloads", value: countText(overviewSummary.workloads.total, status: overviewSummary.workloads.status), subtitle: workloadsSubtitle, systemImage: "shippingbox", tint: overviewSummary.workloads.status.tint, targetSection: .workloads),
            ClusterWorkspaceMetric(title: "Services", value: countText(overviewSummary.services.total, status: overviewSummary.services.status), subtitle: servicesSubtitle, systemImage: "network", tint: overviewSummary.services.status.tint, targetSection: .services),
            ClusterWorkspaceMetric(title: "Ingress", value: countText(overviewSummary.ingress.total, status: overviewSummary.ingress.status), subtitle: ingressSubtitle, systemImage: "point.3.connected.trianglepath.dotted", tint: overviewSummary.ingress.status.tint, targetSection: .ingress),
            ClusterWorkspaceMetric(title: "Events", value: eventsValue, subtitle: eventsSubtitle, systemImage: "waveform.path.ecg", tint: overviewSummary.events.status.tint, targetSection: .events),
            ClusterWorkspaceMetric(title: "RBAC", value: rbacValue, subtitle: "Read permissions", systemImage: "lock.shield", tint: rbacStatusTint)
        ]
    }

    var overviewNotice: ClusterOverviewNotice? {
        if isRefreshingOverview {
            return nil
        }
        guard let issue = lastRefreshIssue ?? overviewSummary.primaryFailure else {
            return nil
        }
        let presentation = issue.category.presentation
        return ClusterOverviewNotice(
            title: presentation.title,
            message: presentation.message,
            systemImage: presentation.systemImage,
            tint: issue.category.tint,
            diagnostics: issue.safeSummary,
            commandHint: manualCommandHint(for: issue.commandKind)
        )
    }

    /// Appended to a card's subtitle when its *current* status isn't reachable but
    /// the big number is still a preserved last-known value, not a fresh one —
    /// keeps that distinction honest instead of silently presenting stale data as
    /// current.
    private func staleSuffix(hasPreservedData: Bool) -> String {
        hasPreservedData ? " · showing last known data" : ""
    }

    private var nodesSubtitle: String {
        switch overviewSummary.nodes.status {
        case .notChecked:
            return "Open Nodes"
        case .reachable:
            guard let ready = overviewSummary.nodes.ready, let notReady = overviewSummary.nodes.notReady else {
                return overviewSummary.nodes.status.cardSubtitle
            }
            return "\(ready) ready · \(notReady) not ready"
        default:
            return overviewSummary.nodes.status.cardSubtitle + staleSuffix(hasPreservedData: overviewSummary.nodes.total != nil)
        }
    }

    private var namespaceSubtitle: String {
        switch overviewSummary.namespaces.status {
        case .reachable:
            return overviewSummary.namespaces.activeNamespace
        case .notChecked:
            return overviewSummary.namespaces.status.cardSubtitle
        default:
            return overviewSummary.namespaces.status.cardSubtitle + staleSuffix(hasPreservedData: overviewSummary.namespaces.count != nil)
        }
    }

    private var podsSubtitle: String {
        switch overviewSummary.pods.status {
        case .notChecked:
            return "Open Pods"
        case .reachable:
            return "\(overviewSummary.pods.running) running · \(overviewSummary.pods.failing) failing"
        default:
            return overviewSummary.pods.status.cardSubtitle + staleSuffix(hasPreservedData: overviewSummary.pods.total != nil)
        }
    }

    private var workloadsSubtitle: String {
        switch overviewSummary.workloads.status {
        case .notChecked:
            return "Open Workloads"
        case .reachable:
            return "\(overviewSummary.workloads.healthy) healthy · \(overviewSummary.workloads.unhealthy) needs attention"
        default:
            return overviewSummary.workloads.status.cardSubtitle + staleSuffix(hasPreservedData: overviewSummary.workloads.total != nil)
        }
    }

    private var servicesSubtitle: String {
        switch overviewSummary.services.status {
        case .notChecked:
            return "Open Services"
        case .reachable:
            return "\(overviewSummary.services.exposed) exposed"
        default:
            return overviewSummary.services.status.cardSubtitle + staleSuffix(hasPreservedData: overviewSummary.services.total != nil)
        }
    }

    private var ingressSubtitle: String {
        switch overviewSummary.ingress.status {
        case .notChecked:
            return "Open Ingress"
        case .reachable:
            return "\(overviewSummary.ingress.routed) routed · \(overviewSummary.ingress.tls) TLS"
        default:
            return overviewSummary.ingress.status.cardSubtitle + staleSuffix(hasPreservedData: overviewSummary.ingress.total != nil)
        }
    }

    private var eventsValue: String {
        if let warningCount = overviewSummary.events.warningCount {
            return warningCount == 0 ? "Quiet" : String(warningCount)
        }
        return overviewSummary.events.status == .notChecked ? "On demand" : overviewSummary.events.status.cardValue
    }

    private var eventsSubtitle: String {
        switch overviewSummary.events.status {
        case .notChecked:
            return "Warnings"
        case .reachable:
            if overviewSummary.events.topWarningCount > 1,
               let reason = overviewSummary.events.topWarningReason,
               let object = overviewSummary.events.topWarningObject {
                return "\(overviewSummary.events.topWarningCount)x \(reason) · \(object)"
            }
            if let reason = overviewSummary.events.latestWarningReason, let object = overviewSummary.events.latestWarningObject {
                return [reason, object, overviewSummary.events.latestWarningLastSeen].compactMap { $0 }.joined(separator: " · ")
            }
            return "Warnings"
        default:
            return overviewSummary.events.status.cardSubtitle + staleSuffix(hasPreservedData: overviewSummary.events.warningCount != nil)
        }
    }

    private var rbacValue: String {
        let known = overviewSummary.rbac.filter { $0.allowed != nil }
        guard !known.isEmpty else { return "Unknown" }
        let allowed = known.filter { $0.allowed == true }.count
        if allowed == overviewSummary.rbac.count { return "OK" }
        if allowed == 0 { return "Denied" }
        return "Limited"
    }

    private func countText(_ count: Int?, status: KubernetesCheckStatus) -> String {
        if let count {
            return String(count)
        }
        switch status {
        case .notChecked: return "On demand"
        case .permissionDenied: return "Denied"
        case .contextNotFound: return "Missing"
        case .kubectlMissing: return "Missing"
        case .timeout: return "Timeout"
        case .unauthorized: return "Unauthorized"
        case .authPluginFailed, .awsSSOExpired, .gcpAuthExpired: return "Auth"
        case .tlsError: return "TLS"
        case .kubeconfigError: return "Config"
        case .unreachable: return "Down"
        default: return "Unknown"
        }
    }

    private func manualCommandHint(for kind: String) -> String {
        let base = "kubectl --context \(context.contextName)"
        let prefix = context.kubeconfigPath.isEmpty ? "" : "KUBECONFIG=\(context.kubeconfigPath) "
        let command: String
        switch kind {
        case "Nodes": command = "\(base) get nodes -o json"
        case "Pods": command = "\(base) get pods -A -o json"
        case "Events": command = "\(base) get events -A -o json"
        default: command = "\(base) get namespaces -o json"
        }
        return prefix + command
    }
}
