import Foundation

public enum KubernetesPortForwardTargetKind: String, Codable, Sendable {
    case service

    var kubectlResource: String {
        switch self {
        case .service: "service"
        }
    }
}

public struct KubernetesPortForwardRequest: Equatable, Sendable {
    public var namespace: String
    public var targetKind: KubernetesPortForwardTargetKind
    public var targetName: String
    public var localPort: Int
    public var remotePort: Int

    public init(namespace: String, targetKind: KubernetesPortForwardTargetKind, targetName: String, localPort: Int, remotePort: Int) {
        self.namespace = namespace
        self.targetKind = targetKind
        self.targetName = targetName
        self.localPort = localPort
        self.remotePort = remotePort
    }
}

public enum KubernetesPortForwardStatus: String, Codable, Sendable {
    case running
    case failed
}

public struct KubernetesPortForwardSession: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var contextName: String
    public var namespace: String
    public var targetKind: KubernetesPortForwardTargetKind
    public var targetName: String
    public var localPort: Int
    public var remotePort: Int
    public var startedAt: Date
    public var status: KubernetesPortForwardStatus
    public var diagnostic: KubernetesCommandDiagnostic?

    public var localURL: String {
        "http://127.0.0.1:\(localPort)"
    }
}

public protocol KubernetesPortForwarding: Sendable {
    func start(context: KubernetesContextProfile, request: KubernetesPortForwardRequest, onTerminate: (@Sendable (UUID) -> Void)?) async -> KubernetesPortForwardSession
    func stop(sessionID: UUID) async
    func stopAll() async
}

public actor KubernetesPortForwardService: KubernetesPortForwarding {
    private let kubectl: any KubectlCommandBuilding & KubectlProcessStarting
    private var processes: [UUID: any KubectlProcessHandling] = [:]

    public init(kubectl: any KubectlCommandBuilding & KubectlProcessStarting = KubectlRunner()) {
        self.kubectl = kubectl
    }

    public func start(context: KubernetesContextProfile, request: KubernetesPortForwardRequest, onTerminate: (@Sendable (UUID) -> Void)? = nil) async -> KubernetesPortForwardSession {
        let startedAt = Date()
        if let validationFailure = validate(context: context, request: request, startedAt: startedAt) {
            return validationFailure
        }
        return await startValidated(context: context, request: request, startedAt: startedAt, onTerminate: onTerminate)
    }

    public func stop(sessionID: UUID) async {
        processes.removeValue(forKey: sessionID)?.terminate()
    }

    public func stopAll() async {
        let handles = processes.values
        processes.removeAll()
        handles.forEach { $0.terminate() }
    }

    private func startValidated(context: KubernetesContextProfile, request: KubernetesPortForwardRequest, startedAt: Date, onTerminate: (@Sendable (UUID) -> Void)?) async -> KubernetesPortForwardSession {
        let id = UUID()
        do {
            var command = try kubectl.inspectionCommand(context: context.contextName, arguments: arguments(context: context, request: request))
            command.environmentOverrides = kubeconfigEnvironment(context)
            let process = try kubectl.start(command)
            if let onTerminate {
                process.setTerminationHandler {
                    onTerminate(id)
                }
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            if process.isRunning {
                processes[id] = process
                return session(id: id, context: context, request: request, startedAt: startedAt, status: .running, diagnostic: nil)
            }
            return session(
                id: id,
                context: context,
                request: request,
                startedAt: startedAt,
                status: .failed,
                diagnostic: diagnostic(context: context, request: request, message: process.outputIfExited(), startedAt: startedAt)
            )
        } catch {
            return session(
                id: id,
                context: context,
                request: request,
                startedAt: startedAt,
                status: .failed,
                diagnostic: diagnostic(context: context, request: request, message: error.localizedDescription, startedAt: startedAt)
            )
        }
    }

    private func validate(context: KubernetesContextProfile, request: KubernetesPortForwardRequest, startedAt: Date) -> KubernetesPortForwardSession? {
        let namespace = request.namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = request.targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.contextName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !namespace.isEmpty,
              !name.isEmpty,
              (1...65_535).contains(request.localPort),
              (1...65_535).contains(request.remotePort)
        else {
            return session(
                id: UUID(),
                context: context,
                request: request,
                startedAt: startedAt,
                status: .failed,
                diagnostic: diagnostic(context: context, request: request, message: "invalid port-forward target or port", startedAt: startedAt)
            )
        }
        return nil
    }

    private func arguments(context: KubernetesContextProfile, request: KubernetesPortForwardRequest) -> [String] {
        kubeconfigArguments(context) + [
            "port-forward",
            "\(request.targetKind.kubectlResource)/\(request.targetName)",
            "--namespace", request.namespace,
            "\(request.localPort):\(request.remotePort)",
            "--address", "127.0.0.1"
        ]
    }

    private func kubeconfigArguments(_ context: KubernetesContextProfile) -> [String] {
        context.kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : ["--kubeconfig", context.kubeconfigPath]
    }

    private func kubeconfigEnvironment(_ context: KubernetesContextProfile) -> [String: String] {
        let path = context.kubeconfigPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? [:] : ["KUBECONFIG": path]
    }

    private func session(
        id: UUID,
        context: KubernetesContextProfile,
        request: KubernetesPortForwardRequest,
        startedAt: Date,
        status: KubernetesPortForwardStatus,
        diagnostic: KubernetesCommandDiagnostic?
    ) -> KubernetesPortForwardSession {
        KubernetesPortForwardSession(
            id: id,
            contextName: context.contextName,
            namespace: request.namespace,
            targetKind: request.targetKind,
            targetName: request.targetName,
            localPort: request.localPort,
            remotePort: request.remotePort,
            startedAt: startedAt,
            status: status,
            diagnostic: diagnostic
        )
    }

    private func diagnostic(context: KubernetesContextProfile, request: KubernetesPortForwardRequest, message: String, startedAt: Date) -> KubernetesCommandDiagnostic {
        let result = KubectlResult(exitCode: 1, stdout: "", stderr: message)
        let category = KubernetesDiagnosticClassifier.category(from: result)
        return KubernetesCommandDiagnostic(
            commandKind: "Port Forward",
            contextName: context.contextName,
            kubeconfigPath: KubernetesDiagnosticClassifier.safeKubeconfigPath(context.kubeconfigPath),
            exitCode: 1,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1000)),
            category: category,
            stderrSummary: "\(request.targetKind.rawValue)/\(request.targetName) \(request.localPort):\(request.remotePort) \(KubernetesDiagnosticClassifier.sanitize(message))"
        )
    }
}
