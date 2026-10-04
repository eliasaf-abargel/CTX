import CTXCore
import Foundation
import SwiftUI

@MainActor
final class ClusterWorkspaceViewModel: ObservableObject {
    @Published var selectedSection: ClusterWorkspaceSection = .overview {
        didSet {
            if let focus = resourceFocus, focus.section != selectedSection {
                resourceFocus = nil
            }
        }
    }
    @Published private(set) var overviewSummary: KubernetesOverviewSummary
    @Published private(set) var isRefreshingOverview = false
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var lastRefreshIssue: KubernetesCommandDiagnostic?
    @Published var selectedNamespace: KubernetesNamespaceSelection {
        didSet {
            handleNamespaceChange(previousNamespace: oldValue)
        }
    }
    @Published private(set) var namespaceOptions: [String] = [] {
        didSet { updateAvailableNamespaces() }
    }
    @Published private(set) var availableNamespaces: [String] = ["default"]
    @Published var diagnosticReport: KubernetesDiagnosticReport = .empty
    @Published private(set) var resourceLists: [String: KubernetesResourceList] = [:] {
        didSet {
            updateAvailableNamespaces()
            recalculateDiagnostics()
        }
    }

    private func updateAvailableNamespaces() {
        var set = Set<String>()
        set.formUnion(namespaceOptions)
        for list in resourceLists.values {
            for row in list.rows {
                if let ns = row.namespace, !ns.isEmpty, ns != "-" {
                    set.insert(ns)
                }
            }
        }
        if let gitOpsList {
            for row in gitOpsList.rows {
                if let ns = row.cells["Namespace"], !ns.isEmpty, ns != "-" {
                    set.insert(ns)
                }
                if let dest = row.cells["Destination"], !dest.isEmpty, dest != "-" {
                    set.insert(dest)
                }
            }
        }
        set.insert("default")
        let sorted = Array(set).sorted()
        if availableNamespaces != sorted {
            availableNamespaces = sorted
        }
    }
    /// Set only when a background refresh fails *and* good cached data already exists
    /// for that key — the good data stays in `resourceLists` and this surfaces the
    /// failure separately, so a flaky refresh never blanks a screen that already had
    /// something useful on it.
    @Published private(set) var refreshErrors: [String: KubernetesCommandDiagnostic] = [:]
    @Published private(set) var loadingResourceKinds: Set<KubernetesResourceKind> = []
    @Published private(set) var selectedResources: [String: KubernetesResourceRow] = [:]
    @Published var presentation: ClusterWorkspacePresentation?
    @Published var yamlResult: KubernetesYAMLResult?
    @Published var isLoadingYAML = false
    @Published var isEditingYAML = false
    @Published var editedYAML = ""
    @Published var isDryRunningYAML = false
    @Published var isApplyingYAML = false
    @Published var applyResult: KubernetesApplyResult?
    @Published var previousBaselineYAML: String?
    /// The exact edit that most recently passed a server dry-run, successfully.
    /// Apply is gated on `editedYAML` still matching this snapshot — any further
    /// edit after a dry-run must be re-validated before it can go live.
    @Published var dryRunValidatedYAML: String?
    let yamlApplier: any KubernetesYAMLApplying
    @Published var isPerformingLifecycleAction = false
    @Published var lifecycleActionResult: KubernetesLifecycleActionResult?
    /// The desired replica count a Deployment/StatefulSet had right before
    /// "Stop" scaled it to zero, keyed by the row's id — what "Start" scales
    /// back to. Lost on dismiss/selection change by design: it describes one
    /// specific stop, not a durable setting to restore across sessions.
    @Published var stoppedReplicaCounts: [String: Int] = [:]
    @Published var lifecyclePreflight: WorkloadLifecyclePreflight?
    let lifecycleService: any KubernetesWorkloadLifecycleManaging
    var rolloutWatchTask: Task<Void, Never>?
    @Published var diffResults: [String: ResourceDiffResult] = [:]
    @Published var diffingKinds: Set<KubernetesResourceKind> = []
    @Published var selectedLogPodID: String?
    @Published var logContainers: [String] = []
    @Published var selectedLogContainer: String?
    @Published var logsResult: KubernetesLogsResult?
    @Published var isLoadingLogs = false
    @Published var logTailLines = 100
    @Published var selectedPortForwardServiceID: String?
    @Published var portForwardLocalPort = "8080"
    @Published var portForwardRemotePort = "80"
    @Published var portForwardSessions: [KubernetesPortForwardSession] = []
    @Published var portForwardIssue: KubernetesCommandDiagnostic?
    @Published var isStartingPortForward = false
    @Published var topologyGraph = ClusterTopologyGraph(nodes: [], edges: [])
    @Published var topologyProjection: TopologyProjection?
    /// A build is running. Published because an empty graph means two opposite
    /// things — "still working" and "there is nothing here" — and the pane has
    /// to tell them apart.
    @Published var isBuildingTopology = false
    /// A build has finished, been abandoned, or been ruled out since the graph
    /// was last cleared. Until it has, an empty graph is only the absence of an
    /// answer.
    @Published var hasResolvedTopology = false
    /// Changes every time the map's scope does — today, on every namespace
    /// switch. The pane watches this instead of the selector text, because the
    /// reset it has to react to (drop the pending search, empty the field) also
    /// happens when the committed selector was already empty and therefore
    /// never changes.
    @Published var topologyScopeID = UUID()
    @Published var topologyExpansionState = TopologyExpansionState()
    @Published var topologySearchNodeIDs: Set<String> = []
    @Published var topologySelectorText = ""
    @Published var showIssuesOnly = false
    @Published var gitOpsResult: GitOpsReadResult?
    @Published var gitOpsList: KubernetesResourceList? {
        didSet { updateAvailableNamespaces() }
    }
    @Published var isLoadingGitOps = false
    @Published var helmResult: HelmReadResult?
    @Published var helmList: KubernetesResourceList?
    @Published var isLoadingHelm = false
    @Published var telemetry = ClusterTelemetryMetrics()
    /// An active "show me only the rows this summary counted" filter. Cleared by the
    /// chip above the table, and automatically whenever the scope changes underneath
    /// it — a namespace switch or a section change would otherwise leave a filter
    /// pinned to ids that are no longer on screen.
    @Published var resourceFocus: ResourceFocus?
    // Phase 6: Spotlight Command Palette & Quick Look Overlay
    @Published var isCommandPalettePresented: Bool = false
    @Published var quickLookResource: KubernetesResourceRow? = nil
    @Published var quickLookSection: ClusterWorkspaceSection? = nil

