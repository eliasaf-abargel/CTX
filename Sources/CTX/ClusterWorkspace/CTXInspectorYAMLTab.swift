import CTXCore
import SwiftUI

/// The inspector's YAML tab. Inspection, monospaced, scrollable — no edit, no apply,
/// no second modal (this renders inline as one of the inspector's tabs, not its own
/// sheet). When `selection.kind.supportsInspectionYAML` is false, shows a clear,
/// visible reason instead of an empty or broken-looking tab.
struct CTXInspectorYAMLTab: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let selection: ClusterWorkspaceResourceSelection
    @State private var showDetails = false

    var body: some View {
        Group {
            if !selection.kind.supportsInspectionYAML {
                unavailable
            } else if viewModel.isLoadingYAML {
                CTXGlassPanel {
                    CTXLoadingStateView(title: "Loading YAML", message: "Running an inspection get command.")
                }
            } else if let yaml = viewModel.yamlResult?.yaml, !yaml.isEmpty {
                yamlPanel(yaml)
            } else if let result = viewModel.yamlResult {
                issue(result)
            } else {
                CTXGlassPanel {
                    CTXLoadingStateView(title: "Loading YAML", message: "Running an inspection get command.")
                }
            }
        }
        .onAppear {
            if selection.kind.supportsInspectionYAML, viewModel.yamlResult == nil {
                viewModel.loadYAMLForFocusedResource()
            }
        }
    }

    private var unavailable: some View {
        CTXGlassPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("YAML unavailable for this resource", systemImage: "lock.shield")
                    .font(.system(size: 13, weight: .semibold))
                Text(unavailableReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unavailableReason: String {
        switch selection.kind {
        case .secretMetadata: "Secret values are never requested or displayed, so there's no safe YAML to show."
        case .configMaps: "ConfigMap values aren't shown until a redaction model exists."
        case .workloads: "Workload YAML is disabled until template redaction rules are designed (env vars and volumes can reference secrets)."
        default: "This resource kind doesn't support inspection YAML in CTX."
        }
    }

    private func yamlPanel(_ yaml: String) -> some View {
        CTXGlassPanel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("Inspection")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    CTXReloadIconButton(action: {
                        viewModel.loadYAMLForFocusedResource()
                    }, isLoading: viewModel.isLoadingYAML)
                    CTXCopyIconButton(value: yaml)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider().opacity(0.55)
                ScrollView([.vertical, .horizontal]) {
                    Text(yaml)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 320, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func issue(_ result: KubernetesYAMLResult) -> some View {
        CTXGlassPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(result.status.tint)
                        .frame(width: 32, height: 32)
                        .background(result.status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.status.cardValue)
                            .font(.headline)
                        Text(result.status.cardSubtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CTXReloadIconButton(action: {
                        viewModel.loadYAMLForFocusedResource()
                    })
                }

                if let diagnostic = result.diagnostic {
                    HStack(spacing: 12) {
                        Button(showDetails ? "Hide details" : "Show details") {
                            showDetails.toggle()
                        }
                        .buttonStyle(CTXInlineActionButton())
                        .controlSize(.small)
                        Button("Copy diagnostics") {
                            copyToClipboard(diagnostic.safeSummary)
                        }
                        .buttonStyle(CTXInlineActionButton())
                        .controlSize(.small)
                    }
                    if showDetails {
                        Text(diagnostic.safeSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }
}
