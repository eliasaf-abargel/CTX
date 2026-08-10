import Foundation

public protocol ClusterHealthChecking: Sendable {
    func overview(for context: KubernetesContextProfile) async -> KubernetesOverviewSummary
}

public final class ClusterHealthService: ClusterHealthChecking {
    private let kubectl: any KubectlRunning & KubectlCommandBuilding
    private let timeout: TimeInterval

    public init(kubectl: any KubectlRunning & KubectlCommandBuilding = KubectlRunner(), timeout: TimeInterval = 12) {
        self.kubectl = kubectl
        self.timeout = timeout
    }

    public func overview(for context: KubernetesContextProfile) async -> KubernetesOverviewSummary {
        let apiResult = await runRead(step: "verify_kubectl", kind: "API", context: context, arguments: ["version", "--request-timeout=\(Int(timeout))s", "--output=json"])
        
        guard !Task.isCancelled else {
            return KubernetesOverviewSummary(
                apiStatus: .notChecked,
                rbac: blockedRBAC(status: .notChecked),
                namespaces: KubernetesNamespacesSummary(count: nil, activeNamespace: namespace(from: context), status: .notChecked),
                nodes: KubernetesNodesSummary(total: nil, ready: nil, notReady: nil, status: .notChecked),
                pods: KubernetesPodsSummary(total: nil, running: 0, pending: 0, failed: 0, crashLoopBackOff: 0, failing: 0, status: .notChecked),
                events: KubernetesEventsSummary(warningCount: nil, status: .notChecked),
                diagnostics: [apiResult.diagnostic]
            )
        }

        guard apiResult.status == .reachable else {
            return KubernetesOverviewSummary(
                apiStatus: apiResult.status,
                rbac: blockedRBAC(status: apiResult.status),
                namespaces: KubernetesNamespacesSummary(count: nil, activeNamespace: namespace(from: context), status: .notChecked),
                nodes: KubernetesNodesSummary(total: nil, ready: nil, notReady: nil, status: .notChecked),
                pods: KubernetesPodsSummary(total: nil, running: 0, pending: 0, failed: 0, crashLoopBackOff: 0, failing: 0, status: .notChecked),
                events: KubernetesEventsSummary(warningCount: nil, status: .notChecked),
                diagnostics: [apiResult.diagnostic]
            )
        }

        let rbacResult = await loadRBAC(context: context)

        return KubernetesOverviewSummary(
            apiStatus: apiResult.status,
            rbac: rbacResult.value,
            namespaces: KubernetesNamespacesSummary(count: nil, activeNamespace: namespace(from: context), status: .notChecked),
            nodes: KubernetesNodesSummary(total: nil, ready: nil, notReady: nil, status: .notChecked),
            pods: KubernetesPodsSummary(total: nil, running: 0, pending: 0, failed: 0, crashLoopBackOff: 0, failing: 0, status: .notChecked),
            events: KubernetesEventsSummary(warningCount: nil, status: .notChecked),
            diagnostics: [apiResult.diagnostic] + rbacResult.diagnostics
        )
    }

    private func blockedRBAC(status: KubernetesCheckStatus) -> [KubernetesPermissionSummary] {
        KubernetesRBACResource.allCases.map {
            KubernetesPermissionSummary(resource: $0.label, allowed: nil, status: status)
        }
    }

    private struct ReadResult {
        var status: KubernetesCheckStatus
        var stdout: String
        var diagnostic: KubernetesCommandDiagnostic
    }

    private struct SummaryResult<Value> {
        var value: Value
        var diagnostics: [KubernetesCommandDiagnostic]
    }

    private func loadRBAC(context: KubernetesContextProfile) async -> SummaryResult<[KubernetesPermissionSummary]> {
        let results = await withBoundedConcurrency(over: Array(KubernetesRBACResource.allCases), limit: 2) { resource in
            await self.permission(for: resource, context: context)
        }
        return SummaryResult(value: results.map(\.0), diagnostics: results.map(\.1))
    }

    private func permission(
        for resource: KubernetesRBACResource,
        context: KubernetesContextProfile
    ) async -> (KubernetesPermissionSummary, KubernetesCommandDiagnostic) {
        var arguments = ["auth", "can-i", "list", resource.kubectlResource]
        if resource.allNamespaces {
            arguments.append("--all-namespaces")
        }
        let result = await runRead(step: "cluster_health", kind: "RBAC \(resource.label)", context: context, arguments: arguments)
        let answer = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = answer == "yes" ? true : answer == "no" ? false : nil
        let summary = KubernetesPermissionSummary(
            resource: resource.label,
            allowed: allowed,
            status: allowed == nil ? result.status : allowed == true ? .reachable : .permissionDenied
        )
        return (summary, result.diagnostic)
    }

    private func runRead(step: String, kind: String, context: KubernetesContextProfile, arguments: [String]) async -> ReadResult {
        let started = Date()
        do {
            var command = try kubectl.inspectionCommand(context: context.contextName, arguments: context.kubeconfigArguments + arguments)
            command.environmentOverrides = context.kubeconfigEnvironment
            let result = try await kubectl.run(command, timeout: timeout)
            let category = KubernetesDiagnosticClassifier.category(from: result)
            logCall(step: step, kind: kind, context: context, durationMilliseconds: KubernetesCommandDiagnostic.elapsedMilliseconds(since: started), outcome: result.timedOut ? .timeout : (category == .success ? .success : .error))
            return ReadResult(
                status: KubernetesDiagnosticClassifier.status(from: category),
                stdout: result.stdout,
                diagnostic: KubernetesCommandDiagnostic(
                    kind: kind, context: context, result: result, category: category, startedAt: started,
                    summary: category == .success ? "read completed" : nil
                )
            )
        } catch KubectlRunnerError.kubectlNotFound {
            logCall(step: step, kind: kind, context: context, durationMilliseconds: KubernetesCommandDiagnostic.elapsedMilliseconds(since: started), outcome: .error)
            return ReadResult(status: .kubectlMissing, stdout: "", diagnostic: KubernetesCommandDiagnostic(
                kind: kind, context: context, category: .kubectlMissing, message: "kubectl was not found", startedAt: started
            ))
        } catch {
            logCall(step: step, kind: kind, context: context, durationMilliseconds: KubernetesCommandDiagnostic.elapsedMilliseconds(since: started), outcome: .error)
            return ReadResult(status: .unknownError, stdout: "", diagnostic: KubernetesCommandDiagnostic(
                kind: kind, context: context, category: .unknown, message: error.localizedDescription, startedAt: started
            ))
        }
    }

    private func logCall(step: String, kind: String, context: KubernetesContextProfile, durationMilliseconds: Int, outcome: CTXPerfLog.Outcome) {
        CTXPerfLog.log(step: step, contextID: context.id, namespace: "cluster", kind: kind, cache: .none, durationMs: durationMilliseconds, outcome: outcome)
    }







    private func namespace(from context: KubernetesContextProfile) -> String {
        context.namespace.isEmpty ? "default" : context.namespace
    }
}
