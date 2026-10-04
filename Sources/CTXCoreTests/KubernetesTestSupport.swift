import CTXCore
import Foundation

actor CountingResourceReader: KubernetesResourceReading {
    private(set) var callCount = 0
    private(set) var calls: [(contextID: String, namespace: String, kind: KubernetesResourceKind)] = []
    private var resultProvider: (KubernetesResourceKind, KubernetesNamespaceSelection) -> KubernetesResourceList = { kind, _ in
        KubernetesResourceList(kind: kind, columns: [], rows: [], status: .reachable)
    }
    private var delayNanoseconds: UInt64 = 0
    private var holdUntilReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func setDelayNanoseconds(_ value: UInt64) {
        delayNanoseconds = value
    }

    func setResultProvider(_ provider: @escaping (KubernetesResourceKind, KubernetesNamespaceSelection) -> KubernetesResourceList) {
        resultProvider = provider
    }

    /// Makes `list(...)` block right after recording the call, until `release()` is
    /// called — so a test can deterministically act while a fetch is in-flight
    /// instead of racing a fixed `Task.sleep` against actor/thread-pool scheduling.
    func setHoldUntilReleased(_ value: Bool) {
        holdUntilReleased = value
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func list(kind: KubernetesResourceKind, context: KubernetesContextProfile, namespace: KubernetesNamespaceSelection) async -> KubernetesResourceList {
        callCount += 1
        calls.append((context.id, namespace.storageValue, kind))
        if holdUntilReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        let delay = delayNanoseconds
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        return resultProvider(kind, namespace)
    }
}

actor RecordingCloudRunner: CloudCommandRunning {
    private var commands: [[String]] = []
    private var environmentOverrides: [[String: String]] = []
    private var defaultResult = CommandResult(exitCode: 0, output: "")

    func setDefault(_ result: CommandResult) {
        defaultResult = result
    }

    func allCommands() -> [[String]] {
        commands
    }

    func allEnvironmentOverrides() -> [[String: String]] {
        environmentOverrides
    }

    func run(
        _ arguments: [String],
        environmentOverrides: [String: String],
        timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)?
    ) async -> CommandResult {
        commands.append(arguments)
        self.environmentOverrides.append(environmentOverrides)
        return defaultResult
    }
}

final class ScriptedKubectl: KubectlRunning, KubectlCommandBuilding, KubectlConfigurationCommandBuilding, KubectlProcessStarting, @unchecked Sendable {
    enum Output {
        case success(String)
        case failure(stderr: String)
        case timeout
        case timeoutWithStdout(String)
    }

    var commands: [KubectlCommand] = []
    var startedCommands: [KubectlCommand] = []
    var outputs: [String: Output] = [:]
    var defaultOutput: Output = .success(emptyItems())
    var error: Error?
    var processToStart: FakeKubectlProcess = FakeKubectlProcess()
    var onRun: ((KubectlCommand) -> Void)?
    /// Scripts a reply from the whole command rather than the flag-stripped key
    /// `outputs` is indexed by — needed when what matters is the verb (`unset`,
    /// `set-credentials`) rather than the arguments around it. Returning `nil`
    /// falls through to `outputs`/`defaultOutput`.
    var outputForCommand: ((KubectlCommand) -> Output?)?
    /// Simulates a real subprocess taking measurable time — needed to create a
    /// window in which a caller can be cancelled mid-flight, or to prove a
    /// genuinely-fast command isn't held up by anything on CTX's side.
    var delayNanoseconds: UInt64 = 0
    private let queue = DispatchQueue(label: "ctx.tests.scripted-kubectl")

    func inspectionCommand(context: String, arguments: [String]) throws -> KubectlCommand {
        if let error { throw error }
        return KubectlCommand(executablePath: "/mock/kubectl", arguments: ["--context", context] + arguments)
    }

    func configurationCommand(arguments: [String]) throws -> KubectlCommand {
        if let error { throw error }
        return KubectlCommand(executablePath: "/mock/kubectl", arguments: arguments)
    }

