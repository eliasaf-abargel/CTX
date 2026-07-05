import CTXCore
import Foundation
import SwiftUI

@MainActor
final class ClusterWorkspaceViewModel: ObservableObject {
    @Published var selectedSection: ClusterWorkspaceSection = .overview
    @Published private(set) var overviewSummary: KubernetesOverviewSummary
    @Published private(set) var isRefreshingOverview = false
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var lastRefreshIssue: KubernetesCommandDiagnostic?
    @Published var selectedNamespace: KubernetesNamespaceSelection {
        didSet {
            handleNamespaceChange(previousNamespace: oldValue)
        }
    }
    @Published private(set) var namespaceOptions: [String] = []
    @Published private(set) var resourceLists: [String: KubernetesResourceList] = [:]
    /// Set only when a background refresh fails *and* good cached data already exists
    /// for that key — the good data stays in `resourceLists` and this surfaces the
    /// failure separately, so a flaky refresh never blanks a screen that already had
    /// something useful on it.
    @Published private(set) var refreshErrors: [String: KubernetesCommandDiagnostic] = [:]
    @Published private(set) var loadingResourceKinds: Set<KubernetesResourceKind> = []
    @Published private(set) var selectedResources: [String: KubernetesResourceRow] = [:]
    @Published var presentation: ClusterWorkspacePresentation?
    @Published private(set) var yamlResult: KubernetesYAMLResult?
    @Published private(set) var isLoadingYAML = false
    @Published private(set) var diffResults: [String: ResourceDiffResult] = [:]
    @Published private(set) var diffingKinds: Set<KubernetesResourceKind> = []
    @Published var selectedLogPodID: String?
    @Published private(set) var logContainers: [String] = []
    @Published var selectedLogContainer: String?
    @Published private(set) var logsResult: KubernetesLogsResult?
    @Published private(set) var isLoadingLogs = false
    @Published private(set) var logTailLines = 100

    let context: KubernetesContextProfile
    private let healthService: any ClusterHealthChecking
    private let resourceReader: any KubernetesResourceReading
    private let yamlReader: any KubernetesYAMLReading
    private let logsReader: any KubernetesLogsReading
    private let coordinator: ResourceRefreshCoordinator
    private var refreshTask: Task<Void, Never>?
    private var resourceTasks: [KubernetesResourceKind: Task<Void, Never>] = [:]
    private var yamlTask: Task<Void, Never>?
    private var diffTasks: [KubernetesResourceKind: Task<Void, Never>] = [:]
    private var logsTask: Task<Void, Never>?
    /// How long cached data is shown without a background revalidation. Below this,
    /// switching back to a screen is instant and silent. Above it, the stale entry is
    /// still shown immediately (nothing clears or blanks), but a fresh load kicks off
    /// behind it automatically — actual stale-while-revalidate, not just a same-session
    /// existence check that never re-validates for the lifetime of the window.
    private let staleThreshold: TimeInterval = 30

