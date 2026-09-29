import CTXCore
import Foundation

extension ClusterWorkspaceViewModel {
    /// Only the currently-scoped rows for each kind — not every namespace this
    /// session has ever cached. `resourceLists` keeps a namespace's last-known
    /// rows around after switching away (that's what makes switching back
    /// instant), so scanning the whole dictionary here would have correlated a
    /// pod from one namespace against a service from another, and re-run the
    /// full validator over data from namespaces nobody is even looking at.
    private func currentlyScopedRows(for kind: KubernetesResourceKind) -> [KubernetesResourceRow] {
        guard let list = resourceLists[resourceKey(kind: kind)], list.status == .reachable else { return [] }
        return list.rows
    }

    public func recalculateDiagnostics() {
        let previouslyKnownIssueIDs = Set(diagnosticReport.allIssues.map(\.id))

        diagnosticReport = KubernetesConfigurationValidator.validate(
            services: currentlyScopedRows(for: .services),
            workloads: currentlyScopedRows(for: .workloads),
            pods: currentlyScopedRows(for: .pods),
            ingress: currentlyScopedRows(for: .ingress),
            configMaps: currentlyScopedRows(for: .configMaps),
            secrets: currentlyScopedRows(for: .secretMetadata),
            pvcs: currentlyScopedRows(for: .pvc),
            nodes: currentlyScopedRows(for: .nodes)
        )

        // Dispatch a native notification only for findings that weren't already
        // known — a cluster with thirty pre-existing crash-looping pods must not
        // re-alert for all thirty on every refresh, only for whatever is newly
        // broken since the last recalculation. Issue ids are stable per
        // rule+resource (see `ResourceDiagnosticIssue.init`), so this comparison
        // survives the report being rebuilt from scratch on every call.
        for issue in diagnosticReport.allIssues where !previouslyKnownIssueIDs.contains(issue.id) {
            guard issue.severity == .error || issue.category == .runtime else { continue }
            AppNotificationService.shared.sendClusterAnomaly(ClusterAnomalyNotificationPayload(
                contextID: context.id,
                contextName: context.contextName,
                resourceKind: issue.resourceKind.rawValue,
                resourceName: issue.resourceName,
                namespace: issue.resourceNamespace,
                ruleId: issue.ruleId,
                title: issue.title,
                message: issue.message,
                isCritical: issue.severity == .error
            ))
        }
    }

    public func diagnostics(for resourceID: String) -> [ResourceDiagnosticIssue] {
        diagnosticReport.issuesByResourceID[resourceID] ?? []
    }

    public func inspectDiagnostics(for row: KubernetesResourceRow, kind: KubernetesResourceKind) {
        let section = ClusterWorkspaceSection.section(for: kind) ?? .workloads
        selectResource(row, in: section)
        selectInspectorTab(.diagnostics)
    }
}
