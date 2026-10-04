import CTXCore
import Foundation
import SwiftUI

/// What a person needs to see *before* confirming a lifecycle action: is a
/// GitOps controller already reconciling this object, and — for Rollback —
/// which revision it would land on. One published value instead of two, so
/// a selection change can't leave one half stale while the other updates.
struct WorkloadLifecyclePreflight: Equatable {
    var gitOpsOwnership: KubernetesGitOpsOwnership?
    var revisions: [KubernetesRolloutRevision] = []
}

extension ClusterWorkspaceViewModel {
    /// Nil for anything that isn't a Deployment/StatefulSet/DaemonSet — the
    /// only kinds `kubectl rollout`/`kubectl scale` operate on. Callers use
    /// this to decide whether to show lifecycle actions at all.
    func controllerKind(for row: KubernetesResourceRow) -> KubernetesWorkloadControllerKind? {
        KubernetesWorkloadControllerKind(rowKind: row.cells["Kind"] ?? "")
    }

    /// The desired replica count from the "Ready" cell's `"x/y"` — the same
    /// column the Workloads table already renders, read back rather than a
    /// second live fetch just to know what to restore on "Start".
    func desiredReplicas(for row: KubernetesResourceRow) -> Int? {
        guard let ready = row.cells["Ready"] else { return nil }
        let parts = ready.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }

    /// Fetched once when the Lifecycle section appears for a resource —
    /// GitOps ownership and, for Rollback, the actual revisions involved —
    /// so the confirmation can say something true instead of a generic
    /// "roll back to the previous revision."
    func loadLifecyclePreflight(_ selection: ClusterWorkspaceResourceSelection) {
        guard let kind = controllerKind(for: selection.row), let namespace = selection.row.namespace else {
            lifecyclePreflight = nil
            return
        }
        let name = selection.row.name
        Task { [weak self, lifecycleService, context] in
            async let ownership = lifecycleService.detectGitOpsOwnership(kind: kind, name: name, namespace: namespace, context: context)
            async let revisions = lifecycleService.recentRolloutRevisions(kind: kind, name: name, namespace: namespace, context: context)
            let result = await WorkloadLifecyclePreflight(gitOpsOwnership: ownership, revisions: revisions)
            guard let self else { return }
            await MainActor.run {
                self.lifecyclePreflight = result
            }
        }
    }

    func restartWorkload(_ selection: ClusterWorkspaceResourceSelection) {
        guard !isPerformingLifecycleAction,
              let kind = controllerKind(for: selection.row),
              let namespace = selection.row.namespace
        else { return }
        performLifecycleAction(selection, verb: "restart") { [lifecycleService, context] in
            await lifecycleService.restart(kind: kind, name: selection.row.name, namespace: namespace, context: context)
        }
    }

    func stopWorkload(_ selection: ClusterWorkspaceResourceSelection) {
        guard !isPerformingLifecycleAction,
              let kind = controllerKind(for: selection.row),
              let namespace = selection.row.namespace
        else { return }
        let rememberedReplicas = desiredReplicas(for: selection.row).map { max($0, 1) } ?? 1
        performLifecycleAction(selection, verb: "stop") { [lifecycleService, context] in
            await lifecycleService.scale(kind: kind, name: selection.row.name, namespace: namespace, context: context, replicas: 0)
        } onSuccess: {
            self.stoppedReplicaCounts[selection.row.id] = rememberedReplicas
        }
    }

    func startWorkload(_ selection: ClusterWorkspaceResourceSelection) {
        guard !isPerformingLifecycleAction,
              let kind = controllerKind(for: selection.row),
              let namespace = selection.row.namespace
        else { return }
        let replicas = stoppedReplicaCounts[selection.row.id] ?? 1
        performLifecycleAction(selection, verb: "start") { [lifecycleService, context] in
            await lifecycleService.scale(kind: kind, name: selection.row.name, namespace: namespace, context: context, replicas: replicas)
        } onSuccess: {
            self.stoppedReplicaCounts.removeValue(forKey: selection.row.id)
        }
    }

    func rollbackWorkload(_ selection: ClusterWorkspaceResourceSelection) {
        guard !isPerformingLifecycleAction,
              let kind = controllerKind(for: selection.row),
              let namespace = selection.row.namespace
        else { return }
        performLifecycleAction(selection, verb: "rollback") { [lifecycleService, context] in
            await lifecycleService.rollbackToPreviousRevision(kind: kind, name: selection.row.name, namespace: namespace, context: context)
        }
    }

    private func performLifecycleAction(
        _ selection: ClusterWorkspaceResourceSelection,
        verb: String,
        action: @escaping () async -> KubernetesLifecycleActionResult,
        onSuccess: (() -> Void)? = nil
    ) {
        isPerformingLifecycleAction = true
        lifecycleActionResult = nil
        Task { [weak self] in
            guard let self else { return }
            let result = await action()
            await MainActor.run {
                self.isPerformingLifecycleAction = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.lifecycleActionResult = result
                }
                try? self.auditLog.record(AuditEvent(
                    type: result.success ? .workloadLifecycleAction : .workloadLifecycleActionFailed,
                    contextName: self.context.contextName,
                    message: "\(verb) \(selection.kind.rawValue)/\(selection.row.name) in \(selection.row.namespace ?? "-"): \(result.message)"
                ))

                // Auto-dismiss the outcome message after 4 seconds
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard let self else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        self.lifecycleActionResult = nil
                    }
                }

                if result.success {
                    onSuccess?()
                    self.startRolloutWatch(for: selection.row.id)
                }
            }
        }
    }

    /// Polls both Workloads and Pods live after Restart/Stop/Start/Rollback,
    /// refreshing pods in the background so newly scheduled and terminating pods
    /// appear immediately in both the inspector and the logs screen.
    private func startRolloutWatch(for rowID: String) {
        rolloutWatchTask?.cancel()
        rolloutWatchTask = Task { [weak self] in
            // Wait 1.5s for Kubernetes controller manager to spin up replacement pods
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            for _ in 0..<12 {
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    self.loadResource(kind: .workloads, bypassCache: true)
                    self.loadResource(kind: .pods, bypassCache: true)
                    self.loadPodsForLogs(bypassCache: true)
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }

            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.loadResource(kind: .workloads, bypassCache: true)
                self.loadResource(kind: .pods, bypassCache: true)
                self.loadPodsForLogs(bypassCache: true)
            }
        }
    }

    @MainActor
    private func fetchWorkloadsList() async -> KubernetesResourceList {
        await withCheckedContinuation { continuation in
            loadResource(kind: .workloads, bypassCache: true) { list in
                continuation.resume(returning: list)
            }
        }
    }
}
