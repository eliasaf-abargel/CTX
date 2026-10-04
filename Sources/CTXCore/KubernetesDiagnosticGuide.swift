import Foundation

/// Provides structural context, spec paths, and suggested YAML snippets for
/// diagnostic issues detected by `KubernetesConfigurationValidator`.
public struct KubernetesDiagnosticGuide: Sendable, Equatable {
    public let specPath: String
    public let specSectionTitle: String
    public let yamlSearchTerm: String
    public let suggestedYAML: String?

    public init(specPath: String, specSectionTitle: String, yamlSearchTerm: String, suggestedYAML: String? = nil) {
        self.specPath = specPath
        self.specSectionTitle = specSectionTitle
        self.yamlSearchTerm = yamlSearchTerm
        self.suggestedYAML = suggestedYAML
    }

    public static func guide(for ruleId: String) -> KubernetesDiagnosticGuide {
        switch ruleId {
        case "RELIABILITY_MISSING_PROBES":
            return KubernetesDiagnosticGuide(
                specPath: "spec.template.spec.containers[*].livenessProbe",
                specSectionTitle: "Health Probes",
                yamlSearchTerm: "containers:",
                suggestedYAML: """
                # Add to container in spec.template.spec.containers:
                livenessProbe:
                  httpGet:
                    path: /healthz
                    port: 8080
                  initialDelaySeconds: 15
                  periodSeconds: 20
                readinessProbe:
                  httpGet:
                    path: /ready
                    port: 8080
                  initialDelaySeconds: 5
                  periodSeconds: 10
                """
            )

        case "RELIABILITY_NO_LIMITS":
            return KubernetesDiagnosticGuide(
                specPath: "spec.template.spec.containers[*].resources",
                specSectionTitle: "Resource Allocation",
                yamlSearchTerm: "resources:",
                suggestedYAML: """
                # Add to container in spec.template.spec.containers:
                resources:
                  requests:
                    cpu: 100m
                    memory: 128Mi
                  limits:
                    cpu: 500m
                    memory: 512Mi
                """
            )

        case "SECURITY_PRIVILEGED":
            return KubernetesDiagnosticGuide(
                specPath: "spec.template.spec.containers[*].securityContext.privileged",
                specSectionTitle: "Security Context",
                yamlSearchTerm: "privileged:",
                suggestedYAML: """
                # In container securityContext:
                securityContext:
                  privileged: false
                  allowPrivilegeEscalation: false
                """
            )

        case "SECURITY_RUN_AS_ROOT":
            return KubernetesDiagnosticGuide(
                specPath: "spec.template.spec.securityContext.runAsNonRoot",
                specSectionTitle: "Security Context",
                yamlSearchTerm: "runAsNonRoot:",
                suggestedYAML: """
                # In pod or container securityContext:
                securityContext:
                  runAsNonRoot: true
                  runAsUser: 10001
                """
            )

        case "SECURITY_HOST_NAMESPACE":
            return KubernetesDiagnosticGuide(
                specPath: "spec.template.spec.hostNetwork / hostPID / hostIPC",
                specSectionTitle: "Security Context",
                yamlSearchTerm: "hostNetwork:",
                suggestedYAML: """
                # In spec.template.spec:
                hostNetwork: false
                hostPID: false
                hostIPC: false
                """
            )

        case "SERVICE_NO_MATCHING_PODS", "SERVICE_WORKLOAD_SCALED_ZERO":
            return KubernetesDiagnosticGuide(
                specPath: "spec.selector",
                specSectionTitle: "Service Endpoints",
                yamlSearchTerm: "selector:",
                suggestedYAML: """
                # In service spec:
                spec:
                  selector:
                    app.kubernetes.io/name: <target-workload>
                """
            )

        case "CONFIGMAP_NOT_FOUND":
            return KubernetesDiagnosticGuide(
                specPath: "spec.template.spec.volumes[*].configMap",
                specSectionTitle: "Config & Environment",
                yamlSearchTerm: "configMap:",
                suggestedYAML: """
                # Ensure the referenced ConfigMap exists in the same namespace.
                """
            )

        case "SECRET_NOT_FOUND":
            return KubernetesDiagnosticGuide(
                specPath: "spec.template.spec.volumes[*].secret",
                specSectionTitle: "Config & Environment",
                yamlSearchTerm: "secret:",
                suggestedYAML: """
                # Ensure the referenced Secret exists in the same namespace.
                """
            )

        case "PVC_NOT_FOUND", "PVC_UNBOUND":
            return KubernetesDiagnosticGuide(
                specPath: "spec.template.spec.volumes[*].persistentVolumeClaim",
                specSectionTitle: "Storage & Volumes",
                yamlSearchTerm: "persistentVolumeClaim:",
                suggestedYAML: """
                # Verify PVC status and StorageClass provisioner binding.
                """
            )

        case "INGRESS_SERVICE_NOT_FOUND":
            return KubernetesDiagnosticGuide(
                specPath: "spec.rules[*].http.paths[*].backend.service",
                specSectionTitle: "Ingress Rules",
                yamlSearchTerm: "backend:",
                suggestedYAML: """
                # Ensure the target Service name and port exist in this namespace.
                """
            )

        case "RUNTIME_CRASH_LOOP", "RUNTIME_HIGH_RESTARTS":
            return KubernetesDiagnosticGuide(
                specPath: "status.containerStatuses[*].state.waiting",
                specSectionTitle: "Runtime Logs & Health",
                yamlSearchTerm: "containerStatuses:",
                suggestedYAML: nil
            )

        default:
            return KubernetesDiagnosticGuide(
                specPath: "spec",
                specSectionTitle: "Specification",
                yamlSearchTerm: "spec:",
                suggestedYAML: nil
            )
        }
    }
}
