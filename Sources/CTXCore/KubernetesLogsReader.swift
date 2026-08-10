import Foundation

public struct KubernetesLogsResult: Equatable, Sendable {
    public var text: String?
    public var status: KubernetesCheckStatus
    public var diagnostic: KubernetesCommandDiagnostic?

    public init(text: String?, status: KubernetesCheckStatus, diagnostic: KubernetesCommandDiagnostic? = nil) {
        self.text = text
        self.status = status
        self.diagnostic = diagnostic
    }
}

public protocol KubernetesLogsReading: Sendable {
    func containers(namespace: String, pod: String, context: KubernetesContextProfile) async -> [String]
    func logs(namespace: String, pod: String, container: String?, tailLines: Int, context: KubernetesContextProfile) async -> KubernetesLogsResult
}

/// Inspection pod log tailing. Never execs into a pod, never streams indefinitely — always a bounded `--tail` snapshot.
public final class KubernetesLogsReader: KubernetesLogsReading {
    private let kubectl: any KubectlRunning & KubectlCommandBuilding
    private let timeout: TimeInterval

    public init(kubectl: any KubectlRunning & KubectlCommandBuilding = KubectlRunner(), timeout: TimeInterval = 10) {
        self.kubectl = kubectl
        self.timeout = timeout
    }

    public func containers(namespace: String, pod: String, context: KubernetesContextProfile) async -> [String] {
        let started = Date()
        do {
            var command = try kubectl.inspectionCommand(
                context: context.contextName,
                arguments: context.kubeconfigArguments + [
                    "get", "pod", pod,
                    "--namespace", namespace,
                    "--request-timeout=\(Int(timeout))s",
                    "--output=jsonpath={.spec.containers[*].name}"
                ]
            )
            command.environmentOverrides = context.kubeconfigEnvironment
            let result = try await kubectl.run(command, timeout: timeout)
            logCall(step: "logs_containers", scope: namespace, context: context, started: started, outcome: result.exitCode == 0 ? .success : .error)
            guard result.exitCode == 0 else { return [] }
            return result.stdout.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        } catch {
            logCall(step: "logs_containers", scope: namespace, context: context, started: started, outcome: .error)
            return []
        }
    }

    public func logs(namespace: String, pod: String, container: String?, tailLines: Int, context: KubernetesContextProfile) async -> KubernetesLogsResult {
        let started = Date()
        do {
            var arguments = context.kubeconfigArguments + [
                "logs", pod,
                "--namespace", namespace,
                "--tail=\(max(1, tailLines))",
                "--timestamps",
                "--request-timeout=\(Int(timeout))s"
            ]
            if let container, !container.isEmpty {
                arguments += ["--container", container]
            }
            var command = try kubectl.inspectionCommand(context: context.contextName, arguments: arguments)
            command.environmentOverrides = context.kubeconfigEnvironment
            let result = try await kubectl.run(command, timeout: timeout)
            let category = KubernetesDiagnosticClassifier.category(from: result)
            let diag = KubernetesCommandDiagnostic(
            kind: "Logs", context: context, result: result, category: category, startedAt: started,
            summary: category == .success ? "inspection logs completed" : nil
        )
            logCall(step: "logs_fetch", scope: namespace, context: context, started: started, outcome: result.timedOut ? .timeout : (category == .success ? .success : .error))
            guard category == .success else {
                return KubernetesLogsResult(text: nil, status: KubernetesDiagnosticClassifier.status(from: category), diagnostic: diag)
            }
            return KubernetesLogsResult(text: result.stdout, status: .reachable, diagnostic: diag)
        } catch KubectlRunnerError.kubectlNotFound {
            logCall(step: "logs_fetch", scope: namespace, context: context, started: started, outcome: .error)
            return failed(context: context, category: .kubectlMissing, message: "kubectl was not found", started: started)
        } catch {
            logCall(step: "logs_fetch", scope: namespace, context: context, started: started, outcome: .error)
            return failed(context: context, category: .unknown, message: error.localizedDescription, started: started)
        }
    }

    private func logCall(step: String, scope: String, context: KubernetesContextProfile, started: Date, outcome: CTXPerfLog.Outcome) {
        CTXPerfLog.log(
            step: step,
            contextID: context.id,
            namespace: scope,
            kind: "pods",
            cache: .none,
            durationMs: max(0, Int(Date().timeIntervalSince(started) * 1000)),
            outcome: outcome
        )
    }




    private func failed(context: KubernetesContextProfile, category: KubernetesDiagnosticCategory, message: String, started: Date) -> KubernetesLogsResult {
        KubernetesLogsResult(
            text: nil,
            status: KubernetesDiagnosticClassifier.status(from: category),
            diagnostic: KubernetesCommandDiagnostic(
                kind: "Logs", context: context, category: category, message: message, startedAt: started
            )
        )
    }
}