    var isQuickLookActive: Bool {
        quickLookResource != nil
    }

    var activeSelectedResource: KubernetesResourceRow? {
        selectedResource(for: selectedSection)
    }
    var telemetryTask: Task<Void, Never>?
    var telemetryTimerTask: Task<Void, Never>?
    var telemetryLoadedAt: Date?
    var gitOpsLoadedAt: Date?
    var helmLoadedAt: Date?
    var gitOpsTask: Task<Void, Never>?
    var helmTask: Task<Void, Never>?
    var topologyBuildTask: Task<Void, Never>?
    var topologyBuildGeneration = 0

    var onStatusCheckFailed: ((String, String) -> Void)?

    let context: KubernetesContextProfile
    private let healthService: any ClusterHealthChecking
    private let resourceReader: any KubernetesResourceReading
    let yamlReader: any KubernetesYAMLReading
    let logsReader: any KubernetesLogsReading
    let portForwardService: any KubernetesPortForwarding
    let auditLog: any AuditLogging
    let gitOpsReader: any KubernetesGitOpsReading
    let helmReader: any KubernetesHelmReading
    let specReader: any KubernetesWorkloadSpecReading
    let metricsReader: any KubernetesMetricsReading
    private let coordinator: ResourceRefreshCoordinator
    private var refreshTask: Task<Void, Never>?
    private var resourceTasks: [KubernetesResourceKind: Task<Void, Never>] = [:]
    var yamlTask: Task<Void, Never>?
    private var diffTasks: [KubernetesResourceKind: Task<Void, Never>] = [:]
    var logsTask: Task<Void, Never>?
    /// How long cached data is shown without a background revalidation. Below this,
    /// switching back to a screen is instant and silent. Above it, the stale entry is
    /// still shown immediately (nothing clears or blanks), but a fresh load kicks off
    /// behind it automatically — actual stale-while-revalidate, not just a same-session
    /// existence check that never re-validates for the lifetime of the window.
    let staleThreshold: TimeInterval = 30

    init(
        context: KubernetesContextProfile,
        healthService: any ClusterHealthChecking = ClusterHealthService(),
        resourceReader: any KubernetesResourceReading = KubernetesResourceReader(),
        yamlReader: any KubernetesYAMLReading = KubernetesYAMLReader(),
        yamlApplier: any KubernetesYAMLApplying = KubernetesYAMLApplier(),
        logsReader: any KubernetesLogsReading = KubernetesLogsReader(),
        portForwardService: any KubernetesPortForwarding = KubernetesPortForwardService(),
        auditLog: any AuditLogging = LocalAuditLogService(),
        gitOpsReader: any KubernetesGitOpsReading = KubernetesGitOpsReader(),
        helmReader: any KubernetesHelmReading = KubernetesHelmReader(),
        specReader: any KubernetesWorkloadSpecReading = KubernetesWorkloadSpecReader(),
        metricsReader: any KubernetesMetricsReading = KubernetesMetricsReader(),
        lifecycleService: any KubernetesWorkloadLifecycleManaging = KubernetesWorkloadLifecycleService()
    ) {
        self.gitOpsReader = gitOpsReader
        self.helmReader = helmReader
        self.specReader = specReader
        self.metricsReader = metricsReader
        self.lifecycleService = lifecycleService
        self.context = context
        self.healthService = healthService
        self.resourceReader = resourceReader
        self.yamlReader = yamlReader
        self.yamlApplier = yamlApplier
        self.logsReader = logsReader
        self.portForwardService = portForwardService
        self.auditLog = auditLog
        // The disk cache is opt-in on the coordinator (nil unless passed) so tests
        // stay fully in-memory; the real app wires a real one here so the very
        // first render after launch shows the last-known data instead of a
        // skeleton, with a background refresh right behind it.
        self.coordinator = ResourceRefreshCoordinator(reader: resourceReader, staleThreshold: 30, diskCache: SQLiteResourceCache(), backgroundGate: KubectlConcurrencyGate())
        self.selectedNamespace = Self.loadNamespaceSelection(context: context)
        self.overviewSummary = .notChecked(namespace: context.namespace.isEmpty ? "default" : context.namespace)
        CTXPerfLog.log(step: "workspace_open", contextID: context.id, namespace: "cluster", kind: "workspace", cache: .none, durationMs: 0, outcome: .success)
    }

