import Foundation

/// Why live metrics are or aren't available, so the UI can say something true
/// instead of blaming a missing metrics-server for every failure.
public enum MetricsAvailability: Equatable, Sendable {
    case available
    /// The metrics API isn't registered — no metrics-server on this cluster.
    case notInstalled
    /// The metrics API is there but this identity may not read it.
    case forbidden
    case timedOut
    case failed(String)

    public var explanation: String? {
        switch self {
        case .available:
            nil
        case .notInstalled:
            "No metrics API on this cluster. Install metrics-server for live CPU and memory."
        case .forbidden:
            "Your identity cannot read the metrics API on this cluster."
        case .timedOut:
            "The metrics API did not respond in time."
        case .failed(let reason):
            "Live metrics unavailable: \(reason)"
        }
    }
}

/// One node's live utilisation against its own allocatable capacity.
public struct NodeUtilization: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let cpuUsedCores: Double
    public let memoryUsedBytes: Double
    public let cpuAllocatableCores: Double?
    public let memoryAllocatableBytes: Double?

    public init(
        name: String,
        cpuUsedCores: Double,
        memoryUsedBytes: Double,
        cpuAllocatableCores: Double? = nil,
        memoryAllocatableBytes: Double? = nil
    ) {
        self.name = name
        self.cpuUsedCores = cpuUsedCores
        self.memoryUsedBytes = memoryUsedBytes
        self.cpuAllocatableCores = cpuAllocatableCores
        self.memoryAllocatableBytes = memoryAllocatableBytes
    }

    public var cpuPercent: Double? {
        guard let allocatable = cpuAllocatableCores, allocatable > 0 else { return nil }
        return min(100, cpuUsedCores / allocatable * 100)
    }

    public var memoryPercent: Double? {
        guard let allocatable = memoryAllocatableBytes, allocatable > 0 else { return nil }
        return min(100, memoryUsedBytes / allocatable * 100)
    }
}

public struct ClusterTelemetryMetrics: Equatable, Sendable {
    /// Cluster CPU, as total usage over total allocatable.
    public var cpuUtilizedPercent: Double?
    public var memoryUtilizedPercent: Double?
    /// Scheduled pods against the sum of the nodes' allocatable pod slots.
    public var podDensityPercent: Double?
    public var totalNodes: Int?
    public var totalPods: Int?
    /// The node closest to saturation. A cluster averaging 40% can still have one
    /// node at 98% about to start evicting, and that node is the one worth seeing.
    public var busiestNodeByCPU: NodeUtilization?
    public var busiestNodeByMemory: NodeUtilization?
    /// Pods using at least 90% of a memory limit they actually declare.
    public var podsNearMemoryLimit: Int?
    /// What the scheduler has *committed* — the sum of pod requests over allocatable.
    ///
    /// Distinct from utilisation and often far higher: a cluster running at 3% CPU
    /// can still be 90% committed and unable to schedule anything. Reading only
    /// utilisation is how clusters end up unschedulable while every dashboard says
    /// they are idle.
    public var requestedCPUPercent: Double?
    public var requestedMemoryPercent: Double?
    /// Total schedulable capacity, for the "of what?" behind every percentage.
    public var allocatableCPUCores: Double?
    public var allocatableMemoryBytes: Double?
    public var availability: MetricsAvailability

    public init(
        cpuUtilizedPercent: Double? = nil,
        memoryUtilizedPercent: Double? = nil,
        podDensityPercent: Double? = nil,
        totalNodes: Int? = nil,
        totalPods: Int? = nil,
        busiestNodeByCPU: NodeUtilization? = nil,
        busiestNodeByMemory: NodeUtilization? = nil,
        podsNearMemoryLimit: Int? = nil,
        requestedCPUPercent: Double? = nil,
        requestedMemoryPercent: Double? = nil,
        allocatableCPUCores: Double? = nil,
        allocatableMemoryBytes: Double? = nil,
        availability: MetricsAvailability = .available
    ) {
        self.cpuUtilizedPercent = cpuUtilizedPercent
        self.memoryUtilizedPercent = memoryUtilizedPercent
        self.podDensityPercent = podDensityPercent
        self.totalNodes = totalNodes
        self.totalPods = totalPods
        self.busiestNodeByCPU = busiestNodeByCPU
        self.busiestNodeByMemory = busiestNodeByMemory
        self.podsNearMemoryLimit = podsNearMemoryLimit
        self.requestedCPUPercent = requestedCPUPercent
        self.requestedMemoryPercent = requestedMemoryPercent
        self.allocatableCPUCores = allocatableCPUCores
        self.allocatableMemoryBytes = allocatableMemoryBytes
        self.availability = availability
    }

