import Foundation

public protocol KubernetesWorkloadSpecReading: Sendable {
    func podSpec(context: KubernetesContextProfile, namespace: String, name: String) async -> PodSpecInsight
    func serviceEndpoints(context: KubernetesContextProfile, namespace: String, name: String) async -> ServiceEndpointsInsight
}

/// Fetches the one object the inspector is showing, on demand.
///
/// Deliberately not folded into the list fetch: a namespace can hold thousands of
/// pods, and keeping every container's env, probes and security context in memory
/// for all of them would cost far more than one read of the single pod the user
/// actually opened. Reads are `-o json` on a named object, so they stay small and
/// fast even on large clusters.
public final class KubernetesWorkloadSpecReader: KubernetesWorkloadSpecReading {
    private let kubectl: any KubectlRunning & KubectlCommandBuilding
    private let timeout: TimeInterval

    public init(
        kubectl: any KubectlRunning & KubectlCommandBuilding = KubectlRunner(),
        timeout: TimeInterval = 12
    ) {
        self.kubectl = kubectl
        self.timeout = timeout
    }

    public func podSpec(context: KubernetesContextProfile, namespace: String, name: String) async -> PodSpecInsight {
        let outcome = await read(kind: "pod", context: context, namespace: namespace, name: name)
        switch outcome {
        case .failure(let diagnostic):
            return PodSpecInsight(
                status: KubernetesDiagnosticClassifier.status(from: diagnostic.category),
                diagnostic: diagnostic
            )
        case .success(let stdout):
            guard let insight = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: stdout) else {
                return PodSpecInsight(status: .unknownError, diagnostic: nil)
            }
            return insight
        }
    }

    public func serviceEndpoints(context: KubernetesContextProfile, namespace: String, name: String) async -> ServiceEndpointsInsight {
        let outcome = await read(kind: "endpoints", context: context, namespace: namespace, name: name, ignoreNotFound: true)
        switch outcome {
        case .failure(let diagnostic):
            return ServiceEndpointsInsight(
                status: KubernetesDiagnosticClassifier.status(from: diagnostic.category),
                diagnostic: diagnostic
            )
        case .success(let stdout):
            // `--ignore-not-found` returns empty stdout when the Service has no
            // Endpoints object at all — a real and telling state (nothing is
            // backing it), reported here as zero targets rather than as an error.
            // Detecting it by matching "not found" in stderr, as this used to,
            // depended on kubectl's exact wording.
            return ServiceEndpointsInsight(
                targets: KubernetesWorkloadSpecParser.endpoints(fromEndpointsJSON: stdout),
                status: .reachable
            )
        }
    }

    private enum ReadOutcome {
        case success(String)
        case failure(KubernetesCommandDiagnostic)
    }

    private func read(
        kind: String,
        context: KubernetesContextProfile,
        namespace: String,
        name: String,
        ignoreNotFound: Bool = false
    ) async -> ReadOutcome {
        let started = Date()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .failure(KubernetesCommandDiagnostic(kind: kind, context: context, category: .unknown, message: "missing resource name", startedAt: started))
        }

        var arguments = context.kubeconfigArguments + ["get", kind, trimmedName]
        let trimmedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNamespace.isEmpty {
            arguments += ["--namespace", trimmedNamespace]
        }
        arguments += ["--output=json", "--request-timeout=\(Int(timeout))s"]
        if ignoreNotFound {
            arguments.append("--ignore-not-found")
        }

        do {
            var command = try kubectl.inspectionCommand(context: context.contextName, arguments: arguments)
            command.environmentOverrides = context.kubeconfigEnvironment
            let result = try await kubectl.run(command, timeout: timeout)
            guard result.exitCode == 0 else {
                let category = KubernetesDiagnosticClassifier.category(from: result)
                return .failure(KubernetesCommandDiagnostic(kind: kind, context: context, result: result, category: category, startedAt: started))
            }
            return .success(result.stdout)
        } catch KubectlRunnerError.kubectlNotFound {
            return .failure(KubernetesCommandDiagnostic(kind: kind, context: context, category: .kubectlMissing, message: "kubectl was not found", startedAt: started))
        } catch {
            return .failure(KubernetesCommandDiagnostic(kind: kind, context: context, category: .unknown, message: error.localizedDescription, startedAt: started))
        }
    }



}
