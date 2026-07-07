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
        let resources = Array(KubernetesRBACResource.allCases)
        let concurrencyLimit = 2
        let results = await withTaskGroup(of: (Int, KubernetesPermissionSummary, KubernetesCommandDiagnostic).self) { group in
            var collected: [(Int, KubernetesPermissionSummary, KubernetesCommandDiagnostic)] = []
            var iterator = resources.enumerated().makeIterator()
            
            for _ in 0..<concurrencyLimit {
                if let next = iterator.next() {
                    group.addTask {
                        let (index, resource) = next
                        var arguments = ["auth", "can-i", "list", resource.kubectlResource]
                        if resource.allNamespaces {
                            arguments.append("--all-namespaces")
                        }
                        let result = await self.runRead(step: "cluster_health", kind: "RBAC \(resource.label)", context: context, arguments: arguments)
                        let answer = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let allowed = answer == "yes" ? true : answer == "no" ? false : nil
                        let summary = KubernetesPermissionSummary(resource: resource.label, allowed: allowed, status: allowed == nil ? result.status : allowed == true ? .reachable : .permissionDenied)
                        return (index, summary, result.diagnostic)
                    }
                }
            }
            
            while let entry = await group.next() {
                collected.append(entry)
                if let next = iterator.next() {
                    group.addTask {
                        let (index, resource) = next
                        var arguments = ["auth", "can-i", "list", resource.kubectlResource]
                        if resource.allNamespaces {
                            arguments.append("--all-namespaces")
                        }
                        let result = await self.runRead(step: "cluster_health", kind: "RBAC \(resource.label)", context: context, arguments: arguments)
                        let answer = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let allowed = answer == "yes" ? true : answer == "no" ? false : nil
                        let summary = KubernetesPermissionSummary(resource: resource.label, allowed: allowed, status: allowed == nil ? result.status : allowed == true ? .reachable : .permissionDenied)
                        return (index, summary, result.diagnostic)
                    }
                }
            }
            return collected.sorted { $0.0 < $1.0 }
        }
        return SummaryResult(value: results.map(\.1), diagnostics: results.map(\.2))
    }

    private func runRead(step: String, kind: String, context: KubernetesContextProfile, arguments: [String]) async -> ReadResult {
        let started = Date()
        do {
            var command = try kubectl.inspectionCommand(context: context.contextName, arguments: kubeconfigArguments(context) + arguments)
            command.environmentOverrides = kubeconfigEnvironment(context)
            let result = try await kubectl.run(command, timeout: timeout)
            let category = KubernetesDiagnosticClassifier.category(from: result)
            logCall(step: step, kind: kind, context: context, durationMilliseconds: durationMilliseconds(since: started), outcome: result.timedOut ? .timeout : (category == .success ? .success : .error))
            return ReadResult(
                status: KubernetesDiagnosticClassifier.status(from: category),
                stdout: result.stdout,
                diagnostic: diagnostic(kind: kind, context: context, result: result, category: category, started: started)
            )
        } catch KubectlRunnerError.kubectlNotFound {
            logCall(step: step, kind: kind, context: context, durationMilliseconds: durationMilliseconds(since: started), outcome: .error)
            return failedRead(kind: kind, context: context, category: .kubectlMissing, message: "kubectl was not found", started: started)
        } catch {
            logCall(step: step, kind: kind, context: context, durationMilliseconds: durationMilliseconds(since: started), outcome: .error)
            return failedRead(kind: kind, context: context, category: .unknown, message: error.localizedDescription, started: started)
        }
    }

    private func logCall(step: String, kind: String, context: KubernetesContextProfile, durationMilliseconds: Int, outcome: CTXPerfLog.Outcome) {
        CTXPerfLog.log(step: step, contextID: context.id, namespace: "cluster", kind: kind, cache: .none, durationMs: durationMilliseconds, outcome: outcome)
    }

    private func kubeconfigArguments(_ context: KubernetesContextProfile) -> [String] {
        context.kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : ["--kubeconfig", context.kubeconfigPath]
    }

    private func kubeconfigEnvironment(_ context: KubernetesContextProfile) -> [String: String] {
        let path = context.kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? [:] : ["KUBECONFIG": path]
    }

    private func diagnostic(
        kind: String,
        context: KubernetesContextProfile,
        result: KubectlResult,
        category: KubernetesDiagnosticCategory,
        started: Date
    ) -> KubernetesCommandDiagnostic {
        KubernetesCommandDiagnostic(
            commandKind: kind,
            contextName: context.contextName,
            kubeconfigPath: KubernetesDiagnosticClassifier.safeKubeconfigPath(context.kubeconfigPath),
            exitCode: result.exitCode,
            durationMilliseconds: durationMilliseconds(since: started),
            category: category,
            stderrSummary: diagnosticSummary(result: result, category: category)
        )
    }

    private func diagnosticSummary(result: KubectlResult, category: KubernetesDiagnosticCategory) -> String {
        let stderr = KubernetesDiagnosticClassifier.sanitize(result.stderr)
        if category == .success {
            return "read completed"
        }
        return stderr.isEmpty ? category.presentationSummary : stderr
    }

    private func failedRead(
        kind: String,
        context: KubernetesContextProfile,
        category: KubernetesDiagnosticCategory,
        message: String,
        started: Date
    ) -> ReadResult {
        let diag = KubernetesCommandDiagnostic(
            commandKind: kind,
            contextName: context.contextName,
            kubeconfigPath: KubernetesDiagnosticClassifier.safeKubeconfigPath(context.kubeconfigPath),
            exitCode: nil,
            durationMilliseconds: durationMilliseconds(since: started),
            category: category,
            stderrSummary: KubernetesDiagnosticClassifier.sanitize(message)
        )
        return ReadResult(status: KubernetesDiagnosticClassifier.status(from: category), stdout: "", diagnostic: diag)
    }

    private func durationMilliseconds(since started: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(started) * 1000))
    }

    private func namespace(from context: KubernetesContextProfile) -> String {
        context.namespace.isEmpty ? "default" : context.namespace
    }
}