    public var hasMetrics: Bool {
        cpuUtilizedPercent != nil || memoryUtilizedPercent != nil
    }

    /// Live utilisation per node, so the Nodes table can show what each one is
    /// actually doing rather than repeating its (identical) capacity on every row.
    public var utilizationByNode: [String: NodeUtilization] = [:]

    func withNodeUtilization(_ nodes: [NodeUtilization]) -> ClusterTelemetryMetrics {
        var copy = self
        copy.utilizationByNode = Dictionary(nodes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return copy
    }
}

public protocol KubernetesMetricsReading: Sendable {
    func telemetry(
        context: KubernetesContextProfile,
        namespace: KubernetesNamespaceSelection,
        podCount: Int?,
        requests: ClusterResourceRequests,
        memoryLimitsByPodID: [String: Double]
    ) async -> ClusterTelemetryMetrics
}

/// What the pods currently scheduled have asked the scheduler to reserve.
public struct ClusterResourceRequests: Equatable, Sendable {
    public let cpuCores: Double
    public let memoryBytes: Double

    public init(cpuCores: Double = 0, memoryBytes: Double = 0) {
        self.cpuCores = cpuCores
        self.memoryBytes = memoryBytes
    }
}

/// Reads live cluster utilisation.
///
/// Self-contained on purpose: it fetches the node list itself rather than reading
/// whatever the workspace happens to have loaded. Nodes are few and the read is
/// cheap, and the alternative — telemetry that silently shows nothing until some
/// other screen has finished loading — is the kind of thing that looks like a bug
/// on every cluster you connect to.
public final class KubernetesMetricsReader: KubernetesMetricsReading {
    private let kubectl: any KubectlRunning & KubectlCommandBuilding
    private let timeout: TimeInterval

    public init(
        kubectl: any KubectlRunning & KubectlCommandBuilding = KubectlRunner(),
        timeout: TimeInterval = 15
    ) {
        self.kubectl = kubectl
        self.timeout = timeout
    }

