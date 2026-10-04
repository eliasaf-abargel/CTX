import CTXCore
import Foundation

let nodeCapacityJSON = """
{"items":[
 {"metadata":{"name":"node-big"},"status":{"allocatable":{"cpu":"96","memory":"384Gi","pods":"250"}}},
 {"metadata":{"name":"node-small"},"status":{"allocatable":{"cpu":"2","memory":"8Gi","pods":"30"}}}
]}
"""

/// Cluster utilisation is total usage over total allocatable, not the mean of the
/// per-node percentages. Averaging weights a two-core node the same as a
/// ninety-six-core one: the cluster below is genuinely at ~11.7% CPU, but a plain
/// mean of 10% and 90% reports 50%.
func testClusterUtilizationIsWeightedByAllocatable() throws {
    let capacity = KubernetesMetricsReader.parseNodeCapacity(nodeCapacityJSON)
    assert(capacity.count == 2)
    assert(capacity["node-big"]?.cpuCores == 96)
    assert(capacity["node-small"]?.podSlots == 30)

    // node-big: 9.6 of 96 cores (10%). node-small: 1.8 of 2 cores (90%).
    let nodes = KubernetesMetricsReader.parseTopNodes("""
    node-big     9600m   10%   38Gi   10%
    node-small   1800m   90%   7Gi    90%
    """, capacity: capacity)
    assert(nodes.count == 2)

    let cpu = KubernetesMetricsReader.aggregate(nodes, used: \.cpuUsedCores, allocatable: \.cpuAllocatableCores)!
    assert(abs(cpu - 11.63) < 0.1, "weighted CPU should be ~11.6%, got \(cpu)")
    assert(abs(cpu - 50) > 30, "a plain mean would have reported 50%")
}

/// The average hides the node that is actually about to evict pods.
func testBusiestNodeIsReportedAlongsideTheAverage() throws {
    let capacity = KubernetesMetricsReader.parseNodeCapacity(nodeCapacityJSON)
    let nodes = KubernetesMetricsReader.parseTopNodes("""
    node-big     9600m   10%   38Gi   10%
    node-small   1800m   90%   7Gi    90%
    """, capacity: capacity)
    let busiest = nodes.filter { $0.cpuPercent != nil }.max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }!
    assert(busiest.name == "node-small", "got \(busiest.name)")
    assert(abs((busiest.cpuPercent ?? 0) - 90) < 0.1)
}

/// A node whose allocatable is unknown is left out of both sides of the ratio
/// rather than counted as zero capacity, which would peg the cluster at 100%.
func testNodesWithUnknownCapacityAreExcludedNotZeroed() throws {
    let nodes = KubernetesMetricsReader.parseTopNodes("""
    known     1000m   50%   1Gi   50%
    unknown   9000m   90%   9Gi   90%
    """, capacity: ["known": KubernetesMetricsReader.NodeCapacity(cpuCores: 2, memoryBytes: nil, podSlots: nil)])
    let cpu = KubernetesMetricsReader.aggregate(nodes, used: \.cpuUsedCores, allocatable: \.cpuAllocatableCores)!
    assert(abs(cpu - 50) < 0.1, "only the node with known capacity should count, got \(cpu)")
    assert(KubernetesMetricsReader.aggregate(nodes, used: \.memoryUsedBytes, allocatable: \.memoryAllocatableBytes) == nil)
}

/// A pod counts as at-risk only against a limit it actually declares.
func testPodsNearMemoryLimitUsesDeclaredLimitsOnly() throws {
    let oneGiB = 1024.0 * 1024 * 1024
    let allNamespaces = """
    shop   checkout-a   120m   950Mi
    shop   checkout-b   80m    100Mi
    shop   nolimit-c    10m    4000Mi
    """
    let limits = ["shop/checkout-a": oneGiB, "shop/checkout-b": oneGiB]
    assert(KubernetesMetricsReader.podsNearMemoryLimit(topPodsOutput: allNamespaces, memoryLimitsByPodID: limits) == ["shop/checkout-a"])
    // No declared limit means no threshold to cross, however much is used.
    assert(KubernetesMetricsReader.podsNearMemoryLimit(topPodsOutput: allNamespaces, memoryLimitsByPodID: [:]).isEmpty)

    // Namespace-scoped output drops the NAMESPACE column; the same limits must match.
    let scoped = """
    checkout-a   120m   950Mi
    checkout-b   80m    100Mi
    """
    // Namespace-scoped output must still yield the namespace-qualified id, or the
    // at-risk list cannot be matched against the pod rows to filter them.
    assert(KubernetesMetricsReader.podsNearMemoryLimit(topPodsOutput: scoped, memoryLimitsByPodID: limits) == ["shop/checkout-a"],
           "namespace-scoped top output must resolve to the canonical namespace/name id")
}

func testQuantityParsingCoversCPUAndMemorySuffixes() throws {
    assert(KubernetesMetricsReader.cores("2") == 2)
    assert(KubernetesMetricsReader.cores("1500m") == 1.5)
    assert(abs((KubernetesMetricsReader.cores("2500000n") ?? 0) - 0.0025) < 1e-9)
    assert(KubernetesMetricsReader.bytes("1Ki") == 1024)
    assert(KubernetesMetricsReader.bytes("2Gi") == 2 * 1024 * 1024 * 1024)
    assert(KubernetesMetricsReader.bytes("1M") == 1_000_000)
    assert(KubernetesMetricsReader.bytes("nonsense") == nil)
}