    /// Namespace-scoped resource kinds background-fetched right after a namespace
    /// switch. Cluster-scoped kinds (Nodes, Namespaces) are deliberately
    /// excluded — they don't change with namespace, so reloading them here would be
    /// a needless live kubectl call on every switch.
    private static let namespaceScopedPrefetchKinds: [KubernetesResourceKind] = [
        .pods, .services, .workloads, .ingress, .hpa, .pvc, .events
    ]

    deinit {
        refreshTask?.cancel()
        gitOpsTask?.cancel()
        helmTask?.cancel()
        telemetryTask?.cancel()
        telemetryTimerTask?.cancel()
        topologyBuildTask?.cancel()
        resourceTasks.values.forEach { $0.cancel() }
        yamlTask?.cancel()
        diffTasks.values.forEach { $0.cancel() }
        logsTask?.cancel()
        rolloutWatchTask?.cancel()
        Task { [portForwardService] in
            await portForwardService.stopAll()
        }
    }

    var title: String {
        context.contextName
    }

    var clusterName: String {
        context.clusterName.isEmpty ? "Unknown cluster" : context.clusterName
    }

    var namespace: String {
        selectedNamespace.displayName
    }

    var userName: String {
        context.userName.isEmpty ? "Unknown user" : context.userName
    }

    var displayUserName: String {
        let name = userName
        if name.hasPrefix("arn:aws:") {
            if let last = name.split(separator: "/").last {
                return String(last)
            }
        }
        return name
    }

    var isProduction: Bool {
        context.environmentType == .production
    }

    /// Called both on first appearance and every time the Overview section is
    /// selected again. Without the staleness check this used to only ever run once
    /// per window — switching away and back showed the same health/RBAC snapshot
    /// from whenever the window first opened, with no automatic re-check possible.
    func refreshOverviewIfNeeded() async {
        guard !isRefreshingOverview else { return }
        if let lastRefreshed, Date().timeIntervalSince(lastRefreshed) <= staleThreshold {
            return
        }
        await refreshOverviewNow(loadNamespacesOnSuccess: true, namespaceBypassCache: false)
    }

    /// Called once when the workspace window first opens (not on every return to
    /// Overview — that's `refreshOverviewIfNeeded()`). Schedules a background load
    /// for every resource kind except Namespaces (already started by
    /// `refreshOverviewIfNeeded()` — including it here too would just cancel and
    /// restart that same in-flight fetch) so navigating to any screen right after
    /// opening already has warm data instead of a skeleton. Each kind still goes
    /// through `loadResource`'s own cache-freshness guard and the coordinator's
    /// dedup, so this can never produce a duplicate request against a kind the
    /// user has already triggered some other way.
    func prefetchWorkspaceResources() {
        guard overviewSummary.apiStatus == .reachable else { return }
        // Prefetch only the resource kinds needed for the Overview screen or common navigation
        let prefetchKinds: [KubernetesResourceKind] = [.nodes, .pods, .services, .workloads, .ingress, .events]
        for kind in prefetchKinds {
            loadResource(kind: kind, bypassCache: false, priority: .background)
        }
    }

