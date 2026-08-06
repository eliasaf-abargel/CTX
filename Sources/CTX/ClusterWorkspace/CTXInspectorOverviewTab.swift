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
    /// Fetched from the live object when the inspector opens. Everything below used
    /// to be produced by matching the pod's *name* against a hardcoded list, so the
    /// environment variables, probes, security context and resource gauges on screen
    /// had no connection to the cluster at all.
    @State private var podSpec: PodSpecInsight?
    @State private var endpoints: [EndpointTarget] = []
    @State private var isLoadingSpec = false

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
            if selection.kind == .pods || selection.kind == .workloads {
                Divider().opacity(0.3)
                containerImageHeaderSection
            }
            if let repoURL = selection.row.cells["Repo URL"], !repoURL.isEmpty {
                Divider().opacity(0.3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("GITOPS APPLICATION")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    // Every value here is whatever the controller reported, falling
                    // back to the unknown marker. Defaulting these to "ArgoCD" /
                    // "Synced" / "main" is what made the old screen look
                    // authoritative about state it had never actually read.
                    CTXInspectorFieldRow(label: "Provider", value: gitOpsField("Provider"))
                    CTXInspectorFieldRow(label: "Source Type", value: gitOpsField("Source"))
                    CTXInspectorFieldRow(label: "Sync Status", value: gitOpsField("Status"))
                    CTXInspectorFieldRow(label: "Health", value: gitOpsField("Health"))
                    CTXInspectorFieldRow(label: "Repository", value: repoURL)
                    CTXInspectorFieldRow(label: "Target Revision", value: gitOpsField("Target"))
                    CTXInspectorFieldRow(label: "Deployed Revision", value: gitOpsField("Synced"))
                }
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
                CTXServiceEndpointsInspector(targets: endpoints)
            }
            if selection.kind == .pods {
                Divider().opacity(0.3)
                podSpecSections
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
            podSpec = nil
            endpoints = []
        }
        .task(id: selection.row.id) {
            await loadLiveSpec()
        }
    }

    private func memoizeState() {
        memoizedAdvice = KubernetesRemediationAdvisor.analyze(row: selection.row)
    }

    /// Reads the single object the inspector is showing. Scoped to the one resource
    /// rather than folded into the list fetch, so opening an inspector on a cluster
    /// with thousands of pods costs one small read instead of carrying every
    /// container's spec around in memory.
    private func loadLiveSpec() async {
        guard let namespace = selection.row.namespace else { return }
        isLoadingSpec = true
        defer { isLoadingSpec = false }
        switch selection.kind {
        case .pods:
            podSpec = await viewModel.specReader.podSpec(
                context: viewModel.context,
                namespace: namespace,
                name: selection.row.name
            )
        case .services:
            let result = await viewModel.specReader.serviceEndpoints(
                context: viewModel.context,
                namespace: namespace,
                name: selection.row.name
            )
            endpoints = result.targets
        default:
            break
        }
    }

    /// Container-level facts, straight from the pod object.
    @ViewBuilder
    private var podSpecSections: some View {
        if let podSpec, podSpec.status == .reachable {
            ForEach(podSpec.containers) { container in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: container.isInitContainer ? "arrow.down.circle" : "shippingbox")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(container.isInitContainer ? "INIT CONTAINER · \(container.name)" : "CONTAINER · \(container.name)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    CTXInspectorFieldRow(label: "Image", value: container.image, monospaced: true)
                    resourceRows(container.resources)
                    CTXSecurityContextInspector(audit: container.security)
                    CTXProbesInspector(probes: container.probes)
                    CTXEnvironmentVariablesInspector(items: container.env)
                }
                Divider().opacity(0.3)
            }
            CTXInspectorFieldRow(label: "Service Account", value: podSpec.serviceAccount, monospaced: true)
        } else if isLoadingSpec {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading pod spec…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let diagnostic = podSpec?.diagnostic {
            Label(diagnostic.stderrSummary, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Declared requests and limits. An absent limit is shown as absent — that is a
    /// real finding (the container can consume the whole node), not a blank to fill.
    @ViewBuilder
    private func resourceRows(_ allocation: ResourceAllocation) -> some View {
        let unset = "not set"
        CTXInspectorFieldRow(
            label: "CPU",
            value: "request \(allocation.cpuRequest ?? unset) · limit \(allocation.cpuLimit ?? unset)",
            monospaced: true
        )
        CTXInspectorFieldRow(
            label: "Memory",
            value: "request \(allocation.memoryRequest ?? unset) · limit \(allocation.memoryLimit ?? unset)",
            monospaced: true
        )
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


    private var containerImageHeaderSection: some View {
        let rawImage = selection.row.cells["Image"] ?? selection.row.cells["Containers"] ?? ""
        guard !rawImage.isEmpty, rawImage != "-" else { return AnyView(EmptyView()) }
        
        let (registry, repository, tag) = parseImageRef(rawImage)
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Text("CONTAINER IMAGE & VERSION TAG")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                
                CTXInspectorFieldRow(label: "Image Tag", value: tag, monospaced: true)
                CTXInspectorFieldRow(label: "Image Ref", value: repository, monospaced: true)
                CTXInspectorFieldRow(label: "Registry", value: registry)
            }
        )
    }

    private func parseImageRef(_ imageRef: String) -> (registry: String, repository: String, tag: String) {
        let components = imageRef.components(separatedBy: "/")
        var registry = "docker.io"
        var repoWithTag = imageRef
        
        if components.count > 1 && (components[0].contains(".") || components[0].contains(":") || components[0] == "localhost") {
            registry = components[0]
            repoWithTag = components.dropFirst().joined(separator: "/")
        }
        
        let tagComponents = repoWithTag.components(separatedBy: ":")
        let repository = tagComponents.first ?? repoWithTag
        let tag = tagComponents.count > 1 ? tagComponents.dropFirst().joined(separator: ":") : "latest"
        
        return (registry, repository, tag)
    }

    /// A GitOps cell as reported, or the shared unknown marker — never a guess.
    private func gitOpsField(_ key: String) -> String {
        let value = selection.row.cells[key] ?? ""
        return value.isEmpty ? KubernetesGitOpsService.unknownValue : value
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
        "Cluster IP", "External", "Ports", "Hosts", "Address", "IP",
        "Git Repository", "Target Revision", "Image", "Image Ref", "Image Tag", "Registry"
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