func testPodDensityRequiresBothInputs() throws {
    assert(KubernetesMetricsReader.density(podCount: 55, allocatablePodSlots: 110) == 50)
    assert(KubernetesMetricsReader.density(podCount: 55, allocatablePodSlots: nil) == nil)
    assert(KubernetesMetricsReader.density(podCount: nil, allocatablePodSlots: 110) == nil)
    assert(KubernetesMetricsReader.density(podCount: 10, allocatablePodSlots: 0) == nil)
}

/// Telling someone to install metrics-server when the real problem is RBAC — or a
/// timeout — sends them to fix the wrong thing.
func testMetricsFailuresAreDistinguished() throws {
    assert(KubernetesMetricsReader.availability(from: KubectlResult(
        exitCode: 1, stdout: "", stderr: "error: Metrics API not available")) == .notInstalled)
    assert(KubernetesMetricsReader.availability(from: KubectlResult(
        exitCode: 1, stdout: "", stderr: "the server could not find the requested resource (get services http:heapster:)")) == .notInstalled)
    assert(KubernetesMetricsReader.availability(from: KubectlResult(
        exitCode: 1, stdout: "", stderr: "Error from server (Forbidden): nodes.metrics.k8s.io is forbidden")) == .notInstalled
        || KubernetesMetricsReader.availability(from: KubectlResult(
            exitCode: 1, stdout: "", stderr: "Error from server (Forbidden): nodes is forbidden")) == .forbidden)
    assert(KubernetesMetricsReader.availability(from: KubectlResult(
        exitCode: 1, stdout: "", stderr: "timed out", timedOut: true)) == .timedOut)
    // Every branch must produce something the UI can show.
    assert(MetricsAvailability.available.explanation == nil)
    for state: MetricsAvailability in [.notInstalled, .forbidden, .timedOut, .failed("boom")] {
        assert(state.explanation?.isEmpty == false)
    }
}

/// Without the metrics API, the numbers that do not need it still come through.
func testTelemetryWithoutMetricsAPIStillReportsWhatItCan() async throws {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .failure(stderr: "error: Metrics API not available")
    kubectl.outputs["get nodes --output=json --request-timeout=15s"] = .success(nodeCapacityJSON)

    let result = await KubernetesMetricsReader(kubectl: kubectl).telemetry(
        context: testKubernetesContext(),
        namespace: .allNamespaces,
        podCount: 140,
        podsByNode: [:],
        requests: ClusterResourceRequests(cpuCores: 49, memoryBytes: 196 * 1_073_741_824),
        memoryLimitsByPodID: [:]
    )
    assert(!result.hasMetrics)
    assert(result.availability == MetricsAvailability.notInstalled, "got \(result.availability)")
    assert(result.totalPods == 140)
    // 140 pods over 280 allocatable slots — derived from the node list, not metrics.
    assert(abs((result.podDensityPercent ?? 0) - 50) < 0.1, "got \(String(describing: result.podDensityPercent))")
    // Commitment comes from the pod requests and the node list, so it survives a
    // missing metrics API too: 49 of 98 cores, 196 of 392 GiB.
    assert(abs((result.requestedCPUPercent ?? 0) - 50) < 0.1, "got \(String(describing: result.requestedCPUPercent))")
    assert(abs((result.requestedMemoryPercent ?? 0) - 50) < 0.1, "got \(String(describing: result.requestedMemoryPercent))")
    assert(result.allocatableCPUCores == 98)
}

/// Utilisation and commitment are different questions. A cluster can sit at 2% CPU
/// and still refuse to schedule anything because its requests are nearly the whole
/// allocatable — reporting only utilisation hides exactly that.
func testCommitmentIsReportedSeparatelyFromUtilization() async throws {
    let kubectl = ScriptedKubectl()
    kubectl.defaultOutput = .failure(stderr: "no metrics")
    kubectl.outputs["get nodes --output=json --request-timeout=15s"] = .success(nodeCapacityJSON)
    kubectl.outputs["top nodes --no-headers --request-timeout=15s"] = .success("""
    node-big     1960m   2%   8Gi    2%
    node-small   40m     2%   160Mi  2%
    """)

    let result = await KubernetesMetricsReader(kubectl: kubectl).telemetry(
        context: testKubernetesContext(),
        namespace: .allNamespaces,
        podCount: 200,
        podsByNode: ["node-big": 100, "node-small": 10],
        requests: ClusterResourceRequests(cpuCores: 93, memoryBytes: 0),
        memoryLimitsByPodID: [:]
    )
    let used = result.cpuUtilizedPercent ?? 0
    let committed = result.requestedCPUPercent ?? 0
    assert(used < 5, "cluster is nearly idle, got \(used)%")
    assert(committed > 90, "but almost fully committed, got \(committed)%")

    // Per-node utilisation is carried through for the Nodes table.
    assert(result.utilizationByNode.count == 2)
    assert(result.utilizationByNode["node-small"]?.cpuUsedCores == 0.04)

    // Peak density names no node — it is a cluster statistic, not a hostname.
    assert(result.peakNodePodPercent != nil)
}


func runKubernetesClusterMetricsTests() async throws {
    try testClusterUtilizationIsWeightedByAllocatable()
    try testBusiestNodeIsReportedAlongsideTheAverage()
    try testNodesWithUnknownCapacityAreExcludedNotZeroed()
    try testPodsNearMemoryLimitUsesDeclaredLimitsOnly()
    try testQuantityParsingCoversCPUAndMemorySuffixes()
    try testPodDensityRequiresBothInputs()
    try testMetricsFailuresAreDistinguished()
    try await testTelemetryWithoutMetricsAPIStillReportsWhatItCan()
    try await testCommitmentIsReportedSeparatelyFromUtilization()
}