    func refreshOverview(loadNamespacesOnSuccess: Bool = false, namespaceBypassCache: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refreshOverviewNow(loadNamespacesOnSuccess: loadNamespacesOnSuccess, namespaceBypassCache: namespaceBypassCache)
        }
    }

    private func refreshOverviewNow(loadNamespacesOnSuccess: Bool, namespaceBypassCache: Bool) async {
        isRefreshingOverview = true
        defer { isRefreshingOverview = false }
        let summary = await healthService.overview(for: context)
        guard !Task.isCancelled else { return }
        lastRefreshIssue = summary.primaryFailure
        if summary.hasLoadedData || lastRefreshed == nil {
            overviewSummary.apiStatus = summary.apiStatus
            overviewSummary.rbac = summary.rbac
            overviewSummary.diagnostics = summary.diagnostics
        }
        if summary.hasLoadedData {
            lastRefreshed = Date()
        }
        if loadNamespacesOnSuccess, summary.apiStatus == .reachable {
            loadNamespaces(bypassCache: namespaceBypassCache)
        } else if summary.apiStatus != .reachable, let failure = summary.primaryFailure {
            onStatusCheckFailed?(context.contextName, failure.stderrSummary)
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        gitOpsTask?.cancel()
        helmTask?.cancel()
        topologyBuildTask?.cancel()
        isBuildingTopology = false
        // Stopping is an answer too: nothing further is coming, so the pane
        // must not sit on a skeleton waiting for it.
        hasResolvedTopology = true
        isLoadingGitOps = false
        isLoadingHelm = false
        resourceTasks.values.forEach { $0.cancel() }
        yamlTask?.cancel()
        diffTasks.values.forEach { $0.cancel() }
        logsTask?.cancel()
        rolloutWatchTask?.cancel()
        isRefreshingOverview = false
        loadingResourceKinds.removeAll()
        isLoadingYAML = false
        presentation = nil
        previousBaselineYAML = nil
        diffingKinds.removeAll()
        isLoadingLogs = false
    }



    func runDiff(kind: KubernetesResourceKind) {
        let namespace = scope(for: kind)
        let key = resourceKey(kind: kind, namespace: namespace)
        let before = resourceLists[key]
        diffTasks[kind]?.cancel()
        diffingKinds.insert(kind)
        diffTasks[kind] = Task { [weak self] in
            guard let self else { return }
            let after = await coordinator.fetch(contextID: context.id, context: context, namespace: namespace, kind: kind, bypassCache: true).list
            guard !Task.isCancelled else { return }
            if after.status == .reachable {
                resourceLists[key] = after
                refreshErrors[key] = nil
                diffResults[key] = ResourceDiffResult.compare(before: before, after: after)
            }
            diffingKinds.remove(kind)
            diffTasks[kind] = nil
        }
    }

    func diffResult(for kind: KubernetesResourceKind) -> ResourceDiffResult? {
        diffResults[resourceKey(kind: kind)]
    }

    func refreshCurrentScreen() {
        CTXPerfLog.log(step: "retry", contextID: context.id, namespace: namespace, kind: selectedSection.rawValue.lowercased(), cache: .none, durationMs: 0, outcome: .success)
        if presentation?.tab == .yaml {
            loadYAMLForFocusedResource()
        } else if presentation?.tab == .logs {
            reloadLogs()
        } else if selectedSection == .overview {
            refreshOverview(loadNamespacesOnSuccess: true, namespaceBypassCache: true)
        } else if selectedSection == .issues {
            loadResource(kind: .pods, bypassCache: true)
            loadResource(kind: .nodes, bypassCache: true)
            loadResource(kind: .workloads, bypassCache: true)
        } else if selectedSection == .logs {
            if selectedLogPodID != nil {
                reloadLogs()
            } else {
                loadPodsForLogs(bypassCache: true)
            }
        } else {
            loadSelectedSection(bypassCache: true)
        }
    }

    func loadSelectedSection(bypassCache: Bool = false) {
        switch selectedSection {
        case .helm:
            loadHelm(bypassCache: bypassCache)
        case .gitops:
            loadGitOps(bypassCache: bypassCache)
        default:
            guard let kind = selectedSection.resourceKind else { return }
            loadResource(kind: kind, bypassCache: bypassCache)
        }
    }

    func loadNamespaces(bypassCache: Bool) {
        loadResource(kind: .namespaces, bypassCache: bypassCache) { [weak self] list in
            self?.namespaceOptions = list.rows.compactMap { $0.cells["Name"] }.sorted()
        }
    }

    func loadPodsForLogs(bypassCache: Bool = false) {
        loadResource(kind: .pods, bypassCache: bypassCache) { [weak self] list in
            guard let self, selectedLogPodID == nil, list.rows.count == 1, let onlyPod = list.rows.first else { return }
            selectLogPod(onlyPod)
        }
    }

    func setNamespace(_ selection: KubernetesNamespaceSelection) {
        selectedNamespace = selection
    }

    /// GitOps and Helm are not plain `kubectl get` kinds — they come from custom
    /// resources and (for Helm) from the `helm` CLI, so they are loaded by their own
    /// readers and cached here as finished lists. Both report only what the cluster
    /// actually says — nothing on these screens is synthesised from other rows.
    func resourceList(for section: ClusterWorkspaceSection) -> KubernetesResourceList? {
        switch section {
        case .gitops:
            guard let list = gitOpsList else { return nil }
            guard selectedNamespace != .allNamespaces else { return list }
            let targetNS = selectedNamespace.displayName.lowercased()
            let filteredRows = list.rows.filter { row in
                let ns = (row.cells["Namespace"] ?? "").lowercased()
                let dest = (row.cells["Destination"] ?? "").lowercased()
                let ctrl = (row.cells["Controller NS"] ?? "").lowercased()
                let name = row.name.lowercased()
                if ns == targetNS || dest == targetNS || ctrl == targetNS || name == targetNS {
                    return true
                }
                if targetNS.count >= 4 && (name.contains(targetNS) || targetNS.contains(name)) {
                    return true
                }
                return false
            }
            return KubernetesResourceList(
                kind: list.kind,
                columns: list.columns,
                rows: filteredRows,
                status: list.status,
                diagnostic: list.diagnostic,
                loadedAt: list.loadedAt
            )
        case .helm: return helmList
        case .pods:
            guard var list = resourceLists[resourceKey(kind: .pods)] else { return nil }
            // The CPU and Memory columns carry declared *requests*, so a pod that
            // declares none showed nothing at all. Live usage is merged in where the
            // metrics API reports it, which is what makes these columns a monitoring
            // view rather than a copy of the manifest.
            guard !telemetry.usageByPod.isEmpty else { return list }
            list.rows = list.rows.map { row in
                guard let usage = telemetry.usageByPod[row.id] else { return row }
                var cells = row.cells
                cells["CPU"] = usage.cpu
                cells["Memory"] = usage.memory
                return KubernetesResourceRow(id: row.id, cells: cells, warning: row.warning, sortValue: row.sortValue, ref: row.ref)
            }
            return list
        case .nodes:
            guard var list = resourceLists[resourceKey(kind: .nodes)] else { return nil }
            // Capacity is identical on every node of a managed node group, so a table
            // of capacities looks static and says nothing about what is happening.
            // Live usage from `kubectl top` is merged in where it exists.
            guard !telemetry.utilizationByNode.isEmpty else { return list }
            list.rows = list.rows.map { row in
                guard let usage = telemetry.utilizationByNode[row.name] else { return row }
                var cells = row.cells
                if let percent = usage.cpuPercent {
                    cells["CPU Used"] = String(format: "%.0f%%", percent)
                }
                if let percent = usage.memoryPercent {
                    cells["Memory Used"] = String(format: "%.0f%%", percent)
                }
                return KubernetesResourceRow(
                    id: row.id,
                    cells: cells,
                    warning: row.warning || (usage.cpuPercent ?? 0) >= 90 || (usage.memoryPercent ?? 0) >= 90,
                    sortValue: row.sortValue,
                    ref: row.ref
                )
            }
            return list
        default:
            guard let kind = section.resourceKind else { return nil }
            return resourceLists[resourceKey(kind: kind)]
        }
    }

    func isLoading(section: ClusterWorkspaceSection) -> Bool {
        switch section {
        case .gitops: return isLoadingGitOps
        case .helm: return isLoadingHelm
        default:
            guard let kind = section.resourceKind else { return false }
            return loadingResourceKinds.contains(kind)
        }
    }

    var isRefreshingCurrentScreen: Bool {
        if presentation?.tab == .yaml {
            return isLoadingYAML
        }
        if presentation?.tab == .logs {
            return isLoadingLogs
        }
        if selectedSection == .overview {
            return isRefreshingOverview
        }
        if selectedSection == .issues {
            return isLoading(section: .pods) || isLoading(section: .nodes) || isLoading(section: .workloads)
        }
        if selectedSection == .logs {
            return selectedLogPodID != nil ? isLoadingLogs : isLoading(section: .pods)
        }
        return isLoading(section: selectedSection)
    }

    func selectedResource(for section: ClusterWorkspaceSection) -> KubernetesResourceRow? {
        let key = section.rawValue
        return selectedResources[key]
    }

    func selectResource(_ row: KubernetesResourceRow, in section: ClusterWorkspaceSection) {
        let kind = section.resourceKind ?? .workloads
        let key = section.rawValue
        selectedResources[key] = row
        yamlResult = nil
        // A staged rollback baseline belongs to whichever resource was just
        // edited — carrying it over to a newly selected row would let
        // "Rollback" apply that other resource's manifest here instead.
        previousBaselineYAML = nil
        // Same reasoning for a lifecycle result banner: "Restart triggered"
        // must not still be showing once a different row is selected.
        lifecycleActionResult = nil
        lifecyclePreflight = nil
        rolloutWatchTask?.cancel()
        presentation = ClusterWorkspacePresentation(
            selection: ClusterWorkspaceResourceSelection(section: section, kind: kind, row: row),
            tab: .overview
        )
    }

    func loadedEventTarget(for row: KubernetesResourceRow) -> ClusterWorkspaceResourceSelection? {
        guard let target = KubernetesEventObjectTarget(object: row.cells["Object"] ?? "", namespace: row.namespace),
              let section = ClusterWorkspaceSection.section(for: target.kind)
        else { return nil }
        let match = resourceLists.values
            .filter { $0.kind == target.kind }
            .flatMap(\.rows)
            .first { $0.name == target.name && (target.namespace == nil || $0.namespace == target.namespace) }
        return match.map { ClusterWorkspaceResourceSelection(section: section, kind: target.kind, row: $0) }
    }

    /// Dismisses the inspector (whichever tab is active) and clears the row
    /// selection behind it. This is the *only* path that closes a presentation —
    /// there is no separate boolean that can independently re-open it, so "click
    /// outside" / Escape / "Done" all funnel through here and stay closed.
    func dismissPresentation() {
        if let kind = presentation?.selection.kind {
            selectedResources.removeValue(forKey: resourceKey(kind: kind))
        }
        presentation = nil
        yamlTask?.cancel()
        yamlResult = nil
        isLoadingYAML = false
        isEditingYAML = false
        applyResult = nil
        isDryRunningYAML = false
        isApplyingYAML = false
        dryRunValidatedYAML = nil
        previousBaselineYAML = nil
        lifecycleActionResult = nil
        lifecyclePreflight = nil
        isPerformingLifecycleAction = false
        rolloutWatchTask?.cancel()
        // The inspector's Logs tab shares this task with the standalone Logs
        // screen; closing the inspector must not leave a fetch running for a pod
        // that's no longer on screen anywhere.
        logsTask?.cancel()
        isLoadingLogs = false
    }

    /// Switches the active inspector tab for the current resource — mutating the
    /// existing `presentation` value in place, not dismissing and re-presenting a
    /// different one. Lazily kicks off the tab's own load the first time it's shown.
    func openInspector(for row: KubernetesResourceRow, in section: ClusterWorkspaceSection, tab: CTXInspectorTab = .overview) {
        selectResource(row, in: section)
        selectInspectorTab(tab)
    }

    /// Deep-links directly to a specific resource, switching namespace if necessary,
    /// selecting the appropriate sidebar section, loading data, and opening the inspector on the given tab.
    @MainActor
    public func navigateToResource(
        kind: KubernetesResourceKind,
        name: String,
        namespace: String?,
        tab: CTXInspectorTab = .diagnostics
    ) async {
        if let namespace, !namespace.isEmpty, namespace != "-" {
            if namespace == "default" {
                selectedNamespace = .defaultNamespace
            } else {
                selectedNamespace = .namespace(namespace)
            }
        }

        if let section = ClusterWorkspaceSection.section(for: kind) {
            selectedSection = section
        }

        loadResource(kind: kind, bypassCache: false)

        let key = resourceKey(kind: kind, namespace: scope(for: kind))
        var row = resourceLists[key]?.rows.first(where: { $0.name == name })

        if row == nil {
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                if let found = resourceLists[key]?.rows.first(where: { $0.name == name }) {
                    row = found
                    break
                }
            }
        }

        if let targetRow = row, let section = ClusterWorkspaceSection.section(for: kind) {
            selectResource(targetRow, in: section)
            selectInspectorTab(tab)
        }
    }

    func toggleQuickLook(for row: KubernetesResourceRow? = nil, in section: ClusterWorkspaceSection? = nil) {
        if isQuickLookActive {
            dismissQuickLook()
        } else if let targetRow = row ?? activeSelectedResource {
            let targetSection = section ?? selectedSection
            quickLookResource = targetRow
            quickLookSection = targetSection
        }
    }

    func dismissQuickLook() {
        quickLookResource = nil
        quickLookSection = nil
    }

    func selectInspectorTab(_ tab: CTXInspectorTab) {
        guard let selection = presentation?.selection else { return }
        presentation?.tab = tab
        switch tab {
        case .overview, .spec, .diagnostics:
            break
        case .yaml:
            if yamlResult == nil { loadYAML(for: selection) }
        case .logs:
            if selection.kind == .pods, selectedLogPodID != selection.row.id {
                selectLogPod(selection.row)
            }
        }
    }

    func loadYAMLForFocusedResource() {
        guard let selection = presentation?.selection, presentation?.tab == .yaml else { return }
        loadYAML(for: selection)
    }

    func loadResource(kind: KubernetesResourceKind, bypassCache: Bool, priority: FetchPriority = .active, completion: ((KubernetesResourceList) -> Void)? = nil) {
        let namespace = scope(for: kind)
        let key = resourceKey(kind: kind, namespace: namespace)
        let cached = resourceLists[key]
        let isStale = cached.map { Date().timeIntervalSince($0.loadedAt) > staleThreshold } ?? false
        guard bypassCache || cached == nil || isStale else {
            return
        }
        // Already fetching this exact kind (e.g. workspace-open prefetch got there
        // a moment before the user clicked the same screen) — the in-flight task
        // will populate this same key when it resolves, so cancelling and
        // restarting it here would just be wasted work. Only short-circuits calls
        // with no completion closure — `loadNamespaces`/`loadPodsForLogs` depend on
        // their own completion firing, so they keep the original restart behavior.
        if !bypassCache, completion == nil, resourceTasks[kind] != nil {
            return
        }
        let started = Date()
        resourceTasks[kind]?.cancel()
        resourceTasks[kind] = Task { [weak self] in
            guard let self else { return }
            
            // 1. Try to load from SQLite disk cache first if not in memory (cold start/new namespace)
            if self.resourceLists[key] == nil {
                if let diskCached = await coordinator.loadDiskCachedIfNeeded(contextID: context.id, namespace: namespace, kind: kind) {
                    guard !Task.isCancelled else { return }
                    if self.resourceLists[key] == nil {
                        self.resourceLists[key] = diskCached
                        self.updateOverview(from: diskCached)
                    }
                }
            }
            
            // 2. Set loading state. If data is now in memory, UI shows list with inline spinner. If not, UI shows skeleton.
            self.loadingResourceKinds.insert(kind)
            
            // 3. Fetch fresh data from Kubernetes
            let outcome = await coordinator.fetch(contextID: context.id, context: context, namespace: namespace, kind: kind, bypassCache: bypassCache || isStale, priority: priority)
            
            guard !Task.isCancelled else { return }
            let list = outcome.list
            if list.status == .reachable || resourceLists[key] == nil {
                resourceLists[key] = list
                refreshErrors[key] = nil
                if kind == .namespaces {
                    namespaceOptions = list.rows.compactMap { $0.cells["Name"] }.sorted()
                }
            } else {
                refreshErrors[key] = list.diagnostic
            }
            if list.status == .reachable {
                reconcileSelection(kind: kind, list: list)
            }
            updateOverview(from: list)
            loadingResourceKinds.remove(kind)
            resourceTasks[kind] = nil
            logScreenLoad(kind: kind, namespace: namespace, cacheState: outcome.cacheStateBeforeFetch, list: list, started: started)
            if kind == .services || kind == .workloads || kind == .pods ||
                kind == .ingress || kind == .hpa || kind == .pvc {
                self.recalculateTopology()
            }
            completion?(list)
        }
    }

    private func logScreenLoad(kind: KubernetesResourceKind, namespace: KubernetesNamespaceSelection, cacheState: ResourceRefreshCoordinator.CacheState, list: KubernetesResourceList, started: Date) {
        let cache: CTXPerfLog.Cache = switch cacheState {
        case .hit: .hit
        case .stale: .stale
        case .miss: .miss
        }
        let outcome: CTXPerfLog.Outcome = list.status == .reachable ? .success : (list.diagnostic?.category == .timeout ? .timeout : .error)
        CTXPerfLog.log(
            step: "screen_open",
            contextID: context.id,
            namespace: kind.isClusterScoped ? "cluster" : namespace.storageValue,
            kind: kind.rawValue,
            cache: cache,
            durationMs: max(0, Int(Date().timeIntervalSince(started) * 1000)),
            outcome: outcome
        )
    }

    /// Recorded when a *background* refresh failed while good cached data stayed
    /// visible — distinct from `resourceList(for:)`'s own `status`, which only
    /// reflects a failure when there was never any good data to preserve.
    func refreshError(for section: ClusterWorkspaceSection) -> KubernetesCommandDiagnostic? {
        guard let kind = section.resourceKind else { return nil }
        return refreshErrors[resourceKey(kind: kind)]
    }

    func scope(for kind: KubernetesResourceKind) -> KubernetesNamespaceSelection {
        kind.isClusterScoped ? .allNamespaces : selectedNamespace
    }

    func resourceKey(kind: KubernetesResourceKind) -> String {
        resourceKey(kind: kind, namespace: scope(for: kind))
    }

    func resourceKey(kind: KubernetesResourceKind, namespace: KubernetesNamespaceSelection) -> String {
        "\(kind.rawValue)|\(namespace.storageValue)"
    }

    /// A failed refresh must never blank an Overview card that already has a real
    /// number on it — same "keep the last known snapshot" rule already applied to
    /// resource-list screens (`refreshErrors`), just applied here too. Only a
    /// *first-ever* failure (no prior good data to preserve) shows the empty/failed
    /// state; every failure after that keeps the last known count and only updates
    /// the status, so the card can still say "Timeout" without losing the number.
    private func updateOverview(from list: KubernetesResourceList) {
        switch list.kind {
        case .namespaces:
            if list.status == .reachable {
                overviewSummary.namespaces = KubernetesNamespacesSummary(count: list.rows.count, activeNamespace: namespace, status: .reachable)
            } else if overviewSummary.namespaces.count == nil {
                overviewSummary.namespaces = KubernetesNamespacesSummary(count: nil, activeNamespace: namespace, status: list.status)
            } else {
                overviewSummary.namespaces.status = list.status
            }
        case .nodes:
            if list.status == .reachable {
                let ready = list.rows.filter { $0.cells["Ready"] == "Ready" }.count
                overviewSummary.nodes = KubernetesNodesSummary(total: list.rows.count, ready: ready, notReady: list.rows.count - ready, status: .reachable)
            } else if overviewSummary.nodes.total == nil {
                overviewSummary.nodes = KubernetesNodesSummary(total: nil, ready: nil, notReady: nil, status: list.status)
            } else {
                overviewSummary.nodes.status = list.status
            }
        case .pods:
            if list.status == .reachable {
                overviewSummary.pods = KubernetesPodsSummary.summarize(rows: list.rows, status: .reachable)
            } else if overviewSummary.pods.total == nil {
                overviewSummary.pods = KubernetesPodsSummary(total: nil, running: 0, pending: 0, failed: 0, crashLoopBackOff: 0, failing: 0, status: list.status)
            } else {
                overviewSummary.pods.status = list.status
            }
        case .events:
            if list.status == .reachable {
                overviewSummary.events = KubernetesEventsSummary.summarize(rows: list.rows, status: .reachable)
            } else if overviewSummary.events.warningCount == nil {
                overviewSummary.events = KubernetesEventsSummary(warningCount: nil, status: list.status)
            } else {
                overviewSummary.events.status = list.status
            }
        case .cronJobs:
            break
        case .workloads:
            if list.status == .reachable {
                overviewSummary.workloads = KubernetesWorkloadsSummary.summarize(rows: list.rows, status: .reachable)
            } else if overviewSummary.workloads.total == nil {
                overviewSummary.workloads = KubernetesWorkloadsSummary(total: nil, healthy: 0, unhealthy: 0, status: list.status)
            } else {
                overviewSummary.workloads.status = list.status
            }
        case .services:
            if list.status == .reachable {
                overviewSummary.services = KubernetesServicesSummary.summarize(rows: list.rows, status: .reachable)
            } else if overviewSummary.services.total == nil {
                overviewSummary.services = KubernetesServicesSummary(total: nil, exposed: 0, status: list.status)
            } else {
                overviewSummary.services.status = list.status
            }
        case .ingress:
            if list.status == .reachable {
                overviewSummary.ingress = KubernetesIngressSummary.summarize(rows: list.rows, status: .reachable)
            } else if overviewSummary.ingress.total == nil {
                overviewSummary.ingress = KubernetesIngressSummary(total: nil, routed: 0, tls: 0, status: list.status)
            } else {
                overviewSummary.ingress.status = list.status
            }
        case .configMaps, .secretMetadata, .hpa, .pvc:
            break
        }
    }

    private func handleNamespaceChange(previousNamespace: KubernetesNamespaceSelection) {
        let started = Date()
        persistNamespaceSelection()
        // Immediately: close the inspector and drop the selection tied to the
        // namespace that just went away.
        selectedResources.removeAll()
        resourceFocus = nil
        // Pod-scoped telemetry belongs to the namespace it was read for. Without
        // this the panel kept reporting the previous scope — switching to a
        // six-pod namespace still showed "80 scheduled" and the cluster-wide
        // at-risk count.
        telemetryTask?.cancel()
        telemetryTask = nil
        telemetryLoadedAt = nil
        presentation = nil
        yamlResult = nil
        yamlTask?.cancel()
        isLoadingYAML = false
        previousBaselineYAML = nil
        logsTask?.cancel()
        selectedLogPodID = nil
        selectedLogContainer = nil
        logContainers = []
        logsResult = nil
        isLoadingLogs = false
        overviewSummary.namespaces.activeNamespace = namespace
        overviewSummary.pods = KubernetesPodsSummary(total: nil, running: 0, pending: 0, failed: 0, crashLoopBackOff: 0, failing: 0, status: .notChecked)
        overviewSummary.workloads = KubernetesWorkloadsSummary(total: nil, healthy: 0, unhealthy: 0, status: .notChecked)
        overviewSummary.services = KubernetesServicesSummary(total: nil, exposed: 0, status: .notChecked)
        overviewSummary.ingress = KubernetesIngressSummary(total: nil, routed: 0, tls: 0, status: .notChecked)
        overviewSummary.events = KubernetesEventsSummary(warningCount: nil, status: .notChecked)
        resetTopology()
        hydrateOverviewFromCachedNamespace()

        // Cancel in-flight namespace-scoped work for the *old* namespace so a slow
        // response can't land under the new namespace's data. This also terminates
        // the underlying kubectl process via the coordinator, not just discards the
        // eventual result.
        for kind in Self.namespaceScopedPrefetchKinds {
            resourceTasks[kind]?.cancel()
            resourceTasks[kind] = nil
            loadingResourceKinds.remove(kind)
        }
        Task { [coordinator, contextID = context.id] in
            await coordinator.cancel(contextID: contextID, namespace: previousNamespace)
        }

        // GitOps and Helm are namespace-scoped reads that live outside the
        // coordinator, so their cached lists have to be invalidated here too —
        // otherwise the new namespace would show the previous one's applications.
        // GitOps is cluster-wide, so a namespace switch cannot change its answer —
        // it is deliberately left alone here rather than cancelled and refetched.
        helmTask?.cancel()
        helmTask = nil
        helmLoadedAt = nil
        isLoadingHelm = false
        if selectedSection == .helm { loadHelm() }
        if selectedSection == .gitops {
            selectedResources.removeValue(forKey: ClusterWorkspaceSection.gitops.rawValue)
        }

        // Cached data for the new namespace (if any) is already what `resourceList(for:)`
        // returns, since cache keys are namespace-scoped — no separate "render cached
        // data" step is needed here. What's left: revalidate the currently-visible
        // section if it's namespace-scoped, then background-prefetch the rest.
        if let kind = selectedSection.resourceKind, !kind.isClusterScoped {
            loadResource(kind: kind, bypassCache: false)
        }
        for kind in Self.namespaceScopedPrefetchKinds where kind != selectedSection.resourceKind {
            loadResource(kind: kind, bypassCache: false, priority: .background)
        }

        CTXPerfLog.log(step: "namespace_switch", contextID: context.id, namespace: selectedNamespace.storageValue, kind: "workspace", cache: .none, durationMs: max(0, Int(Date().timeIntervalSince(started) * 1000)), outcome: .success)
        recalculateTopology()
    }

    private func hydrateOverviewFromCachedNamespace() {
        for kind in Self.namespaceScopedPrefetchKinds {
            if let cached = resourceLists[resourceKey(kind: kind, namespace: selectedNamespace)] {
                updateOverview(from: cached)
            }
        }
    }

    private func reconcileSelection(kind: KubernetesResourceKind, list: KubernetesResourceList) {
        let key = resourceKey(kind: kind)
        guard let selected = selectedResources[key] else { return }
        if list.rows.contains(where: { $0.id == selected.id }) == false {
            selectedResources.removeValue(forKey: key)
            if presentation?.selection.kind == kind {
                presentation = nil
                yamlResult = nil
            }
        }
    }



    private func persistNamespaceSelection() {
        UserDefaults.standard.set(selectedNamespace.storageValue, forKey: namespaceSelectionKey)
    }

    private var namespaceSelectionKey: String {
        "clusterWorkspace.namespace.\(context.id)"
    }

    private static func loadNamespaceSelection(context: KubernetesContextProfile) -> KubernetesNamespaceSelection {
        let key = "clusterWorkspace.namespace.\(context.id)"
        guard let value = UserDefaults.standard.string(forKey: key), !value.isEmpty else {
            let namespace = context.namespace.isEmpty ? "default" : context.namespace
            return namespace == "default" ? .defaultNamespace : .namespace(namespace)
        }
        if value == "__all__" { return .allNamespaces }
        if value == "default" { return .defaultNamespace }
        return .namespace(value)
    }

    private var terminatedSessionIDs = Set<UUID>()

    func handlePortForwardTerminated(sessionID: UUID) {
        if let index = portForwardSessions.firstIndex(where: { $0.id == sessionID }) {
            let session = portForwardSessions[index]
            portForwardSessions.remove(at: index)
            try? auditLog.record(AuditEvent(type: .portForwardStopped, contextName: context.contextName, message: "service/\(session.targetName) \(session.localPort):\(session.remotePort)"))
        } else {
            terminatedSessionIDs.insert(sessionID)
        }
    }

    func checkAndInsertPortForwardSession(_ session: KubernetesPortForwardSession, refName: String) -> Bool {
        if terminatedSessionIDs.contains(session.id) {
            terminatedSessionIDs.remove(session.id)
            return false
        } else {
            portForwardSessions.insert(session, at: 0)
            try? auditLog.record(AuditEvent(type: .portForwardStarted, contextName: context.contextName, message: "service/\(refName) \(session.localPort):\(session.remotePort)"))
            return true
        }
    }
}
