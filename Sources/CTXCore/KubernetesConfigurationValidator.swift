import Foundation

public struct KubernetesConfigurationValidator: Sendable {
    public init() {}

    public static func validate(batch: [KubernetesResourceKind: KubernetesResourceList]) -> KubernetesDiagnosticReport {
        validate(
            services: batch[.services]?.rows ?? [],
            workloads: batch[.workloads]?.rows ?? [],
            pods: batch[.pods]?.rows ?? [],
            ingress: batch[.ingress]?.rows ?? [],
            configMaps: batch[.configMaps]?.rows ?? [],
            secrets: batch[.secretMetadata]?.rows ?? [],
            pvcs: batch[.pvc]?.rows ?? [],
            nodes: batch[.nodes]?.rows ?? []
        )
    }

    public static func validate(
        services: [KubernetesResourceRow] = [],
        workloads: [KubernetesResourceRow] = [],
        pods: [KubernetesResourceRow] = [],
        ingress: [KubernetesResourceRow] = [],
        configMaps: [KubernetesResourceRow] = [],
        secrets: [KubernetesResourceRow] = [],
        pvcs: [KubernetesResourceRow] = [],
        nodes: [KubernetesResourceRow] = []
    ) -> KubernetesDiagnosticReport {
        var issuesByResource: [String: [ResourceDiagnosticIssue]] = [:]

        func addIssue(_ issue: ResourceDiagnosticIssue) {
            issuesByResource[issue.resourceID, default: []].append(issue)
        }

        // Pre-index collections by namespace for sub-millisecond lookup
        let podsByNamespace = Dictionary(grouping: pods, by: { $0.namespace ?? "default" })
        let workloadsByNamespace = Dictionary(grouping: workloads, by: { $0.namespace ?? "default" })
        let servicesByNamespace = Dictionary(grouping: services, by: { $0.namespace ?? "default" })
        let configMapsByNamespace = Dictionary(grouping: configMaps, by: { $0.namespace ?? "default" })
        let secretsByNamespace = Dictionary(grouping: secrets, by: { $0.namespace ?? "default" })
        let pvcsByNamespace = Dictionary(grouping: pvcs, by: { $0.namespace ?? "default" })

        // 1. Service Selector & Endpoints validation
        for svc in services {
            let ns = svc.namespace ?? "default"
            let selectorStr = svc.cells["Selector"] ?? ""
            guard !selectorStr.isEmpty else { continue }

            let selectorPairs = parsePairs(selectorStr)
            guard !selectorPairs.isEmpty else { continue }

            let nsPods = podsByNamespace[ns] ?? []
            let matchingPods = nsPods.filter { pod in
                let podLabels = parsePairs(pod.cells["Labels"] ?? "")
                return selectorPairs.allSatisfy { k, v in podLabels[k] == v }
            }

            if matchingPods.isEmpty && !nsPods.isEmpty {
                // Check if there is a workload with matching selector
                let nsWorkloads = workloadsByNamespace[ns] ?? []
                let matchingWorkload = nsWorkloads.first { wl in
                    let wlLabels = parsePairs(wl.cells["Selector"] ?? "")
                    return selectorPairs.allSatisfy { k, v in wlLabels[k] == v }
                }

                if let wl = matchingWorkload, wl.cells["Ready"]?.hasPrefix("0/") == true {
                    addIssue(ResourceDiagnosticIssue(
                        resourceID: svc.id,
                        resourceName: svc.name,
                        resourceNamespace: svc.namespace,
                        resourceKind: .services,
                        severity: .info,
                        category: .configuration,
                        ruleId: "SERVICE_WORKLOAD_SCALED_ZERO",
                        title: "Workload Scaled to Zero",
                        message: "Service '\(svc.name)' selector matches workload '\(wl.name)' which is currently scaled to 0 replicas.",
                        recommendation: "Scale up workload '\(wl.name)' if you want this Service to route traffic."
                    ))
                } else {
                    addIssue(ResourceDiagnosticIssue(
                        resourceID: svc.id,
                        resourceName: svc.name,
                        resourceNamespace: svc.namespace,
                        resourceKind: .services,
                        severity: .error,
                        category: .configuration,
                        ruleId: "SERVICE_NO_MATCHING_PODS",
                        title: "No Matching Pods for Service",
                        message: "Service selector '\(selectorStr)' matches 0 active pods in namespace '\(ns)'.",
                        recommendation: "Ensure pod manifests specify labels that match the Service selector: '\(selectorStr)'."
                    ))
                }
            }
        }

        // 2. Ingress Backend Service validation
        for ing in ingress {
            let ns = ing.namespace ?? "default"
            let svcNamesStr = ing.cells["Services"] ?? ""
            let referencedSvcs = svcNamesStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let nsServices = Set((servicesByNamespace[ns] ?? []).map(\.name))

            if !nsServices.isEmpty {
                for svcName in referencedSvcs {
                    if !nsServices.contains(svcName) {
                        addIssue(ResourceDiagnosticIssue(
                            resourceID: ing.id,
                            resourceName: ing.name,
                            resourceNamespace: ing.namespace,
                            resourceKind: .ingress,
                            severity: .error,
                            category: .configuration,
                            ruleId: "INGRESS_SERVICE_NOT_FOUND",
                            title: "Backend Service Not Found",
                            message: "Ingress points to service '\(svcName)' which does not exist in namespace '\(ns)'.",
                            recommendation: "Deploy Service '\(svcName)' or update the Ingress backend configuration."
                        ))
                    }
                }
            }
        }

        // 3. Pod Validations (Missing ConfigMaps, Secrets, PVCs, Security, Probes, Limits, CrashLoop)
        for pod in pods {
            let ns = pod.namespace ?? "default"

            // Missing ConfigMaps
            if let cmStr = pod.cells["ConfigMaps"], !cmStr.isEmpty {
                let nsCMs = Set((configMapsByNamespace[ns] ?? []).map(\.name))
                if !nsCMs.isEmpty {
                    let cms = cmStr.split(separator: ",").map(String.init)
                    for cm in cms where !nsCMs.contains(cm) {
                        addIssue(ResourceDiagnosticIssue(
                            resourceID: pod.id,
                            resourceName: pod.name,
                            resourceNamespace: pod.namespace,
                            resourceKind: .pods,
                            severity: .error,
                            category: .configuration,
                            ruleId: "CONFIGMAP_NOT_FOUND",
                            title: "Missing ConfigMap Reference",
                            message: "Pod references ConfigMap '\(cm)' which was not found in namespace '\(ns)'.",
                            recommendation: "Create ConfigMap '\(cm)' or verify spelling in pod volumes and environment variables."
                        ))
                    }
                }
            }

            // Missing Secrets
            if let secStr = pod.cells["Secrets"], !secStr.isEmpty {
                let nsSecs = Set((secretsByNamespace[ns] ?? []).map(\.name))
                if !nsSecs.isEmpty {
                    let secs = secStr.split(separator: ",").map(String.init)
                    for sec in secs where !nsSecs.contains(sec) {
                        addIssue(ResourceDiagnosticIssue(
                            resourceID: pod.id,
                            resourceName: pod.name,
                            resourceNamespace: pod.namespace,
                            resourceKind: .pods,
                            severity: .error,
                            category: .configuration,
                            ruleId: "SECRET_NOT_FOUND",
                            title: "Missing Secret Reference",
                            message: "Pod references Secret '\(sec)' which was not found in namespace '\(ns)'.",
                            recommendation: "Deploy Secret '\(sec)' before starting the pod."
                        ))
                    }
                }
            }

            // Missing PVCs
            if let pvcStr = pod.cells["PVCs"], !pvcStr.isEmpty {
                let nsPVCs = Set((pvcsByNamespace[ns] ?? []).map(\.name))
                if !nsPVCs.isEmpty {
                    let claims = pvcStr.split(separator: ",").map(String.init)
                    for claim in claims where !nsPVCs.contains(claim) {
                        addIssue(ResourceDiagnosticIssue(
                            resourceID: pod.id,
                            resourceName: pod.name,
                            resourceNamespace: pod.namespace,
                            resourceKind: .pods,
                            severity: .error,
                            category: .configuration,
                            ruleId: "PVC_NOT_FOUND",
                            title: "Missing PVC Reference",
                            message: "Pod mounts PersistentVolumeClaim '\(claim)' which does not exist in namespace '\(ns)'.",
                            recommendation: "Create PersistentVolumeClaim '\(claim)' to allow volume mounting."
                        ))
                    }
                }
            }

            // Security checks
            let secFlags = Set((pod.cells["Security"] ?? "").split(separator: ",").map(String.init))
            if secFlags.contains("privileged") {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: pod.id,
                    resourceName: pod.name,
                    resourceNamespace: pod.namespace,
                    resourceKind: .pods,
                    severity: .warning,
                    category: .security,
                    ruleId: "SECURITY_PRIVILEGED",
                    title: "Privileged Container",
                    message: "Pod runs in privileged mode, granting unrestricted root capabilities on the host.",
                    recommendation: "Disable privileged mode and grant only the specific Linux capabilities needed."
                ))
            }
            if secFlags.contains("runAsRoot") {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: pod.id,
                    resourceName: pod.name,
                    resourceNamespace: pod.namespace,
                    resourceKind: .pods,
                    severity: .warning,
                    category: .security,
                    ruleId: "SECURITY_RUN_AS_ROOT",
                    title: "Running as Root",
                    message: "Container allows root user execution without runAsNonRoot enforcement.",
                    recommendation: "Set securityContext.runAsNonRoot: true and specify a non-zero runAsUser."
                ))
            }
            if secFlags.contains("hostNetwork") || secFlags.contains("hostPID") {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: pod.id,
                    resourceName: pod.name,
                    resourceNamespace: pod.namespace,
                    resourceKind: .pods,
                    severity: .warning,
                    category: .security,
                    ruleId: "SECURITY_HOST_NAMESPACE",
                    title: "Host Namespace Shared",
                    message: "Pod shares host network or PID namespace with the node.",
                    recommendation: "Avoid hostNetwork and hostPID in application pods."
                ))
            }

            // Reliability: Memory limits
            if pod.cells["HasLimits"] == "false" {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: pod.id,
                    resourceName: pod.name,
                    resourceNamespace: pod.namespace,
                    resourceKind: .pods,
                    severity: .warning,
                    category: .reliability,
                    ruleId: "RELIABILITY_NO_LIMITS",
                    title: "Missing Memory Limits",
                    message: "Pod has no memory limits configured, risking node memory exhaustion and OOM kills.",
                    recommendation: "Define resources.limits.memory for all containers."
                ))
            }

            // Reliability: Probes
            let probeFlags = Set((pod.cells["Probes"] ?? "").split(separator: ",").map(String.init))
            if !probeFlags.contains("liveness") || !probeFlags.contains("readiness") {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: pod.id,
                    resourceName: pod.name,
                    resourceNamespace: pod.namespace,
                    resourceKind: .pods,
                    severity: .info,
                    category: .reliability,
                    ruleId: "RELIABILITY_MISSING_PROBES",
                    title: "Missing Health Probes",
                    message: "Pod is missing liveness or readiness probes.",
                    recommendation: "Configure livenessProbe and readinessProbe for automatic recovery and safe rollouts."
                ))
            }

            // Runtime: CrashLoop / Failures / Restarts
            let status = pod.cells["Status"] ?? ""
            let restarts = Int(pod.cells["Restarts"] ?? "0") ?? 0
            if status.contains("CrashLoop") || status.contains("BackOff") || status.contains("Error") {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: pod.id,
                    resourceName: pod.name,
                    resourceNamespace: pod.namespace,
                    resourceKind: .pods,
                    severity: .error,
                    category: .runtime,
                    ruleId: "RUNTIME_CRASH_LOOP",
                    title: "Container CrashLoopBackOff",
                    message: "Pod has failed container execution and is restarting in back-off loop.",
                    recommendation: "Inspect pod logs and container exit codes to diagnose crash causes."
                ))
            }
            if restarts >= 5 {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: pod.id,
                    resourceName: pod.name,
                    resourceNamespace: pod.namespace,
                    resourceKind: .pods,
                    severity: .warning,
                    category: .runtime,
                    ruleId: "RUNTIME_HIGH_RESTARTS",
                    title: "High Container Restart Count",
                    message: "Pod containers have restarted \(restarts) times.",
                    recommendation: "Check pod logs and previous container termination reasons."
                ))
            }
        }

        // 4. Workloads Validation (Deployment/StatefulSet/DaemonSet)
        for wl in workloads {
            let ns = wl.namespace ?? "default"

            // Workload Replicas Degraded
            let readyParts = (wl.cells["Ready"] ?? "").split(separator: "/")
            if readyParts.count == 2,
               let ready = Int(readyParts[0]),
               let desired = Int(readyParts[1]),
               desired > 0 && ready < desired {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: wl.id,
                    resourceName: wl.name,
                    resourceNamespace: wl.namespace,
                    resourceKind: .workloads,
                    severity: .error,
                    category: .runtime,
                    ruleId: "WORKLOAD_REPLICAS_DEGRADED",
                    title: "Workload Replicas Degraded",
                    message: "\(wl.cells["Kind"] ?? "Workload") has only \(ready) of \(desired) pods ready.",
                    recommendation: "Check underlying pods for crash loops, scheduling constraints, or failed readiness probes."
                ))
            }

            // Workload missing ConfigMaps or Secrets
            if let cmStr = wl.cells["ConfigMaps"], !cmStr.isEmpty {
                let nsCMs = Set((configMapsByNamespace[ns] ?? []).map(\.name))
                if !nsCMs.isEmpty {
                    for cm in cmStr.split(separator: ",").map(String.init) where !nsCMs.contains(cm) {
                        addIssue(ResourceDiagnosticIssue(
                            resourceID: wl.id,
                            resourceName: wl.name,
                            resourceNamespace: wl.namespace,
                            resourceKind: .workloads,
                            severity: .error,
                            category: .configuration,
                            ruleId: "CONFIGMAP_NOT_FOUND",
                            title: "Missing ConfigMap Reference",
                            message: "Workload template references ConfigMap '\(cm)' which does not exist in namespace '\(ns)'.",
                            recommendation: "Create ConfigMap '\(cm)' before deploying new pod revisions."
                        ))
                    }
                }
            }

            if let secStr = wl.cells["Secrets"], !secStr.isEmpty {
                let nsSecs = Set((secretsByNamespace[ns] ?? []).map(\.name))
                if !nsSecs.isEmpty {
                    for sec in secStr.split(separator: ",").map(String.init) where !nsSecs.contains(sec) {
                        addIssue(ResourceDiagnosticIssue(
                            resourceID: wl.id,
                            resourceName: wl.name,
                            resourceNamespace: wl.namespace,
                            resourceKind: .workloads,
                            severity: .error,
                            category: .configuration,
                            ruleId: "SECRET_NOT_FOUND",
                            title: "Missing Secret Reference",
                            message: "Workload template references Secret '\(sec)' which does not exist in namespace '\(ns)'.",
                            recommendation: "Deploy Secret '\(sec)' to avoid pod creation errors."
                        ))
                    }
                }
            }

            // Workload Security checks
            let secFlags = Set((wl.cells["Security"] ?? "").split(separator: ",").map(String.init))
            if secFlags.contains("privileged") {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: wl.id,
                    resourceName: wl.name,
                    resourceNamespace: wl.namespace,
                    resourceKind: .workloads,
                    severity: .warning,
                    category: .security,
                    ruleId: "SECURITY_PRIVILEGED",
                    title: "Privileged Container Template",
                    message: "Workload pod template runs in privileged mode.",
                    recommendation: "Disable privileged mode and grant only the specific Linux capabilities needed."
                ))
            }
            if secFlags.contains("runAsRoot") {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: wl.id,
                    resourceName: wl.name,
                    resourceNamespace: wl.namespace,
                    resourceKind: .workloads,
                    severity: .warning,
                    category: .security,
                    ruleId: "SECURITY_RUN_AS_ROOT",
                    title: "Running as Root Template",
                    message: "Workload allows root user execution without runAsNonRoot enforcement.",
                    recommendation: "Set securityContext.runAsNonRoot: true and specify a non-zero runAsUser."
                ))
            }

            // Workload Reliability: Memory limits
            if wl.cells["HasLimits"] == "false" {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: wl.id,
                    resourceName: wl.name,
                    resourceNamespace: wl.namespace,
                    resourceKind: .workloads,
                    severity: .warning,
                    category: .reliability,
                    ruleId: "RELIABILITY_NO_LIMITS",
                    title: "Missing Memory Limits",
                    message: "Workload has no memory limits configured, risking node memory exhaustion and OOM kills.",
                    recommendation: "Define resources.limits.memory for all containers."
                ))
            }

            // Workload Reliability: Probes
            let probeFlags = Set((wl.cells["Probes"] ?? "").split(separator: ",").map(String.init))
            if !probeFlags.contains("liveness") || !probeFlags.contains("readiness") {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: wl.id,
                    resourceName: wl.name,
                    resourceNamespace: wl.namespace,
                    resourceKind: .workloads,
                    severity: .info,
                    category: .reliability,
                    ruleId: "RELIABILITY_MISSING_PROBES",
                    title: "Missing Health Probes",
                    message: "Workload pod template is missing liveness or readiness probes.",
                    recommendation: "Configure livenessProbe and readinessProbe for automatic recovery and safe rollouts."
                ))
            }
        }

        // 5. PersistentVolumeClaims (PVC unbound)
        for pvc in pvcs {
            let status = pvc.cells["Status"] ?? "Bound"
            if status != "Bound" {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: pvc.id,
                    resourceName: pvc.name,
                    resourceNamespace: pvc.namespace,
                    resourceKind: .pvc,
                    severity: .error,
                    category: .configuration,
                    ruleId: "PVC_UNBOUND",
                    title: "PersistentVolumeClaim Unbound",
                    message: "Claim is in '\(status)' status, volume storage is not bound.",
                    recommendation: "Verify StorageClass availability and storage provisioner health."
                ))
            }
        }

        // 6. Nodes (Not Ready)
        for node in nodes {
            let ready = node.cells["Ready"] ?? node.cells["Status"] ?? "Ready"
            if ready != "Ready" {
                addIssue(ResourceDiagnosticIssue(
                    resourceID: node.id,
                    resourceName: node.name,
                    resourceNamespace: nil,
                    resourceKind: .nodes,
                    severity: .error,
                    category: .runtime,
                    ruleId: "NODE_NOT_READY",
                    title: "Node Not Ready",
                    message: "Node '\(node.name)' is reporting Not Ready status.",
                    recommendation: "Check kubelet logs and system resources on the node."
                ))
            }
        }

        let allIssues = issuesByResource.values.flatMap { $0 }
        let errors = allIssues.filter { $0.severity == .error }.count
        let warnings = allIssues.filter { $0.severity == .warning }.count
        let infos = allIssues.filter { $0.severity == .info }.count

        return KubernetesDiagnosticReport(
            issuesByResourceID: issuesByResource,
            allIssues: allIssues,
            errorCount: errors,
            warningCount: warnings,
            infoCount: infos
        )
    }

    private static func parsePairs(_ str: String) -> [String: String] {
        guard !str.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for item in str.split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result[parts[0]] = parts[1]
            }
        }
        return result
    }
}
