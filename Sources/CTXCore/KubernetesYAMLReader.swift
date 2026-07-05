import Foundation

public protocol KubernetesYAMLReading: Sendable {
    func yaml(kind: KubernetesResourceKind, row: KubernetesResourceRow, context: KubernetesContextProfile) async -> KubernetesYAMLResult
}

public final class KubernetesYAMLReader: KubernetesYAMLReading {
    private let kubectl: any KubectlRunning & KubectlCommandBuilding
    private let timeout: TimeInterval

    public init(kubectl: any KubectlRunning & KubectlCommandBuilding = KubectlRunner(), timeout: TimeInterval = 10) {
        self.kubectl = kubectl
        self.timeout = timeout
    }

    public func yaml(kind: KubernetesResourceKind, row: KubernetesResourceRow, context: KubernetesContextProfile) async -> KubernetesYAMLResult {
        let ref = row.reference(kind: kind, context: context)
        guard kind.supportsInspectionYAML, let resource = resourceName(kind: ref.kind) else {
            return KubernetesYAMLResult(
                yaml: nil,
                status: .permissionDenied,
                diagnostic: KubernetesCommandDiagnostic(
                    commandKind: "\(ref.kind.title) YAML",
                    contextName: context.contextName,
                    kubeconfigPath: KubernetesDiagnosticClassifier.safeKubeconfigPath(context.kubeconfigPath),
                    exitCode: nil,
                    durationMilliseconds: 0,
                    category: .forbidden,
                    stderrSummary: "YAML disabled for this resource to avoid exposing values"
                )
            )
        }

        let started = Date()
        do {
            var command = try kubectl.inspectionCommand(
                context: context.contextName,
                arguments: arguments(resource: resource, ref: ref, context: context)
            )
            command.environmentOverrides = kubeconfigEnvironment(context)
            let result = try await kubectl.run(command, timeout: timeout)
            let category = KubernetesDiagnosticClassifier.category(from: result)
            let diagnostic = diagnostic(kind: ref.kind, context: context, result: result, category: category, started: started)
            logCall(kind: ref.kind, context: context, namespace: ref.namespace, started: started, outcome: result.timedOut ? .timeout : (category == .success ? .success : .error))
            guard category == .success else {
                return KubernetesYAMLResult(yaml: nil, status: KubernetesDiagnosticClassifier.status(from: category), diagnostic: diagnostic)
            }
            return KubernetesYAMLResult(yaml: result.stdout, status: .reachable, diagnostic: diagnostic)
        } catch KubectlRunnerError.kubectlNotFound {
            logCall(kind: ref.kind, context: context, namespace: ref.namespace, started: started, outcome: .error)
            return failed(kind: ref.kind, context: context, category: .kubectlMissing, message: "kubectl was not found", started: started)
        } catch {
            logCall(kind: ref.kind, context: context, namespace: ref.namespace, started: started, outcome: .error)
            return failed(kind: ref.kind, context: context, category: .unknown, message: error.localizedDescription, started: started)
        }
    }

    private func logCall(kind: KubernetesResourceKind, context: KubernetesContextProfile, namespace: String?, started: Date, outcome: CTXPerfLog.Outcome) {
        CTXPerfLog.log(
            step: "yaml_load",
            contextID: context.id,
            namespace: kind.isClusterScoped ? "cluster" : (namespace ?? "cluster"),
            kind: kind.rawValue,
            cache: .none,
            durationMs: max(0, Int(Date().timeIntervalSince(started) * 1000)),
            outcome: outcome
        )
    }

    private func arguments(resource: String, ref: KubernetesResourceRef, context: KubernetesContextProfile) -> [String] {
        var args = kubeconfigArguments(context) + ["get", resource, ref.name]
        if !ref.kind.isClusterScoped, let namespace = ref.namespace {
            args += ["--namespace", namespace]
        }
        return args + ["--request-timeout=\(Int(timeout))s", "--output=yaml"]
    }

    private func resourceName(kind: KubernetesResourceKind) -> String? {
        switch kind {
        case .namespaces: "namespace"
        case .nodes: "node"
        case .pods: "pod"
        case .services: "service"
        case .ingress: "ingress"
        case .events: "event"
        case .workloads, .configMaps, .secretMetadata: nil
        }
    }

    private func kubeconfigArguments(_ context: KubernetesContextProfile) -> [String] {
        context.kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : ["--kubeconfig", context.kubeconfigPath]
    }

    private func kubeconfigEnvironment(_ context: KubernetesContextProfile) -> [String: String] {
        let path = context.kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? [:] : ["KUBECONFIG": path]
    }

    private func diagnostic(
        kind: KubernetesResourceKind,
        context: KubernetesContextProfile,
        result: KubectlResult,
        category: KubernetesDiagnosticCategory,
        started: Date
    ) -> KubernetesCommandDiagnostic {
        KubernetesCommandDiagnostic(
            commandKind: "\(kind.title) YAML",
            contextName: context.contextName,
            kubeconfigPath: KubernetesDiagnosticClassifier.safeKubeconfigPath(context.kubeconfigPath),
            exitCode: result.exitCode,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1000)),
            category: category,
            stderrSummary: diagnosticSummary(result: result, category: category)
        )
    }

    private func diagnosticSummary(result: KubectlResult, category: KubernetesDiagnosticCategory) -> String {
        let stderr = KubernetesDiagnosticClassifier.sanitize(result.stderr)
        if category == .success {
            return "inspection YAML completed"
        }
        return stderr.isEmpty ? category.presentationSummary : stderr
    }

    private func failed(
        kind: KubernetesResourceKind,
        context: KubernetesContextProfile,
        category: KubernetesDiagnosticCategory,
        message: String,
        started: Date
    ) -> KubernetesYAMLResult {
        KubernetesYAMLResult(
            yaml: nil,
            status: KubernetesDiagnosticClassifier.status(from: category),
            diagnostic: KubernetesCommandDiagnostic(
                commandKind: "\(kind.title) YAML",
                contextName: context.contextName,
                kubeconfigPath: KubernetesDiagnosticClassifier.safeKubeconfigPath(context.kubeconfigPath),
                exitCode: nil,
                durationMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1000)),
                category: category,
                stderrSummary: KubernetesDiagnosticClassifier.sanitize(message)
            )
        )
    }
}
