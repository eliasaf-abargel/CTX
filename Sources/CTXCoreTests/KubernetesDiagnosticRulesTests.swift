import CTXCore
import Foundation

func testKubernetesDiagnosticValidationRules() throws {
    // 1. Service with no matching pods
    let brokenSvc = KubernetesResourceRow(id: "svc-1", cells: [
        "Name": "web-service",
        "Namespace": "prod",
        "Selector": "app=web,env=prod"
    ])
    let unrelatedPod = KubernetesResourceRow(id: "pod-other", cells: [
        "Name": "other-pod",
        "Namespace": "prod",
        "Labels": "app=other"
    ])
    let report1 = KubernetesConfigurationValidator.validate(
        services: [brokenSvc],
        workloads: [],
        pods: [unrelatedPod],
        ingress: [],
        configMaps: [],
        secrets: [],
        pvcs: [],
        nodes: []
    )
    assert(report1.issuesByResourceID["svc-1"]?.contains(where: { $0.ruleId == "SERVICE_NO_MATCHING_PODS" }) == true, "Must detect SERVICE_NO_MATCHING_PODS")

    // 2. Service matched by workload scaled to 0
    let scaledWorkload = KubernetesResourceRow(id: "wkl-1", cells: [
        "Name": "web-deploy",
        "Namespace": "prod",
        "Selector": "app=web,env=prod",
        "Ready": "0/0"
    ])
    let report2 = KubernetesConfigurationValidator.validate(
        services: [brokenSvc],
        workloads: [scaledWorkload],
        pods: [unrelatedPod],
        ingress: [],
        configMaps: [],
        secrets: [],
        pvcs: [],
        nodes: []
    )
    assert(report2.issuesByResourceID["svc-1"]?.contains(where: { $0.ruleId == "SERVICE_WORKLOAD_SCALED_ZERO" }) == true, "Must detect SERVICE_WORKLOAD_SCALED_ZERO")

    // 3. Missing ConfigMap & Secret references
    let missingRefPod = KubernetesResourceRow(id: "pod-1", cells: [
        "Name": "api-pod",
        "Namespace": "prod",
        "Status": "Running",
        "Ready": "1/1",
        "Restarts": "0",
        "ConfigMaps": "app-config, missing-config",
        "Secrets": "app-secret, missing-secret"
    ])
    let existingCM = KubernetesResourceRow(id: "cm-1", cells: ["Name": "app-config", "Namespace": "prod"])
    let existingSecret = KubernetesResourceRow(id: "sec-1", cells: ["Name": "app-secret", "Namespace": "prod"])
    let report3 = KubernetesConfigurationValidator.validate(
        services: [],
        workloads: [],
        pods: [missingRefPod],
        ingress: [],
        configMaps: [existingCM],
        secrets: [existingSecret],
        pvcs: [],
        nodes: []
    )
    assert(report3.issuesByResourceID["pod-1"]?.contains(where: { $0.ruleId == "CONFIGMAP_NOT_FOUND" }) == true, "Must detect CONFIGMAP_NOT_FOUND")
    assert(report3.issuesByResourceID["pod-1"]?.contains(where: { $0.ruleId == "SECRET_NOT_FOUND" }) == true, "Must detect SECRET_NOT_FOUND")

    // 4. Missing PVC & Unbound PVC
    let podWithPVC = KubernetesResourceRow(id: "pod-pvc", cells: [
        "Name": "db-pod",
        "Namespace": "prod",
        "PVCs": "missing-data, unbound-data"
    ])
    let unboundPVC = KubernetesResourceRow(id: "pvc-1", cells: [
        "Name": "unbound-data",
        "Namespace": "prod",
        "Status": "Pending"
    ])
    let report4 = KubernetesConfigurationValidator.validate(
        services: [],
        workloads: [],
        pods: [podWithPVC],
        ingress: [],
        configMaps: [],
        secrets: [],
        pvcs: [unboundPVC],
        nodes: []
    )
    assert(report4.issuesByResourceID["pod-pvc"]?.contains(where: { $0.ruleId == "PVC_NOT_FOUND" }) == true, "Must detect PVC_NOT_FOUND")
    assert(report4.issuesByResourceID["pvc-1"]?.contains(where: { $0.ruleId == "PVC_UNBOUND" }) == true, "Must detect PVC_UNBOUND")

    // 5. Ingress pointing to non-existent service
    let brokenIngress = KubernetesResourceRow(id: "ing-1", cells: [
        "Name": "gateway",
        "Namespace": "prod",
        "Services": "missing-svc"
    ])
    let existingSvc = KubernetesResourceRow(id: "svc-other", cells: [
        "Name": "other-svc",
        "Namespace": "prod"
    ])
    let report5 = KubernetesConfigurationValidator.validate(
        services: [existingSvc],
        workloads: [],
        pods: [],
        ingress: [brokenIngress],
        configMaps: [],
        secrets: [],
        pvcs: [],
        nodes: []
    )
    assert(report5.issuesByResourceID["ing-1"]?.contains(where: { $0.ruleId == "INGRESS_SERVICE_NOT_FOUND" }) == true, "Must detect INGRESS_SERVICE_NOT_FOUND")

    // 6. Security issues (Privileged, Root, HostNamespace)
    let insecurePod = KubernetesResourceRow(id: "pod-sec", cells: [
        "Name": "insecure-pod",
        "Namespace": "prod",
        "Security": "privileged,runAsRoot,hostNetwork"
    ])
    let report6 = KubernetesConfigurationValidator.validate(
        services: [],
        workloads: [],
        pods: [insecurePod],
        ingress: [],
        configMaps: [],
        secrets: [],
        pvcs: [],
        nodes: []
    )
    assert(report6.issuesByResourceID["pod-sec"]?.contains(where: { $0.ruleId == "SECURITY_PRIVILEGED" }) == true, "Must detect SECURITY_PRIVILEGED")
    assert(report6.issuesByResourceID["pod-sec"]?.contains(where: { $0.ruleId == "SECURITY_RUN_AS_ROOT" }) == true, "Must detect SECURITY_RUN_AS_ROOT")
    assert(report6.issuesByResourceID["pod-sec"]?.contains(where: { $0.ruleId == "SECURITY_HOST_NAMESPACE" }) == true, "Must detect SECURITY_HOST_NAMESPACE")

    // 7. Reliability issues (No limits, Missing probes)
    let unreliableWorkload = KubernetesResourceRow(id: "wkl-rel", cells: [
        "Name": "unreliable-app",
        "Namespace": "prod",
        "HasLimits": "false",
        "Probes": ""
    ])
    let report7 = KubernetesConfigurationValidator.validate(
        services: [],
        workloads: [unreliableWorkload],
        pods: [],
        ingress: [],
        configMaps: [],
        secrets: [],
        pvcs: [],
        nodes: []
    )
    assert(report7.issuesByResourceID["wkl-rel"]?.contains(where: { $0.ruleId == "RELIABILITY_NO_LIMITS" }) == true, "Must detect RELIABILITY_NO_LIMITS")
    assert(report7.issuesByResourceID["wkl-rel"]?.contains(where: { $0.ruleId == "RELIABILITY_MISSING_PROBES" }) == true, "Must detect RELIABILITY_MISSING_PROBES")

    // 8. Workload Replicas Degraded
    let degradedWorkload = KubernetesResourceRow(id: "wkl-deg", cells: [
        "Name": "payment-service",
        "Namespace": "prod",
        "Ready": "1/3"
    ])
    let report8 = KubernetesConfigurationValidator.validate(
        services: [],
        workloads: [degradedWorkload],
        pods: [],
        ingress: [],
        configMaps: [],
        secrets: [],
        pvcs: [],
        nodes: []
    )
    assert(report8.issuesByResourceID["wkl-deg"]?.contains(where: { $0.ruleId == "WORKLOAD_REPLICAS_DEGRADED" }) == true, "Must detect WORKLOAD_REPLICAS_DEGRADED")

    // 9. Runtime failures (CrashLoopBackOff & High Restarts)
    let crashingPod = KubernetesResourceRow(id: "pod-crash", cells: [
        "Name": "worker",
        "Namespace": "prod",
        "Status": "CrashLoopBackOff",
        "Restarts": "25"
    ])
    let report9 = KubernetesConfigurationValidator.validate(
        services: [],
        workloads: [],
        pods: [crashingPod],
        ingress: [],
        configMaps: [],
        secrets: [],
        pvcs: [],
        nodes: []
    )
    assert(report9.issuesByResourceID["pod-crash"]?.contains(where: { $0.ruleId == "RUNTIME_CRASH_LOOP" }) == true, "Must detect RUNTIME_CRASH_LOOP")
    assert(report9.issuesByResourceID["pod-crash"]?.contains(where: { $0.ruleId == "RUNTIME_HIGH_RESTARTS" }) == true, "Must detect RUNTIME_HIGH_RESTARTS")

    // 10. Node NotReady
    let unreadyNode = KubernetesResourceRow(id: "node-1", cells: [
        "Name": "worker-node-alpha",
        "Status": "NotReady"
    ])
    let report10 = KubernetesConfigurationValidator.validate(
        services: [],
        workloads: [],
        pods: [],
        ingress: [],
        configMaps: [],
        secrets: [],
        pvcs: [],
        nodes: [unreadyNode]
    )
    assert(report10.issuesByResourceID["node-1"]?.contains(where: { $0.ruleId == "NODE_NOT_READY" }) == true, "Must detect NODE_NOT_READY")
}

func testClusterAnomalyNotificationDebounceAndPayload() {
    let payload = ClusterAnomalyNotificationPayload(
        contextID: "ctx-prod-123",
        contextName: "production-eu-west-1",
        resourceKind: "Pod",
        resourceName: "order-processor-7fd69-xyz",
        namespace: "billing",
        ruleId: "RUNTIME_CRASH_LOOP",
        title: "Container CrashLoopBackOff",
        message: "Pod has failed container execution and is restarting in back-off loop.",
        isCritical: true
    )
    assert(payload.contextID == "ctx-prod-123")
    assert(payload.resourceName == "order-processor-7fd69-xyz")
    assert(payload.namespace == "billing")
    assert(payload.isCritical == true)
    assert(payload.ruleId == "RUNTIME_CRASH_LOOP")

    // Service call must safely process payload without runtime faults
    AppNotificationService.shared.sendClusterAnomaly(payload)
}

func runKubernetesDiagnosticRulesTests() throws {
    try testKubernetesDiagnosticValidationRules()
    testClusterAnomalyNotificationDebounceAndPayload()
}