    func run(_ command: KubectlCommand, timeout: TimeInterval) async throws -> KubectlResult {
        let key = command.arguments.dropFirst(2).filter { $0 != "--kubeconfig" && !$0.hasPrefix("/") }.joined(separator: " ")
        let output = queue.sync { () -> Output in
            commands.append(command)
            onRun?(command)
            return outputForCommand?(command) ?? outputs[key] ?? defaultOutput
        }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        switch output {
        case .success(let stdout):
            return KubectlResult(exitCode: 0, stdout: stdout, stderr: "")
        case .failure(let stderr):
            return KubectlResult(exitCode: 1, stdout: "", stderr: stderr)
        case .timeout:
            return KubectlResult(exitCode: 1, stdout: "", stderr: "timed out", timedOut: true)
        case .timeoutWithStdout(let stdout):
            return KubectlResult(exitCode: 1, stdout: stdout, stderr: "timed out", timedOut: true)
        }
    }

    func start(_ command: KubectlCommand) throws -> any KubectlProcessHandling {
        if let error { throw error }
        queue.sync {
            startedCommands.append(command)
        }
        return processToStart
    }
}

final class FakeKubectlProcess: KubectlProcessHandling, @unchecked Sendable {
    var running = true
    var terminated = false
    var output = ""

    private var terminationHandler: (@Sendable () -> Void)?

    var isRunning: Bool {
        running && !terminated
    }

    func terminate() {
        terminated = true
        terminationHandler?()
    }

    func outputIfExited() -> String {
        output
    }

    func setTerminationHandler(_ handler: @Sendable @escaping () -> Void) {
        terminationHandler = handler
        if !isRunning {
            handler()
        }
    }
}

func testKubernetesContext() -> KubernetesContextProfile {
    KubernetesContextProfile(
        contextName: "prod-context",
        clusterName: "prod-cluster",
        userName: "prod-user",
        namespace: "platform",
        kubeconfigPath: "/tmp/kubeconfig",
        providerType: .eks,
        environmentDetection: EnvironmentDetectionResult(type: .production, confidence: 1, source: "test"),
        isCurrent: true
    )
}

func emptyItems() -> String {
    #"{"items":[]}"#
}

func items(_ values: [[String: Any]]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["items": values])
    return String(decoding: data, as: UTF8.self)
}

func textFiles(under url: URL) throws -> [URL] {
    if url.pathExtension == "md" || url.pathExtension == "swift" {
        return [url]
    }
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }
    return try enumerator.compactMap { item in
        guard let file = item as? URL else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { return nil }
        return file.pathExtension == "swift" || file.pathExtension == "md" ? file : nil
    }
}

func kubeconfig(
    context: String,
    cluster: String,
    user: String,
    namespace: String = "",
    server: String
) -> String {
    """
    apiVersion: v1
    kind: Config
    current-context: \(context)
    clusters:
    - name: \(cluster)
      cluster:
        server: \(server)
    contexts:
    - name: \(context)
      context:
        cluster: \(cluster)
        user: \(user)
    \(namespace.isEmpty ? "" : "    namespace: \(namespace)")
    users:
    - name: \(user)
      user: {}
    """
}


final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func fire() {
        lock.lock(); stored += 1; lock.unlock()
    }
}

// MARK: - Pod spec is read from the object, never guessed from its name

let realPodJSON = """
{"metadata":{"name":"checkout-7d9f","namespace":"shop"},
 "spec":{
   "serviceAccountName":"checkout-sa","nodeName":"node-worker-a",
   "securityContext":{"runAsUser":1000,"runAsNonRoot":true},
   "initContainers":[{"name":"migrate","image":"registry.example.com/migrate:2.1"}],
   "containers":[{
     "name":"app","image":"registry.example.com/checkout:1.4.2",
     "env":[
       {"name":"APP_ENV","value":"production"},
       {"name":"DB_PASSWORD","valueFrom":{"secretKeyRef":{"name":"db-creds","key":"password"}}},
       {"name":"FEATURE_FLAGS","valueFrom":{"configMapKeyRef":{"name":"checkout-config","key":"flags"}}},
       {"name":"POD_IP","valueFrom":{"fieldRef":{"fieldPath":"status.podIP"}}}],
     "envFrom":[{"secretRef":{"name":"shared-secrets"}}],
     "livenessProbe":{"httpGet":{"path":"/healthz","port":9090,"scheme":"HTTPS"},
                      "initialDelaySeconds":15,"periodSeconds":20},
     "readinessProbe":{"tcpSocket":{"port":"http"},"initialDelaySeconds":3,"periodSeconds":5},
     "securityContext":{"privileged":true,"readOnlyRootFilesystem":true,
                        "capabilities":{"add":["NET_ADMIN"]}},
     "resources":{"requests":{"cpu":"250m","memory":"512Mi"},"limits":{"memory":"1Gi"}}}]}}
"""
