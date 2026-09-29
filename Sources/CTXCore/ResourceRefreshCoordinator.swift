import Foundation

/// Owns the fetch/cache/dedup *decision* for one (context, namespace, kind) key.
/// The view model still owns `@Published` state for SwiftUI binding, but it asks
/// this actor whether a live kubectl call is actually needed instead of computing
/// that itself — which also makes the decision unit-testable: view models live in
/// the app target and can't be imported by `CTXCoreTests`, this actor lives in
/// CTXCore and can.
public actor ResourceRefreshCoordinator {
    public enum CacheState: Equatable, Sendable {
        case hit
        case stale
        case miss
    }

    public struct FetchOutcome: Sendable {
        public let list: KubernetesResourceList
        public let cacheStateBeforeFetch: CacheState
    }

    private struct Key: Hashable {
        let contextID: String
        let namespace: String
        let kind: KubernetesResourceKind
    }

    private var entries: [Key: KubernetesResourceList] = [:]
    private var inFlight: [Key: Task<KubernetesResourceList, Never>] = [:]
    /// The priority the in-flight task for a key was actually started with —
    /// needed so a later `.active` caller can tell it would otherwise be joining
    /// gate-limited `.background` work instead of getting its own immediate,
    /// ungated attempt (see `fetch(...)`).
    private var inFlightPriority: [Key: FetchPriority] = [:]
    /// Bumped each time a new fetch starts for a key, so a cancelled fetch that
    /// resolves late (cooperative cancellation, not instant) can tell it's no longer
    /// the current request for that key and must not touch shared state.
    private var generation: [Key: Int] = [:]
    private let reader: any KubernetesResourceReading
    private let staleThreshold: TimeInterval
    /// Optional L2 cache — `nil` in every test and in any caller that doesn't
    /// explicitly opt in, so existing in-memory-only behavior (and its exact
    /// call-count assertions) is unaffected unless a disk cache is actually
    /// wired in. Disk-hydrated data always reads as `.stale` on first read (a
    /// prior app run is, by definition, older than `staleThreshold`), which is
    /// exactly what triggers a background refresh right behind it — no separate
    /// "disk hit" state is needed.
    private let diskCache: SQLiteResourceCache?
    /// Optional — `nil` in every test and unless the caller opts in. Only
    /// `.background`-priority fetches ever touch it; `.active` fetches always
    /// proceed immediately regardless of how many background fetches are queued.
    private let backgroundGate: KubectlConcurrencyGate?

    public init(
        reader: any KubernetesResourceReading,
        staleThreshold: TimeInterval = 30,
        diskCache: SQLiteResourceCache? = nil,
        backgroundGate: KubectlConcurrencyGate? = nil
    ) {
        self.reader = reader
        self.staleThreshold = staleThreshold
        self.diskCache = diskCache
        self.backgroundGate = backgroundGate
    }

    public func cacheState(contextID: String, namespace: KubernetesNamespaceSelection, kind: KubernetesResourceKind) -> CacheState {
        state(for: key(contextID: contextID, namespace: namespace, kind: kind))
    }

    public func cachedList(contextID: String, namespace: KubernetesNamespaceSelection, kind: KubernetesResourceKind) -> KubernetesResourceList? {
        entries[key(contextID: contextID, namespace: namespace, kind: kind)]
    }

    public func loadDiskCachedIfNeeded(contextID: String, namespace: KubernetesNamespaceSelection, kind: KubernetesResourceKind) async -> KubernetesResourceList? {
        let requestKey = key(contextID: contextID, namespace: namespace, kind: kind)
        if entries[requestKey] == nil, let diskCache {
            if let diskEntry = await diskCache.load(contextID: contextID, namespace: namespace.storageValue, kind: kind.rawValue) {
                entries[requestKey] = diskEntry
            }
        }
        return entries[requestKey]
    }

    /// Fetches a resource list. A fresh cache hit returns immediately with no live
    /// call. A stale or missing entry triggers a live fetch, joining an existing
    /// in-flight fetch for the same key rather than starting a duplicate one. A
    /// failed live fetch never overwrites a good cached entry — the caller decides
    /// how to surface the failure while the last-known-good data stays cached.
    @discardableResult
    public func fetch(
        contextID: String,
        context: KubernetesContextProfile,
        namespace: KubernetesNamespaceSelection,
        kind: KubernetesResourceKind,
        bypassCache: Bool,
        priority: FetchPriority = .active
    ) async -> FetchOutcome {
        let requestKey = key(contextID: contextID, namespace: namespace, kind: kind)
        var stateBefore = state(for: requestKey)

        // Cold start: nothing in memory yet. Seed from disk before deciding
        // whether a live call is needed — this is what makes the very first
        // render after launch show real data instead of a skeleton.
        if stateBefore == .miss, let diskCache {
            if let diskEntry = await diskCache.load(contextID: contextID, namespace: namespace.storageValue, kind: kind.rawValue) {
                entries[requestKey] = diskEntry
                stateBefore = state(for: requestKey)
            }
        }

        if !bypassCache, stateBefore == .hit, let cached = entries[requestKey] {
            return FetchOutcome(list: cached, cacheStateBeforeFetch: stateBefore)
        }

        if let existing = inFlight[requestKey] {
            // An `.active` caller (the screen the user is actually looking at)
            // must never inherit a `.background` fetch's wait behind the
            // concurrency gate — that's exactly how a Nodes screen open could end
            // up taking far longer than a plain, uncontended `kubectl get nodes`,
            // even though the manual command itself completes in a few seconds.
            // Cancel the gated background attempt and start a fresh, ungated one;
            // `generation` already guarantees the abandoned task's eventual
            // result (cooperative cancellation isn't instant) can never land.
            if priority == .active, inFlightPriority[requestKey] == .background {
                existing.cancel()
                inFlight[requestKey] = nil
                inFlightPriority[requestKey] = nil
            } else {
                return FetchOutcome(list: await existing.value, cacheStateBeforeFetch: stateBefore)
            }
        }

        let myGeneration = (generation[requestKey] ?? 0) + 1
        generation[requestKey] = myGeneration

        let gate = priority == .background ? backgroundGate : nil
        let task = Task<KubernetesResourceList, Never> { [reader] in
            if let gate {
                do {
                    try await gate.acquire()
                } catch {
                    return KubernetesResourceList(kind: kind, columns: [], rows: [], status: .notChecked)
                }
                defer { Task { await gate.release() } }
                return await reader.list(kind: kind, context: context, namespace: namespace)
            }
            return await reader.list(kind: kind, context: context, namespace: namespace)
        }
        inFlight[requestKey] = task
        inFlightPriority[requestKey] = priority
        let result = await task.value
        // `cancel(...)` may have already removed this key and asked the task to stop —
        // the underlying reader may still resolve normally (cooperative cancellation),
        // but a cancelled request must never write its result into the cache, and must
        // not clobber bookkeeping for a newer request that's since taken over this key
        // (exactly the "stale response lands after a namespace switch" bug).
        let wasCancelled = task.isCancelled
        let isCurrent = generation[requestKey] == myGeneration
        if isCurrent {
            inFlight[requestKey] = nil
            inFlightPriority[requestKey] = nil
            if !wasCancelled, result.status == .reachable || entries[requestKey] == nil {
                entries[requestKey] = result
            }
            if !wasCancelled, result.status == .reachable, let diskCache {
                // Best-effort, off the return path — the caller never waits on
                // the disk write, only on the live kubectl result it already has.
                Task.detached {
                    await diskCache.store(contextID: contextID, namespace: namespace.storageValue, kind: kind.rawValue, list: result)
                }
            }
        }
        return FetchOutcome(list: result, cacheStateBeforeFetch: stateBefore)
    }

    /// Fetches multiple resource kinds in a single aggregated batch.
    /// Hits from cache return immediately; any stale or missing kinds are queried in a single call.
    @discardableResult
    public func fetchBatch(
        contextID: String,
        context: KubernetesContextProfile,
        namespace: KubernetesNamespaceSelection,
        kinds: [KubernetesResourceKind],
        bypassCache: Bool,
        priority: FetchPriority = .active
    ) async -> [KubernetesResourceKind: KubernetesResourceList] {
        var neededKinds: [KubernetesResourceKind] = []
        var results: [KubernetesResourceKind: KubernetesResourceList] = [:]

        for kind in kinds {
            let requestKey = key(contextID: contextID, namespace: namespace, kind: kind)
            var stateBefore = state(for: requestKey)
            if stateBefore == .miss, let diskCache {
                if let diskEntry = await diskCache.load(contextID: contextID, namespace: namespace.storageValue, kind: kind.rawValue) {
                    entries[requestKey] = diskEntry
                    stateBefore = state(for: requestKey)
                }
            }
            if !bypassCache, stateBefore == .hit, let cached = entries[requestKey] {
                results[kind] = cached
            } else {
                neededKinds.append(kind)
            }
        }

        if neededKinds.isEmpty {
            return results
        }

        let fetched = await reader.batchList(kinds: neededKinds, context: context, namespace: namespace)
        for (kind, list) in fetched {
            let requestKey = key(contextID: contextID, namespace: namespace, kind: kind)
            if list.status == .reachable || entries[requestKey] == nil {
                entries[requestKey] = list
            }
            results[kind] = list
            if list.status == .reachable, let diskCache {
                Task.detached {
                    await diskCache.store(contextID: contextID, namespace: namespace.storageValue, kind: kind.rawValue, list: list)
                }
            }
        }
        return results
    }

    /// Cancels in-flight fetches for a context, or — when `namespace` is given —
    /// only those scoped to that namespace, so a slow response for a namespace the
    /// user already switched away from can never land as if it were current.
    public func cancel(contextID: String, namespace: KubernetesNamespaceSelection? = nil, kind: KubernetesResourceKind? = nil) {
        for (entryKey, task) in inFlight {
            guard entryKey.contextID == contextID else { continue }
            if let namespace, entryKey.namespace != namespace.storageValue { continue }
            if let kind, entryKey.kind != kind { continue }
            task.cancel()
            inFlight.removeValue(forKey: entryKey)
            inFlightPriority.removeValue(forKey: entryKey)
        }
    }

    private func key(contextID: String, namespace: KubernetesNamespaceSelection, kind: KubernetesResourceKind) -> Key {
        Key(contextID: contextID, namespace: namespace.storageValue, kind: kind)
    }

    private func state(for key: Key) -> CacheState {
        guard let cached = entries[key] else { return .miss }
        return Date().timeIntervalSince(cached.loadedAt) > staleThreshold ? .stale : .hit
    }
}
