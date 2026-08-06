import CTXCore
import Foundation
import SwiftUI

/// GitOps and Helm loading.
///
/// Neither is a plain `kubectl get <kind>`: GitOps state lives in controller-owned
/// custom resources that may not be installed at all, and Helm's authoritative view
/// comes from the `helm` CLI. Both therefore sit outside `ResourceRefreshCoordinator`
/// and own their loading here, but present the same `KubernetesResourceList` the
/// shared table already knows how to render.
extension ClusterWorkspaceViewModel {

    // MARK: - GitOps

    /// GitOps is read cluster-wide (see `KubernetesGitOpsReader.applications`), so
    /// it deliberately does not reload on a namespace switch — the answer is the
    /// same for every namespace.
    func loadGitOps(bypassCache: Bool = false) {
        if !bypassCache, let loadedAt = gitOpsLoadedAt, Date().timeIntervalSince(loadedAt) <= staleThreshold {
            return
        }
        gitOpsTask?.cancel()
        isLoadingGitOps = true
        let started = Date()
        gitOpsTask = Task { [weak self] in
            guard let self else { return }
            // `defer` rather than a trailing assignment: an early `return` on
            // cancellation would otherwise leave the spinner running forever.
            defer { isLoadingGitOps = false }
            let result = await gitOpsReader.applications(context: context, namespace: selectedNamespace)
            guard !Task.isCancelled else { return }
            gitOpsResult = result
            // A failed read must not blank a screen that already showed real apps.
            if result.status == .reachable || gitOpsList == nil {
                gitOpsList = Self.list(from: result, columns: Self.gitOpsColumns)
                gitOpsLoadedAt = Date()
            }
            gitOpsTask = nil
            CTXPerfLog.log(
                step: "screen_open",
                contextID: context.id,
                namespace: selectedNamespace.storageValue,
                kind: "gitops",
                cache: .miss,
                durationMs: max(0, Int(Date().timeIntervalSince(started) * 1000)),
                outcome: result.status == .reachable ? .success : .error
            )
        }
    }

    static let gitOpsColumns = [
        "Namespace", "Name", "Provider", "Source", "Status", "Health", "Repo URL", "Target", "Synced", "Age"
    ]

    private static func list(from result: GitOpsReadResult, columns: [String]) -> KubernetesResourceList {
        let rows = result.items.map { item -> KubernetesResourceRow in
            // Multi-source detail belongs in Source, not appended to Name — the
            // Name cell has a copy button, and it must yield the real application
            // name that `kubectl` and `argocd` would accept.
            var source = item.sourceKind.rawValue
            if item.additionalSourceCount > 0 {
                source += " +\(item.additionalSourceCount)"
            }
            return KubernetesResourceRow(
                id: item.id,
                cells: [
                    "Namespace": item.namespace,
                    "Name": item.name,
                    "Provider": item.provider,
                    "Source": source,
                    "Status": item.syncStatus,
                    "Health": item.healthStatus,
                    "Repo URL": item.repoURL,
                    "Target": item.targetRevision,
                    "Synced": item.syncedRevision,
                    "Age": item.age
                ],
                warning: Self.isUnhealthy(item)
            )
        }
        return KubernetesResourceList(
            kind: .workloads,
            columns: columns,
            rows: rows,
            status: result.status,
            diagnostic: result.diagnostic,
            loadedAt: Date()
        )
    }

    private static func isUnhealthy(_ item: GitOpsApplicationItem) -> Bool {
        let healthy = ["healthy", "synced", "suspended", KubernetesGitOpsService.unknownValue]
        return !healthy.contains(item.healthStatus.lowercased())
            || item.syncStatus.lowercased() == "outofsync"
    }

    /// Copy for the empty state, which has to distinguish three genuinely different
    /// situations: no controller installed, a controller installed with nothing to
    /// show, and a scope that filtered everything out.
    /// Surfaces a partially-failed read: some controllers answered and their apps
    /// are on screen, but at least one could not be read, so the list is incomplete.
    var gitOpsSourceNotice: String? {
        guard let result = gitOpsResult,
              result.status == .reachable,
              let diagnostic = result.diagnostic
        else { return nil }
        return "This list may be incomplete — \(diagnostic.commandKind) could not be read: \(diagnostic.stderrSummary)"
    }

    var gitOpsEmptyMessage: String {
        guard let result = gitOpsResult else { return "Loading GitOps applications." }
        if result.installedControllers.isEmpty {
            return "Neither ArgoCD nor Flux CD is installed on this cluster. CTX looks for ArgoCD Applications and Flux Kustomizations and HelmReleases."
        }
        let controllers = result.installedControllers.joined(separator: " and ")
        return "\(controllers) is installed, but reports no applications anywhere on this cluster."
    }

    // MARK: - Helm

    func loadHelm(bypassCache: Bool = false) {
        if !bypassCache, let loadedAt = helmLoadedAt, Date().timeIntervalSince(loadedAt) <= staleThreshold {
            return
        }
        helmTask?.cancel()
        isLoadingHelm = true
        let started = Date()
        helmTask = Task { [weak self] in
            guard let self else { return }
            defer { isLoadingHelm = false }
            let result = await helmReader.releases(context: context, namespace: selectedNamespace)
            guard !Task.isCancelled else { return }
            helmResult = result
            if result.status == .reachable || helmList == nil {
                helmList = Self.list(from: result)
                helmLoadedAt = Date()
            }
            helmTask = nil
            CTXPerfLog.log(
                step: "screen_open",
                contextID: context.id,
                namespace: selectedNamespace.storageValue,
                kind: "helm",
                cache: .miss,
                durationMs: max(0, Int(Date().timeIntervalSince(started) * 1000)),
                outcome: result.status == .reachable ? .success : .error
            )
        }
    }

    private static func list(from result: HelmReadResult) -> KubernetesResourceList {
        let rows = result.items.map { item in
            KubernetesResourceRow(
                id: item.id,
                cells: [
                    "Namespace": item.namespace,
                    "Name": item.name,
                    "Chart": item.chart,
                    "App Version": item.appVersion,
                    "Revision": String(item.revision),
                    "Status": item.status,
                    "Updated": item.updated
                ],
                // Anything not cleanly deployed is worth flagging: failed,
                // uninstalled, and every pending-* state a stuck upgrade leaves behind.
                warning: item.status.lowercased() != "deployed"
            )
        }
        return KubernetesResourceList(
            kind: .workloads,
            columns: ["Namespace", "Name", "Chart", "App Version", "Revision", "Status", "Updated"],
            rows: rows,
            status: result.status,
            diagnostic: result.diagnostic,
            loadedAt: Date()
        )
    }

    /// Shown when releases were found through the Secret-label fallback, so it is
    /// clear why Chart and App Version read as unknown rather than looking broken.
    var helmSourceNotice: String? {
        guard let result = helmResult, result.source == .releaseSecretLabels, !result.items.isEmpty else { return nil }
        return "helm was not found on PATH. Showing release metadata from Helm's storage Secrets — chart and app version are inside the Secret payload, which CTX does not read."
    }

    var helmEmptyMessage: String {
        guard helmResult != nil else { return "Loading Helm releases." }
        return "No Helm releases in this namespace scope."
    }
}
