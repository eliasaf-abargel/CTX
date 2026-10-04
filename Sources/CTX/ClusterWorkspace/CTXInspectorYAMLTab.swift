import CTXCore
import SwiftUI

/// The inspector's YAML tab.
/// Supports viewing live manifests, in-place editing, unified diff preview,
/// safe server dry-run validation, atomic apply, and single-click rollback.
struct CTXInspectorYAMLTab: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let selection: ClusterWorkspaceResourceSelection

    @State private var showDetails = false
    @State private var showDiff = false
    @State private var pendingConfirmation: PendingYAMLConfirmation?
    /// Recomputed on a short debounce after `editedYAML` settles rather than on
    /// every keystroke — the diff is a full LCS table build, and at manifest
    /// sizes CTX actually edits (workload-adjacent Services, ConfigMaps-once
    /// redaction lands) that's cheap once per pause but not cheap 10x/second
    /// while someone is still typing.
    @State private var diffSummary = YAMLDiffSummary.empty

    private enum PendingYAMLConfirmation: Equatable {
        case apply
        case rollback
    }

    var body: some View {
        Group {
            if !selection.kind.supportsInspectionYAML {
                unavailable
            } else if viewModel.isLoadingYAML && !viewModel.isEditingYAML {
                CTXGlassPanel {
                    CTXLoadingStateView(title: "Loading YAML", message: "Fetching live resource manifest from cluster.")
                }
            } else if viewModel.isEditingYAML {
                yamlEditorPanel
            } else if let yaml = viewModel.yamlResult?.yaml, !yaml.isEmpty {
                yamlViewerPanel(yaml)
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
        .alert(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            presenting: pendingConfirmation
        ) { confirmation in
            Button(confirmation == .rollback ? "Rollback" : "Apply", role: .destructive) {
                perform(confirmation)
                pendingConfirmation = nil
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: { confirmation in
            Text(confirmationMessage(for: confirmation))
        }
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .apply: "Apply changes to \(selection.row.name)?"
        case .rollback: "Roll back \(selection.row.name)?"
        case .none: ""
        }
    }

    private func confirmationMessage(for confirmation: PendingYAMLConfirmation) -> String {
        let target = "\(selection.kind.rawValue)/\(selection.row.name) in \(selection.row.namespace ?? "cluster scope"), on \(viewModel.context.contextName)"
        switch confirmation {
        case .apply:
            return "This runs kubectl apply against the live cluster for \(target). The change is recorded in the audit log."
        case .rollback:
            return "This re-applies the previous manifest to \(target), undoing the last apply. The change is recorded in the audit log."
        }
    }

    private func perform(_ confirmation: PendingYAMLConfirmation) {
        switch confirmation {
        case .apply:
            viewModel.applyEditedYAML(for: selection)
        case .rollback:
            viewModel.rollbackYAML(for: selection)
        }
    }

    private var unavailable: some View {
        CTXGlassPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("YAML unavailable for this resource", systemImage: "lock.shield")
                    .font(.system(.footnote, weight: .semibold))
                Text(unavailableReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unavailableReason: String {
        switch selection.kind {
        case .secretMetadata: "Secret values are protected for security and not displayed in plaintext."
        default: "This resource kind doesn't support inspection YAML in CTX."
        }
    }

    // MARK: - Viewer Panel

    private func yamlViewerPanel(_ yaml: String) -> some View {
        CTXGlassPanel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Header Toolbar
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.plaintext")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("Live Manifest")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())

                    if viewModel.previousBaselineYAML != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text("Previous baseline available")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if let _ = viewModel.previousBaselineYAML {
                        Button {
                            pendingConfirmation = .rollback
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Rollback")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isApplyingYAML)
                        .help("Roll back cluster resource to pre-apply baseline")
                    }

                    Button {
                        viewModel.startEditingYAML()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Edit YAML")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Edit resource YAML with safe server dry-run")

                    CTXReloadIconButton(action: {
                        viewModel.loadYAMLForFocusedResource()
                    }, isLoading: viewModel.isLoadingYAML)

                    CTXCopyIconButton(value: Self.cleanYAML(from: yaml))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if let applyResult = viewModel.applyResult, !applyResult.isDryRun {
                    applyBanner(applyResult)
                }

                Divider().opacity(0.55)

                ScrollView([.vertical, .horizontal]) {
                    Text(yaml)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 200, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// True only once a server dry-run has succeeded against exactly this edit.
    /// Any further keystroke moves `editedYAML` away from the validated
    /// snapshot and this goes false again, so Apply always reflects a live
    /// dry-run, never a stale one.
    private var canApply: Bool {
        guard let validated = viewModel.dryRunValidatedYAML else { return false }
        return validated == viewModel.editedYAML
    }

    // MARK: - Editor Panel

    private var yamlEditorPanel: some View {
        CTXGlassPanel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Header Toolbar in Edit Mode
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("Editing Manifest")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12), in: Capsule())

                    if diffSummary.hasChanges {
                        HStack(spacing: 6) {
                            if diffSummary.additions > 0 {
                                Text("+\(diffSummary.additions)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.green)
                            }
                            if diffSummary.deletions > 0 {
                                Text("-\(diffSummary.deletions)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    Spacer()

                    // Diff Toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showDiff.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showDiff ? "pencil" : "arrow.left.arrow.right")
                                .font(.system(size: 10, weight: .medium))
                            Text(showDiff ? "Editor" : "Diff (\(diffSummary.additions + diffSummary.deletions))")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(showDiff ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Cancel
                    Button("Cancel") {
                        viewModel.cancelEditingYAML()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                    // Stage 1: Server Dry-Run
                    Button {
                        viewModel.dryRunEditedYAML(for: selection)
                    } label: {
                        HStack(spacing: 4) {
                            if viewModel.isDryRunningYAML {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "checkmark.shield")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text("Dry-Run")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isDryRunningYAML || viewModel.isApplyingYAML || !diffSummary.hasChanges)
                    .help("Simulate server-side apply without modifying the cluster")

                    // Stage 2: Apply to Cluster
                    Button {
                        pendingConfirmation = .apply
                    } label: {
                        HStack(spacing: 4) {
                            if viewModel.isApplyingYAML {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            Text("Apply")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(canApply ? Color.accentColor : Color.secondary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isApplyingYAML || viewModel.isDryRunningYAML || !canApply)
                    .help(canApply ? "Apply modified YAML to the live cluster" : "Run Dry-Run against this edit first")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                // Feedback Banner
                if let result = viewModel.applyResult {
                    applyBanner(result)
                }

                Divider().opacity(0.55)

                if showDiff {
                    diffView(diffSummary)
                } else {
                    editorView
                }
            }
        }
        .task(id: viewModel.editedYAML) {
            // Debounced: a full LCS diff on every keystroke visibly stutters the
            // editor on a manifest of any real size. Waiting for typing to pause
            // costs nothing the UI needs instantly — the badge and Diff tab are
            // both fine a couple hundred milliseconds behind the cursor.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let original = viewModel.yamlResult?.yaml ?? ""
            let modified = viewModel.editedYAML
            let result = YAMLDiffCalculator.diff(original: original, modified: modified)
            guard !Task.isCancelled else { return }
            diffSummary = result
        }
    }

    // MARK: - Banner

    private func applyBanner(_ result: KubernetesApplyResult) -> some View {
        CTXOutcomeBanner(result: result)
    }

    // MARK: - Diff View

    private func diffView(_ diff: YAMLDiffSummary) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 1) {
                if !diff.hasChanges {
                    Text("No differences detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(20)
                } else {
                    ForEach(diff.lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(lineIndicator(for: line))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(line.kind == .unchanged ? .secondary.opacity(0.5) : lineTint(for: line.kind))
                                .frame(width: 32, alignment: .trailing)

                            Text(prefix(for: line.kind))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(lineTint(for: line.kind))
                                .frame(width: 12, alignment: .leading)

                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(line.kind == .unchanged ? .primary : lineTint(for: line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .background(lineBackground(for: line.kind))
                    }
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 200, maxHeight: .infinity, alignment: .top)
    }

    private func lineIndicator(for line: YAMLDiffLine) -> String {
        if let n = line.newLineNumber {
            return "\(n)"
        } else if let o = line.originalLineNumber {
            return "\(o)"
        }
        return ""
    }

    private func prefix(for kind: YAMLDiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .unchanged: return " "
        }
    }

    private func lineTint(for kind: YAMLDiffLine.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .unchanged: return .secondary
        }
    }

    private func lineBackground(for kind: YAMLDiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.08)
        case .removed: return Color.red.opacity(0.08)
        case .unchanged: return Color.clear
        }
    }

    // MARK: - Editor View

    private var editorView: some View {
        ScrollView([.vertical, .horizontal]) {
            TextEditor(text: $viewModel.editedYAML)
                .font(.system(.caption2, design: .monospaced))
                .lineSpacing(3)
                .padding(14)
                .frame(minWidth: 640, minHeight: 200, alignment: .topLeading)
        }
        .frame(minHeight: 200, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Diagnostic Issue

    private func issue(_ result: KubernetesYAMLResult) -> some View {
        CTXGlassPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(.headline, weight: .semibold))
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
                            .font(.system(.caption2, design: .monospaced))
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

    private static func cleanYAML(from yaml: String) -> String {
        let lines = yaml.components(separatedBy: .newlines)
        var inManagedFields = false
        var cleanLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("managedFields:") {
                inManagedFields = true
                continue
            }
            if inManagedFields {
                if line.prefix(while: { $0 == " " }).count <= 2 && !trimmed.hasPrefix("-") && !trimmed.isEmpty {
                    inManagedFields = false
                } else {
                    continue
                }
            }
            if trimmed.hasPrefix("resourceVersion:") || trimmed.hasPrefix("uid:") || trimmed.hasPrefix("generation:") || trimmed.hasPrefix("creationTimestamp:") {
                continue
            }
            cleanLines.append(line)
        }
        return cleanLines.joined(separator: "\n")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
