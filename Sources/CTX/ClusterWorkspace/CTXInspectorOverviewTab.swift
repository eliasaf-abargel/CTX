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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CTXInspectorFieldRow(label: "Reference", value: detail.safeReference, monospaced: true)

            if selection.kind == .workloads, let controllerKind = viewModel.controllerKind(for: selection.row) {
                Divider().opacity(0.3)
                WorkloadLifecycleActionsView(viewModel: viewModel, selection: selection, controllerKind: controllerKind)
            }

            if let advice = memoizedAdvice {
                remediationPanel(advice)
            }

            ForEach(detail.sections) { section in
                Divider().opacity(0.3)
                CTXInspectorSection(title: section.title, fields: section.fields)
            }

            if let repoURL = selection.row.cells["Repo URL"], !repoURL.isEmpty {
                let targetRev = gitOpsField("Target")
                let webURL = GitRepositoryURLHelper.webURL(from: repoURL, revision: targetRev)
                Divider().opacity(0.3)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("GITOPS APPLICATION")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if let webURL {
                            Button {
                                NSWorkspace.shared.open(webURL)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Open in Browser")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("Open repository in browser: \(webURL.absoluteString)")
                        }
                    }
                    .padding(.top, 2)

                    CTXInspectorFieldRow(label: "Provider", value: gitOpsField("Provider"))
                    CTXInspectorFieldRow(label: "Source Type", value: gitOpsField("Source"))
                    CTXInspectorFieldRow(label: "Sync Status", value: gitOpsField("Status"))
                    CTXInspectorFieldRow(label: "Health", value: gitOpsField("Health"))
                    CTXInspectorFieldRow(label: "Repository", value: repoURL, linkURL: webURL)
                    CTXInspectorFieldRow(label: "Target Revision", value: targetRev, linkURL: webURL)
                    let syncedRev = gitOpsField("Synced")
                    let syncedURL = GitRepositoryURLHelper.webURL(from: repoURL, revision: syncedRev)
                    CTXInspectorFieldRow(label: "Deployed Revision", value: syncedRev, linkURL: syncedURL)
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
            if selection.kind == .workloads {
                if !relatedPodFields.isEmpty {
                    Divider().opacity(0.3)
                    CTXInspectorSection(title: "Related Pods", fields: relatedPodFields)
                }
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
    }











    private var relatedPodFields: [KubernetesResourceDetail.Field] {
        guard !encodedSelector.isEmpty else {
            return []
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
                        .font(.system(.caption, weight: .bold))
                    Spacer()
                    Text(advice.category)
                        .font(.system(.caption2, weight: .bold))
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
                            .font(.system(.caption2, design: .monospaced))
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
                .font(.system(size: 11.5, weight: .bold))
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
    var linkURL: URL? = nil

    /// Copy is only worth an icon next to a value someone would actually paste
    /// elsewhere — a name, a reference, an address. Age/status/counts are read at a
    /// glance, never copied, so an icon there would just be clutter.
    static let copyableFieldLabels: Set<String> = [
        "Name", "Namespace", "Reference", "Object", "Message",
        "Cluster IP", "External", "Ports", "Hosts", "Address", "IP",
        "Repository", "Git Repository", "Target Revision", "Deployed Revision", "Image", "Image Ref", "Image Tag", "Registry"
    ]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: monospaced ? .monospaced : .default))
                .lineLimit(label == "Message" ? 3 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
            Spacer(minLength: 4)
            if let linkURL {
                Button {
                    NSWorkspace.shared.open(linkURL)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Open in browser (\(linkURL.absoluteString))")
            }
            if Self.copyableFieldLabels.contains(label), value != "-" {
                CTXCopyIconButton(value: value)
            }
        }
    }
}
