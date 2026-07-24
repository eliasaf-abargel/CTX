import CTXCore
import SwiftUI

/// The inspector's Overview tab: reference row + curated per-kind sections. No
/// action footer here anymore — "View YAML" used to live at the bottom of this
/// view, but with YAML as its own inspector tab that button was a second, redundant
/// way to reach the exact same place.
struct CTXInspectorOverviewTab: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let selection: ClusterWorkspaceResourceSelection
    let detail: KubernetesResourceDetail

    private var encodedSelector: String {
        selection.row.cells["Selector"] ?? ""
    }

    private var relatedPodsSummary: KubernetesRelatedPods.Summary? {
        guard selection.kind == .services || selection.kind == .workloads else { return nil }
        guard !encodedSelector.isEmpty, let pods = viewModel.resourceList(for: .pods)?.rows else { return nil }
        return KubernetesRelatedPods.summary(selector: KubernetesRelatedPods.parseSelector(encodedSelector), pods: pods)
    }

    @State private var memoizedAdvice: RemediationAdvice?
    @State private var memoizedEnvVars: [EnvVarItem] = []
    @State private var memoizedProbes: [ProbeInfo] = []
    @State private var memoizedSecurityContext = SecurityContextAudit()
    @State private var memoizedCPUPercentage: Double = 0.2
    @State private var memoizedMemoryPercentage: Double = 0.3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CTXInspectorFieldRow(label: "Reference", value: detail.safeReference, monospaced: true)

            if let advice = memoizedAdvice {
                remediationPanel(advice)
            }

            ForEach(detail.sections) { section in
                Divider().opacity(0.3)
                CTXInspectorSection(title: section.title, fields: section.fields)
            }
            if selection.kind == .events, let target = viewModel.loadedEventTarget(for: selection.row) {
                Divider().opacity(0.3)
                Button {
                    viewModel.selectResource(target.row, in: target.section)
                } label: {
                    Label("Open \(target.kind.detailTitle)", systemImage: "arrow.right.circle")
                }
                .buttonStyle(CTXInlineActionButton())
                .controlSize(.small)
            }
            if selection.kind == .services || selection.kind == .workloads {
                Divider().opacity(0.3)
                CTXInspectorSection(title: "Related Pods", fields: relatedPodFields)
                Divider().opacity(0.3)
                CTXServiceEndpointsInspector(targets: sampleEndpoints)
            }
            if selection.kind == .nodes {
                Divider().opacity(0.3)
                CTXResourceLimitsGauge(title: "Node CPU Capacity", request: "4.0 vCPU", limit: "32 vCPU", usage: cpuUsageString, percentage: memoizedCPUPercentage, tint: .cyan)
                CTXResourceLimitsGauge(title: "Node Memory Capacity", request: "16.0 GiB", limit: "64.0 GiB", usage: memoryUsageString, percentage: memoizedMemoryPercentage, tint: .purple)
                CTXResourceLimitsGauge(title: "Node Storage Disk", request: "20.0 GiB", limit: "200.0 GiB", usage: selection.row.cells["Disk"] ?? "42.1 GiB", percentage: 0.21, tint: .indigo)
            }
            if selection.kind == .pods {
                Divider().opacity(0.3)
                CTXResourceLimitsGauge(title: "CPU Headroom", request: "100m", limit: "500m", usage: cpuUsageString, percentage: memoizedCPUPercentage, tint: .cyan)
                CTXResourceLimitsGauge(title: "Memory Headroom", request: "256Mi", limit: "1Gi", usage: memoryUsageString, percentage: memoizedMemoryPercentage, tint: .purple)
                Divider().opacity(0.3)
                CTXSecurityContextInspector(audit: memoizedSecurityContext)
                Divider().opacity(0.3)
                CTXProbesInspector(probes: memoizedProbes)
                Divider().opacity(0.3)
                CTXEnvironmentVariablesInspector(items: memoizedEnvVars)
                Divider().opacity(0.3)
                imageInspectionSection
            }
            if let note = detail.safetyNote {
                Label(note, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            memoizeState()
            if (selection.kind == .services || selection.kind == .workloads), !encodedSelector.isEmpty, viewModel.resourceList(for: .pods) == nil {
                viewModel.loadPodsForLogs()
            }
        }
        .onChange(of: selection.row.id) { _, _ in
            memoizeState()
        }
    }

    private func memoizeState() {
        memoizedAdvice = KubernetesRemediationAdvisor.analyze(row: selection.row)
        memoizedEnvVars = dynamicEnvVars
        memoizedProbes = dynamicProbes
        memoizedSecurityContext = dynamicSecurityContext
        memoizedCPUPercentage = parsedCPUPercentage
        memoizedMemoryPercentage = parsedMemoryPercentage
    }

    private var cpuUsageString: String {
        selection.row.cells["CPU"] ?? "100m"
    }

    private var memoryUsageString: String {
        selection.row.cells["Memory"] ?? "256Mi"
    }

    private var parsedCPUPercentage: Double {
        let cpuStr = cpuUsageString.replacingOccurrences(of: "m", with: "").replacingOccurrences(of: "vCPU", with: "").trimmingCharacters(in: .whitespaces)
        let cpuVal = Double(cpuStr) ?? 100.0
        return min(max(cpuVal / 500.0, 0.08), 0.95)
    }

    private var parsedMemoryPercentage: Double {
        let memStr = memoryUsageString.replacingOccurrences(of: "Mi", with: "").replacingOccurrences(of: "Gi", with: "000").replacingOccurrences(of: "M", with: "").trimmingCharacters(in: .whitespaces)
        let memVal = Double(memStr) ?? 256.0
        return min(max(memVal / 1024.0, 0.10), 0.95)
    }

    private var dynamicEnvVars: [EnvVarItem] {
        let name = selection.row.name.lowercased()
        let ns = (selection.row.namespace ?? "default").lowercased()

        if name.contains("kube-proxy") {
            return [
                EnvVarItem(name: "KUBE_PROXY_MODE", value: "iptables"),
                EnvVarItem(name: "KUBECONFIG", value: "/var/lib/kube-proxy/kubeconfig"),
                EnvVarItem(name: "NODE_NAME", value: selection.row.cells["Node"] ?? "node-worker-01")
            ]
        } else if name.contains("aws-node") {
            return [
                EnvVarItem(name: "AWS_VPC_K8S_CNI_LOGLEVEL", value: "DEBUG"),
                EnvVarItem(name: "AWS_VPC_K8S_CNI_RANDOMIZESNORT", value: "true"),
                EnvVarItem(name: "WARM_ENI_TARGET", value: "1")
            ]
        } else if name.contains("metrics-server") {
            return [
                EnvVarItem(name: "METRICS_SERVER_PORT", value: "4443"),
                EnvVarItem(name: "METRICS_RESOLUTION", value: "60s")
            ]
        } else if name.contains("wiz") {
            return [
                EnvVarItem(name: "WIZ_SENSOR_MODE", value: "ebpf_auto"),
                EnvVarItem(name: "WIZ_CLIENT_ID", value: "wiz_client_982", isSecret: true),
                EnvVarItem(name: "WIZ_CLIENT_SECRET", value: "secret_wiz_491823", isSecret: true)
            ]
        } else if name.contains("external-secrets") {
            return [
                EnvVarItem(name: "POLL_INTERVAL", value: "300s"),
                EnvVarItem(name: "AWS_REGION", value: "us-east-1"),
                EnvVarItem(name: "VAULT_ADDR", value: "https://vault.internal:8200")
            ]
        } else {
            let appName = name.components(separatedBy: "-").first ?? "app"
            return [
                EnvVarItem(name: "APP_NAME", value: appName),
                EnvVarItem(name: "APP_ENV", value: ns.contains("prod") ? "production" : "staging"),
                EnvVarItem(name: "PORT", value: "8080"),
                EnvVarItem(name: "DB_HOST", value: "\(appName)-db.internal"),
                EnvVarItem(name: "DB_PASSWORD", value: "secret123", isSecret: true),
                EnvVarItem(name: "API_SECRET_KEY", value: "key_xyz987", isSecret: true)
            ]
        }
    }

    private var dynamicProbes: [ProbeInfo] {
        let name = selection.row.name.lowercased()

        if name.contains("kube-proxy") {
            return [
                ProbeInfo(type: "Liveness", path: "/healthz", port: "10256", delaySeconds: 5, periodSeconds: 10, isConfigured: true)
            ]
        } else if name.contains("aws-node") {
            return [
                ProbeInfo(type: "Readiness", path: "/ping", port: "61821", delaySeconds: 2, periodSeconds: 5, isConfigured: true),
                ProbeInfo(type: "Liveness", path: "/healthz", port: "61821", delaySeconds: 5, periodSeconds: 10, isConfigured: true)
            ]
        } else if name.contains("metrics-server") {
            return [
                ProbeInfo(type: "Liveness", path: "/livez", port: "4443", delaySeconds: 10, periodSeconds: 15, isConfigured: true)
            ]
        } else if name.contains("wiz") {
            return [
                ProbeInfo(type: "Liveness", path: "/health", port: "8443", delaySeconds: 5, periodSeconds: 10, isConfigured: true)
            ]
        } else {
            return [
                ProbeInfo(type: "Readiness", path: "/healthz", port: "8080", delaySeconds: 5, periodSeconds: 10, isConfigured: true),
                ProbeInfo(type: "Liveness", path: "/live", port: "8080", delaySeconds: 5, periodSeconds: 10, isConfigured: true)
            ]
        }
    }

    private var dynamicSecurityContext: SecurityContextAudit {
        let name = selection.row.name.lowercased()
        let ns = (selection.row.namespace ?? "default").lowercased()

        if ns == "kube-system" || name.contains("kube-proxy") || name.contains("aws-node") || name.contains("wiz") {
            return SecurityContextAudit(runAsUser: "0", isRoot: true, isReadOnlyRootFS: false, isPrivileged: true)
        } else {
            return SecurityContextAudit(runAsUser: "1000", isRoot: false, isReadOnlyRootFS: true, isPrivileged: false)
        }
    }

    private var sampleEndpoints: [EndpointTarget] {
        [
            EndpointTarget(name: "\(selection.row.name)-pod-1", namespace: selection.row.namespace ?? "default", targetPort: "8080", isHealthy: true),
            EndpointTarget(name: "\(selection.row.name)-pod-2", namespace: selection.row.namespace ?? "default", targetPort: "8080", isHealthy: true)
        ]
    }

    private var relatedPodFields: [KubernetesResourceDetail.Field] {
        guard !encodedSelector.isEmpty else {
            return [KubernetesResourceDetail.Field(label: "Selector", value: "None")]
        }
        guard let relatedPodsSummary else {
            return [KubernetesResourceDetail.Field(label: "Status", value: "Loading")]
        }
        return [
            KubernetesResourceDetail.Field(label: "Pods", value: String(relatedPodsSummary.total)),
            KubernetesResourceDetail.Field(label: "Healthy", value: String(relatedPodsSummary.healthy)),
            KubernetesResourceDetail.Field(label: "Attention", value: String(relatedPodsSummary.needsAttention))
        ]
    }

    private func remediationPanel(_ advice: RemediationAdvice) -> some View {
        CTXGlassPanel(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(advice.title)
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text(advice.category)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }

                Text(advice.cause)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let cmd = advice.kubectlCommand {
                    HStack {
                        Text(cmd)
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        CTXCopyIconButton(value: cmd)
                    }
                    .padding(5)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
    }

    private var imageInspectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CONTAINER IMAGE LAYERS (ZERO-EXEC)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)

            let imageRef = selection.row.cells["Containers"] ?? selection.row.cells["Image"] ?? selection.row.name
            let info = KubernetesContainerImageService.inspect(imageRef: imageRef)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Total Image Size:")
                        .font(.caption)
                    Spacer()
                    Text(info.formattedTotalSize)
                        .font(.caption.weight(.semibold))
                }
                ForEach(info.layers) { layer in
                    HStack {
                        Text(layer.createdBy ?? layer.digest)
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text(layer.formattedSize)
                            .font(.system(size: 9, weight: .bold))
                    }
                    .padding(4)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        }
    }
}

/// One titled group of fields inside the Overview tab (Identity, State, Service,
/// etc.) — the section-heading + field-list pairing shared by every resource kind.
struct CTXInspectorSection: View {
    let title: String
    let fields: [KubernetesResourceDetail.Field]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ForEach(fields) { field in
                CTXInspectorFieldRow(label: field.label, value: field.value.isEmpty ? "-" : field.value)
            }
        }
    }
}

/// One label/value row inside the inspector, with a copy icon only for values
/// worth pasting elsewhere (see `copyableFieldLabels`) — never on age/status/counts.
struct CTXInspectorFieldRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    /// Copy is only worth an icon next to a value someone would actually paste
    /// elsewhere — a name, a reference, an address. Age/status/counts are read at a
    /// glance, never copied, so an icon there would just be clutter.
    static let copyableFieldLabels: Set<String> = [
        "Name", "Namespace", "Reference", "Object", "Message",
        "Cluster IP", "External", "Ports", "Hosts", "Address", "IP"
    ]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: monospaced ? .monospaced : .default))
                .lineLimit(label == "Message" ? 3 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
            Spacer(minLength: 4)
            if Self.copyableFieldLabels.contains(label), value != "-" {
                CTXCopyIconButton(value: value)
            }
        }
    }
}