    init(
        context: KubernetesContextProfile,
        healthService: any ClusterHealthChecking = ClusterHealthService(),
        resourceReader: any KubernetesResourceReading = KubernetesResourceReader(),
        yamlReader: any KubernetesYAMLReading = KubernetesYAMLReader(),
        logsReader: any KubernetesLogsReading = KubernetesLogsReader()
    ) {
        self.context = context
        self.healthService = healthService
        self.resourceReader = resourceReader
        self.yamlReader = yamlReader
        self.logsReader = logsReader
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
    /// switch (item 6): cluster-scoped kinds (Nodes, Namespaces) are deliberately
    /// excluded — they don't change with namespace, so reloading them here would be
    /// a needless live kubectl call on every switch.
    private static let namespaceScopedPrefetchKinds: [KubernetesResourceKind] = [
        .pods, .services, .workloads, .ingress, .events
    ]

    deinit {
        refreshTask?.cancel()
        resourceTasks.values.forEach { $0.cancel() }
        yamlTask?.cancel()
        diffTasks.values.forEach { $0.cancel() }
        logsTask?.cancel()
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
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        resourceTasks.values.forEach { $0.cancel() }
        yamlTask?.cancel()
        diffTasks.values.forEach { $0.cancel() }
        logsTask?.cancel()
        isRefreshingOverview = false
        loadingResourceKinds.removeAll()
        isLoadingYAML = false
        presentation = nil
        diffingKinds.removeAll()
        isLoadingLogs = false
    }

    var selectedLogPodRow: KubernetesResourceRow? {
        guard let selectedLogPodID else { return nil }
        return resourceList(for: .pods)?.rows.first { $0.id == selectedLogPodID }
    }

    func selectLogPod(_ row: KubernetesResourceRow) {
        let ref = row.reference(kind: .pods, context: context)
        guard let namespace = ref.namespace else { return }
        selectedLogPodID = row.id
        selectedLogContainer = nil
        logContainers = []
        logsResult = nil
        logsTask?.cancel()
        logsTask = Task { [weak self] in
            guard let self else { return }
            let containers = await logsReader.containers(namespace: namespace, pod: ref.name, context: context)
            guard !Task.isCancelled else { return }
            logContainers = containers
            selectedLogContainer = containers.first
            await loadLogs(namespace: namespace, pod: ref.name, container: containers.first)
        }
    }

    func selectLogContainer(_ container: String) {
        selectedLogContainer = container
        reloadLogs()
    }

    func setLogTailLines(_ lines: Int) {
        guard logTailLines != lines else { return }
        logTailLines = lines
        reloadLogs()
    }

    func reloadLogs() {
        guard let row = selectedLogPodRow else { return }
        let ref = row.reference(kind: .pods, context: context)
        guard let namespace = ref.namespace else { return }
        logsTask?.cancel()
        let container = selectedLogContainer
        logsTask = Task { [weak self] in
            guard let self else { return }
            await loadLogs(namespace: namespace, pod: ref.name, container: container)
        }
    }

    private func loadLogs(namespace: String, pod: String, container: String?) async {
        isLoadingLogs = true
        let result = await logsReader.logs(namespace: namespace, pod: pod, container: container, tailLines: logTailLines, context: context)
        guard !Task.isCancelled else { return }
        logsResult = result
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
        guard let kind = selectedSection.resourceKind else { return }
        loadResource(kind: kind, bypassCache: bypassCache)
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

    func resourceList(for section: ClusterWorkspaceSection) -> KubernetesResourceList? {
        guard let kind = section.resourceKind else { return nil }
        return resourceLists[resourceKey(kind: kind)]
    }

    func isLoading(section: ClusterWorkspaceSection) -> Bool {
        guard let kind = section.resourceKind else { return false }
        return loadingResourceKinds.contains(kind)
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
        if selectedSection == .logs {
            return selectedLogPodID != nil ? isLoadingLogs : isLoading(section: .pods)
        }
        return isLoading(section: selectedSection)
    }

    func selectedResource(for section: ClusterWorkspaceSection) -> KubernetesResourceRow? {
        guard let kind = section.resourceKind else { return nil }
        return selectedResources[resourceKey(kind: kind)]
    }

    func selectResource(_ row: KubernetesResourceRow, in section: ClusterWorkspaceSection) {
        guard let kind = section.resourceKind else { return }
        selectedResources[resourceKey(kind: kind)] = row
        yamlResult = nil
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
        // The inspector's Logs tab shares this task with the standalone Logs
        // screen; closing the inspector must not leave a fetch running for a pod
        // that's no longer on screen anywhere.
        logsTask?.cancel()
        isLoadingLogs = false
    }

    /// Switches the active inspector tab for the current resource — mutating the
    /// existing `presentation` value in place, not dismissing and re-presenting a
    /// different one. Lazily kicks off the tab's own load the first time it's shown.
    func selectInspectorTab(_ tab: CTXInspectorTab) {
        guard let selection = presentation?.selection else { return }
        presentation?.tab = tab
        switch tab {
        case .overview:
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

    private func loadResource(kind: KubernetesResourceKind, bypassCache: Bool, priority: FetchPriority = .active, completion: ((KubernetesResourceList) -> Void)? = nil) {
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

    private func resourceKey(kind: KubernetesResourceKind) -> String {
        resourceKey(kind: kind, namespace: scope(for: kind))
    }

    private func resourceKey(kind: KubernetesResourceKind, namespace: KubernetesNamespaceSelection) -> String {
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
        case .configMaps, .secretMetadata:
            break
        }
    }

    private func handleNamespaceChange(previousNamespace: KubernetesNamespaceSelection) {
        let started = Date()
        persistNamespaceSelection()
        // Immediately: close the inspector and drop the selection tied to the
        // namespace that just went away.
        selectedResources.removeAll()
        presentation = nil
        yamlResult = nil
        yamlTask?.cancel()
        isLoadingYAML = false
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

    private func loadYAML(for selection: ClusterWorkspaceResourceSelection) {
        yamlTask?.cancel()
        yamlResult = nil
        guard selection.kind.supportsInspectionYAML else {
            yamlResult = KubernetesYAMLResult(yaml: nil, status: .permissionDenied)
            isLoadingYAML = false
            return
        }
        isLoadingYAML = true
        yamlTask = Task { [weak self] in
            guard let self else { return }
            let result = await yamlReader.yaml(kind: selection.kind, row: selection.row, context: context)
            guard !Task.isCancelled else { return }
            yamlResult = result
            isLoadingYAML = false
            yamlTask = nil
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
}
