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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CTXInspectorFieldRow(label: "Reference", value: detail.safeReference, monospaced: true)
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
            }
            if let note = detail.safetyNote {
                Label(note, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if (selection.kind == .services || selection.kind == .workloads), !encodedSelector.isEmpty, viewModel.resourceList(for: .pods) == nil {
                viewModel.loadPodsForLogs()
            }
        }
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
