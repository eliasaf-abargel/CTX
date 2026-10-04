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
            let displayNamespace = (!item.destinationNamespace.isEmpty && item.destinationNamespace != KubernetesGitOpsService.unknownValue)
                ? item.destinationNamespace
                : item.namespace

            return KubernetesResourceRow(
                id: item.id,
                cells: [
                    "Namespace": displayNamespace,
                    "Destination": item.destinationNamespace,
                    "Controller NS": item.namespace,
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

    func matchingGitOpsApplication(for appName: String?) -> GitOpsApplicationItem? {
        guard let raw = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let items = gitOpsResult?.items else { return nil }
        let clean = raw
            .replacingOccurrences(of: "^(argocd|flux)_", with: "", options: .regularExpression)
            .lowercased()

        return items.first { item in
            let itemLower = item.name.lowercased()
            let destLower = item.destinationNamespace.lowercased()
            return itemLower == raw.lowercased()
                || itemLower == clean
                || itemLower.contains(clean)
                || clean.contains(itemLower)
                || (!destLower.isEmpty && (destLower == clean || clean.contains(destLower)))
        }
    }

    var gitOpsEmptyMessage: String {
        guard let result = gitOpsResult else { return "Loading GitOps applications." }
        if result.installedControllers.isEmpty {
            return "Neither ArgoCD nor Flux CD is installed on this cluster. CTX looks for ArgoCD Applications and Flux Kustomizations and HelmReleases."
        }
        let controllers = result.installedControllers.joined(separator: " and ")
        if selectedNamespace != .allNamespaces {
            return "\(controllers) is installed, but reports no applications targeting '\(selectedNamespace.displayName)'."
        }
        return "\(controllers) is installed, but reports no applications anywhere on this cluster."
    }

    // MARK: - Telemetry

    /// Live utilisation for the Overview panel.
    ///
    /// Metrics move constantly, so this is the one screen where cached data goes
    /// stale in seconds rather than the workspace's usual thirty. It is refreshed on
    /// a short interval while Overview is on screen and stopped as soon as it isn't
    /// — a background poll against a production cluster nobody is looking at is
    /// exactly the kind of thing that shows up in an API-server audit log.
    static let telemetryRefreshInterval: TimeInterval = 15

    func loadTelemetry(force: Bool = false) {
        if !force, let loadedAt = telemetryLoadedAt,
           Date().timeIntervalSince(loadedAt) <= Self.telemetryRefreshInterval {
            return
        }
        guard telemetryTask == nil || force else { return }
        telemetryTask?.cancel()

        // Memory limits come from the pod list already on hand, in the same scope the
        // metrics read uses, so the two always describe the same set of pods.
        let podRows = resourceList(for: .pods)?.rows ?? []
        let limits = Dictionary(
            podRows.compactMap { row -> (String, Double)? in
                guard let raw = row.cells["Memory Limit"], let limit = Double(raw), limit > 0 else { return nil }
                let namespace = row.namespace.map { "\($0)/" } ?? ""
                return ("\(namespace)\(row.name)", limit)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Requests come from the same pod rows, summed. Committed capacity is what
        // decides whether anything can still be scheduled, and it is routinely far
        // higher than live utilisation.
        let requests = ClusterResourceRequests(
            cpuCores: podRows.compactMap { Double($0.cells["CPU Request Cores"] ?? "") }.reduce(0, +),
            memoryBytes: podRows.compactMap { Double($0.cells["Memory Request Bytes"] ?? "") }.reduce(0, +)
        )
        let podsByNode = Dictionary(grouping: podRows) { $0.cells["Node"] ?? "" }
            .filter { !$0.key.isEmpty }
            .mapValues { $0.count }
        let scope = selectedNamespace
        let podCount = podRows.isEmpty ? nil : podRows.count

        telemetryTask = Task { [weak self] in
            guard let self else { return }
            defer { telemetryTask = nil }
            let result = await metricsReader.telemetry(
                context: context,
                namespace: scope,
                podCount: podCount,
                podsByNode: podsByNode,
                requests: requests,
                memoryLimitsByPodID: limits
            )
            guard !Task.isCancelled else { return }
            telemetry = result
            telemetryLoadedAt = Date()
        }
    }

    /// The scope the pod-based figures were read for, shown next to them so a
    /// namespace-scoped count is never mistaken for a cluster-wide one.
    var telemetryScopeLabel: String {
        selectedNamespace == .allNamespaces ? "cluster-wide" : selectedNamespace.displayName
    }

    /// Starts the poll. Cancelled by `stopTelemetryUpdates()` when Overview goes away.
    func startTelemetryUpdates() {
        loadTelemetry()
        guard telemetryTimerTask == nil else { return }
        telemetryTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.telemetryRefreshInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                loadTelemetry(force: true)
            }
        }
    }

    func stopTelemetryUpdates() {
        telemetryTimerTask?.cancel()
        telemetryTimerTask = nil
        telemetryTask?.cancel()
        telemetryTask = nil
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

extension ClusterWorkspaceViewModel {
    /// Opens a section filtered to the rows a summary counted.
    ///
    /// Setting the section before the focus matters: `selectedSection`'s `didSet`
    /// clears any focus belonging to a different section, so assigning them the
    /// other way round would immediately discard the one just set.
    func focus(_ focus: ResourceFocus) {
        selectedSection = focus.section
        resourceFocus = focus
    }
}