    public func telemetry(
        context: KubernetesContextProfile,
        namespace: KubernetesNamespaceSelection,
        podCount: Int?,
        requests: ClusterResourceRequests,
        memoryLimitsByPodID: [String: Double]
    ) async -> ClusterTelemetryMetrics {
        // All three reads overlap: none depends on another's result.
        async let topNodes = read(["top", "nodes", "--no-headers"], context: context)
        async let nodeSpecs = read(["get", "nodes", "--output=json"], context: context)
        async let topPods = read(["top", "pods", "--no-headers"] + namespace.commandArguments, context: context)
        let (topNodesResult, nodeSpecsResult, topPodsResult) = await (topNodes, nodeSpecs, topPods)

        let capacity = nodeSpecsResult.output.map(Self.parseNodeCapacity) ?? [:]
        let podSlots = capacity.values.compactMap(\.podSlots).reduce(0, +)
        let density = Self.density(podCount: podCount, allocatablePodSlots: podSlots > 0 ? podSlots : nil)
        let totalCPU = capacity.values.compactMap(\.cpuCores).reduce(0, +)
        let totalMemory = capacity.values.compactMap(\.memoryBytes).reduce(0, +)
        let requestedCPU = totalCPU > 0 ? min(100, requests.cpuCores / totalCPU * 100) : nil
        let requestedMemory = totalMemory > 0 ? min(100, requests.memoryBytes / totalMemory * 100) : nil

        guard let topOutput = topNodesResult.output else {
            return ClusterTelemetryMetrics(
                podDensityPercent: density,
                totalNodes: capacity.isEmpty ? nil : capacity.count,
                totalPods: podCount,
                requestedCPUPercent: requestedCPU,
                requestedMemoryPercent: requestedMemory,
                allocatableCPUCores: totalCPU > 0 ? totalCPU : nil,
                allocatableMemoryBytes: totalMemory > 0 ? totalMemory : nil,
                availability: topNodesResult.availability
            )
        }

        let nodes = Self.parseTopNodes(topOutput, capacity: capacity)
        return ClusterTelemetryMetrics(
            cpuUtilizedPercent: Self.aggregate(nodes, used: \.cpuUsedCores, allocatable: \.cpuAllocatableCores),
            memoryUtilizedPercent: Self.aggregate(nodes, used: \.memoryUsedBytes, allocatable: \.memoryAllocatableBytes),
            podDensityPercent: density,
            totalNodes: nodes.isEmpty ? nil : nodes.count,
            totalPods: podCount,
            busiestNodeByCPU: nodes.filter { $0.cpuPercent != nil }.max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) },
            busiestNodeByMemory: nodes.filter { $0.memoryPercent != nil }.max { ($0.memoryPercent ?? 0) < ($1.memoryPercent ?? 0) },
            podsNearMemoryLimit: topPodsResult.output.map {
                Self.podsNearMemoryLimit(topPodsOutput: $0, memoryLimitsByPodID: memoryLimitsByPodID)
            },
            requestedCPUPercent: requestedCPU,
            requestedMemoryPercent: requestedMemory,
            allocatableCPUCores: totalCPU > 0 ? totalCPU : nil,
            allocatableMemoryBytes: totalMemory > 0 ? totalMemory : nil,
            availability: .available
        )
        .withNodeUtilization(nodes)
    }

    // MARK: - Aggregation

    /// Total usage over total allocatable — *not* the mean of the per-node
    /// percentages, which weights a two-core node the same as a ninety-six-core one
    /// and can report 50% for a cluster genuinely sitting at 11%. Nodes whose
    /// allocatable is unknown are left out of both sides rather than counted as zero.
    public static func aggregate(
        _ nodes: [NodeUtilization],
        used: (NodeUtilization) -> Double,
        allocatable: (NodeUtilization) -> Double?
    ) -> Double? {
        var totalUsed: Double = 0
        var totalAllocatable: Double = 0
        for node in nodes {
            guard let capacity = allocatable(node), capacity > 0 else { continue }
            totalUsed += used(node)
            totalAllocatable += capacity
        }
        guard totalAllocatable > 0 else { return nil }
        return min(100, totalUsed / totalAllocatable * 100)
    }

    public static func density(podCount: Int?, allocatablePodSlots: Int?) -> Double? {
        guard let podCount, let allocatablePodSlots, allocatablePodSlots > 0 else { return nil }
        return min(100, Double(podCount) / Double(allocatablePodSlots) * 100)
    }

    // MARK: - Parsing

    public struct NodeCapacity: Equatable, Sendable {
        public let cpuCores: Double?
        public let memoryBytes: Double?
        public let podSlots: Int?

        public init(cpuCores: Double?, memoryBytes: Double?, podSlots: Int?) {
            self.cpuCores = cpuCores
            self.memoryBytes = memoryBytes
            self.podSlots = podSlots
        }
    }

    /// `status.allocatable` per node — what the scheduler can actually hand out,
    /// which is less than `capacity` once system reservations are taken off.
    public static func parseNodeCapacity(_ nodesJSON: String) -> [String: NodeCapacity] {
        guard
            let data = nodesJSON.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["items"] as? [[String: Any]]
        else { return [:] }

        var capacity: [String: NodeCapacity] = [:]
        for item in items {
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            guard let name = metadata["name"] as? String else { continue }
            let status = item["status"] as? [String: Any] ?? [:]
            let allocatable = (status["allocatable"] as? [String: Any]) ?? (status["capacity"] as? [String: Any]) ?? [:]
            capacity[name] = NodeCapacity(
                cpuCores: (allocatable["cpu"]).flatMap { cores(String(describing: $0)) },
                memoryBytes: (allocatable["memory"]).flatMap { bytes(String(describing: $0)) },
                podSlots: (allocatable["pods"]).flatMap { Int(String(describing: $0)) }
            )
        }
        return capacity
    }

    /// `kubectl top nodes` prints: NAME  CPU(cores)  CPU%  MEMORY(bytes)  MEMORY%
    ///
    /// The raw usage columns are used rather than the printed percentages: those are
    /// rounded to whole numbers, so at low utilisation they lose most of their
    /// precision, and they cannot be aggregated across nodes of different sizes.
    public static func parseTopNodes(_ stdout: String, capacity: [String: NodeCapacity]) -> [NodeUtilization] {
        stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 4 else { return nil }
            let name = fields[0]
            guard let cpu = cores(fields[1]), let memory = bytes(fields[3]) else { return nil }
            return NodeUtilization(
                name: name,
                cpuUsedCores: cpu,
                memoryUsedBytes: memory,
                cpuAllocatableCores: capacity[name]?.cpuCores,
                memoryAllocatableBytes: capacity[name]?.memoryBytes
            )
        }
    }

    /// `kubectl top pods` prints: NAME  CPU(cores)  MEMORY(bytes), and with
    /// `--all-namespaces` prefixes a NAMESPACE column.
    ///
    /// A pod counts only when it declares a memory limit *and* is using at least
    /// `threshold` of it. Pods without a limit are excluded — there is no line for
    /// them to cross.
    public static func podsNearMemoryLimit(
        topPodsOutput: String,
        memoryLimitsByPodID: [String: Double],
        threshold: Double = 0.9
    ) -> Int {
        var count = 0
        for line in topPodsOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let id: String
            let memoryField: Int
            switch fields.count {
            case 4...:
                id = "\(fields[0])/\(fields[1])"
                memoryField = 3
            case 3:
                // Namespace-scoped output has no NAMESPACE column; the limits map is
                // built from the same scope, so match on the bare name.
                id = fields[0]
                memoryField = 2
            default:
                continue
            }
            guard let limit = limit(for: id, in: memoryLimitsByPodID), limit > 0,
                  let used = bytes(fields[memoryField]) else { continue }
            if used / limit >= threshold { count += 1 }
        }
        return count
    }

    private static func limit(for id: String, in limits: [String: Double]) -> Double? {
        if let exact = limits[id] { return exact }
        // Bare pod name against namespace-qualified keys.
        guard !id.contains("/") else { return nil }
        return limits.first { $0.key.hasSuffix("/\(id)") }?.value
    }

    // MARK: - Quantities

    /// Kubernetes CPU quantities: whole cores, `m` millicores, `u` micro, `n` nano.
    public static func cores(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        for (suffix, divisor) in [("m", 1_000.0), ("u", 1_000_000.0), ("n", 1_000_000_000.0)] where value.hasSuffix(suffix) {
            guard let number = Double(value.dropLast(suffix.count)) else { return nil }
            return number / divisor
        }
        return Double(value)
    }

    /// Kubernetes memory quantities, binary or decimal suffixed.
    public static func bytes(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let suffixes: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1_048_576), ("Gi", 1_073_741_824), ("Ti", 1_099_511_627_776),
            ("K", 1_000), ("M", 1_000_000), ("G", 1_000_000_000), ("T", 1_000_000_000_000)
        ]
        for (suffix, multiplier) in suffixes where value.hasSuffix(suffix) {
            guard let number = Double(value.dropLast(suffix.count)) else { return nil }
            return number * multiplier
        }
        return Double(value)
    }

    // MARK: - Reading

    private struct ReadResult {
        let output: String?
        let availability: MetricsAvailability
    }

    private func read(_ arguments: [String], context: KubernetesContextProfile) async -> ReadResult {
        do {
            var command = try kubectl.inspectionCommand(
                context: context.contextName,
                arguments: context.kubeconfigArguments + arguments + ["--request-timeout=\(Int(timeout))s"]
            )
            command.environmentOverrides = context.kubeconfigEnvironment
            let result = try await kubectl.run(command, timeout: timeout)
            if result.exitCode == 0 {
                return ReadResult(output: result.stdout, availability: .available)
            }
            return ReadResult(output: nil, availability: Self.availability(from: result))
        } catch KubectlRunnerError.kubectlNotFound {
            return ReadResult(output: nil, availability: .failed("kubectl was not found"))
        } catch {
            return ReadResult(output: nil, availability: .failed(KubernetesDiagnosticClassifier.sanitize(error.localizedDescription)))
        }
    }

    /// A failed `kubectl top` has three meaningfully different causes, and telling
    /// the user to install metrics-server when the real problem is RBAC — or a
    /// timeout — sends them to fix the wrong thing.
    public static func availability(from result: KubectlResult) -> MetricsAvailability {
        if result.timedOut { return .timedOut }
        let stderr = result.stderr.lowercased()
        if stderr.contains("metrics api not available")
            || stderr.contains("metrics.k8s.io")
            || stderr.contains("the server could not find the requested resource") {
            return .notInstalled
        }
        switch KubernetesDiagnosticClassifier.category(from: result) {
        case .timeout: return .timedOut
        case .forbidden: return .forbidden
        default: return .failed(KubernetesDiagnosticClassifier.sanitize(result.stderr))
        }
    }
}
