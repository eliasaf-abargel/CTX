import CTXCore
import Foundation

func testPodEnvExposesReferencesButNeverSecretValues() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: realPodJSON)!
    let app = spec.containers.first { $0.name == "app" }!

    let literal = app.env.first { $0.name == "APP_ENV" }!
    assert(literal.value == "production" && literal.source.isEmpty)
    assert(!literal.isSecret)

    let secret = app.env.first { $0.name == "DB_PASSWORD" }!
    assert(secret.isSecret)
    assert(secret.value.isEmpty, "a Secret-backed value must never be materialised")
    assert(secret.source == "Secret db-creds/password", "got \(secret.source)")

    let configMap = app.env.first { $0.name == "FEATURE_FLAGS" }!
    assert(configMap.source == "ConfigMap checkout-config/flags" && !configMap.isSecret)

    let field = app.env.first { $0.name == "POD_IP" }!
    assert(field.source == "field status.podIP")

    // envFrom pulls in every key at once; only the reference is knowable.
    let bulk = app.env.first { $0.source == "Secret shared-secrets" }!
    assert(bulk.isSecret && bulk.value.isEmpty)

    // Nothing anywhere carries a materialised secret value.
    assert(!app.env.contains { $0.isSecret && !$0.value.isEmpty })
}

func testPodProbesReportRealTargetsAndAbsence() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: realPodJSON)!
    let app = spec.containers.first { $0.name == "app" }!

    let liveness = app.probes.first { $0.type == "Liveness" }!
    assert(liveness.isConfigured)
    assert(liveness.target == "HTTPS GET /healthz:9090", "got \(liveness.target)")
    assert(liveness.delaySeconds == 15 && liveness.periodSeconds == 20)

    // A named port must survive as its name, not be coerced to a number.
    let readiness = app.probes.first { $0.type == "Readiness" }!
    assert(readiness.target == "TCP :http", "got \(readiness.target)")

    // An unset probe is a real finding, not a value to invent.
    let startup = app.probes.first { $0.type == "Startup" }!
    assert(!startup.isConfigured)
}

/// Container-level security context wins; anything it leaves unset falls back to
/// the pod-level one, which is how the kubelet resolves it.
func testPodSecurityContextMergesContainerOverPodLevel() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: realPodJSON)!
    let app = spec.containers.first { $0.name == "app" }!
    assert(app.security.runAsUser == "1000", "pod-level runAsUser should apply, got \(app.security.runAsUser)")
    assert(!app.security.isRoot)
    assert(app.security.isPrivileged, "container-level privileged must be honoured")
    assert(app.security.isReadOnlyRootFS)
    assert(app.security.addedCapabilities == ["NET_ADMIN"])
}

/// An unset security context is unknown, not "safe" — and UID 0 is root.
func testPodSecurityContextDoesNotAssumeSafetyWhenUnset() throws {
    let bare = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: """
    {"spec":{"containers":[{"name":"c","image":"i"}]}}
    """)!.containers[0]
    assert(bare.security.runAsUser == KubernetesGitOpsService.unknownValue)
    assert(!bare.security.isRoot && !bare.security.isPrivileged)

    let rootPod = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: """
    {"spec":{"containers":[{"name":"c","image":"i","securityContext":{"runAsUser":0}}]}}
    """)!.containers[0]
    assert(rootPod.security.isRoot, "UID 0 must be reported as root")
}

/// An absent limit stays absent — that is the finding (the container can consume
/// the whole node), not a blank to fill with a plausible number.
func testPodResourcesKeepUnsetLimitsUnset() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: realPodJSON)!
    let app = spec.containers.first { $0.name == "app" }!
    assert(app.resources.cpuRequest == "250m")
    assert(app.resources.memoryRequest == "512Mi")
    assert(app.resources.memoryLimit == "1Gi")
    assert(app.resources.cpuLimit == nil, "an unset CPU limit must not be invented")
}

func testPodSpecIncludesInitContainersAndIdentity() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: realPodJSON)!
    assert(spec.containers.count == 2)
    assert(spec.containers[0].isInitContainer && spec.containers[0].name == "migrate")
    assert(!spec.containers[1].isInitContainer)
    assert(spec.serviceAccount == "checkout-sa")
    assert(spec.nodeName == "node-worker-a")
}

/// Not-ready backends are exactly what someone debugging "the service is up but
/// nothing answers" needs to see, so they are kept and flagged rather than hidden.
func testServiceEndpointsReportReadyAndNotReadyBackends() throws {
    let targets = KubernetesWorkloadSpecParser.endpoints(fromEndpointsJSON: """
    {"metadata":{"name":"checkout","namespace":"shop"},
     "subsets":[{"ports":[{"port":8080,"name":"http"}],
                 "addresses":[{"ip":"10.1.2.3","targetRef":{"name":"checkout-a","namespace":"shop"}}],
                 "notReadyAddresses":[{"ip":"10.1.2.4","targetRef":{"name":"checkout-b","namespace":"shop"}}]}]}
    """)
    assert(targets.count == 2)
    let ready = targets.first { $0.name == "checkout-a" }!
    assert(ready.isHealthy && ready.address == "10.1.2.3" && ready.targetPort == "8080/http")
    let notReady = targets.first { $0.name == "checkout-b" }!
    assert(!notReady.isHealthy, "a not-ready backend must not be reported as healthy")

    // A Service with no backends at all yields nothing — not two invented pods.
    assert(KubernetesWorkloadSpecParser.endpoints(fromEndpointsJSON: #"{"metadata":{},"subsets":[]}"#).isEmpty)
}

func testNodeCapacityComesFromTheNodeObject() throws {
    let node: [String: Any] = [
        "status": ["capacity": ["cpu": "8", "memory": "32Gi", "pods": "110"],
                   "allocatable": ["cpu": "7910m", "memory": "30Gi", "pods": "110"]]
    ]
    let capacity = KubernetesWorkloadSpecParser.nodeCapacity(fromNodeObject: node)!
    // Allocatable is what can actually be scheduled, so it wins over raw capacity.
    assert(capacity.cpu == "7910m", "got \(capacity.cpu)")
    assert(capacity.memory == "30Gi")
    assert(capacity.pods == "110")
}


func testEnvVarIdentityStaysUniqueAcrossBulkReferences() throws {
    let spec = KubernetesWorkloadSpecParser.podSpec(fromPodJSON: """
    {"spec":{"containers":[{"name":"app","image":"i","envFrom":[
      {"secretRef":{"name":"shared-secrets"}},
      {"secretRef":{"name":"extra-secrets"}},
      {"configMapRef":{"name":"app-config"}}]}]}}
    """)!
    let env = spec.containers[0].env
    assert(env.count == 3)
    assert(Set(env.map(\.id)).count == 3, "duplicate identifiers: \(env.map(\.id))")
    assert(env.filter(\.isSecret).count == 2)
    assert(!env.contains { !$0.value.isEmpty }, "bulk references have no readable value")
}


func runKubernetesResourceInspectionTests() throws {
    try testPodEnvExposesReferencesButNeverSecretValues()
    try testPodProbesReportRealTargetsAndAbsence()
    try testPodSecurityContextMergesContainerOverPodLevel()
    try testPodSecurityContextDoesNotAssumeSafetyWhenUnset()
    try testPodResourcesKeepUnsetLimitsUnset()
    try testPodSpecIncludesInitContainersAndIdentity()
    try testServiceEndpointsReportReadyAndNotReadyBackends()
    try testNodeCapacityComesFromTheNodeObject()
    try testEnvVarIdentityStaysUniqueAcrossBulkReferences()
}
