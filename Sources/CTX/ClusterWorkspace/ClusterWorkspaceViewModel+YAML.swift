import CTXCore
import Foundation

extension ClusterWorkspaceViewModel {
    func loadYAML(for selection: ClusterWorkspaceResourceSelection) {
        yamlTask?.cancel()
        yamlResult = nil
        isEditingYAML = false
        applyResult = nil
        dryRunValidatedYAML = nil
        guard selection.kind.supportsInspectionYAML else {
            yamlResult = KubernetesYAMLResult(yaml: nil, status: .permissionDenied)
            isLoadingYAML = false
            return
        }
        isLoadingYAML = true
        yamlTask = Task { [weak self] in
            guard let self else { return }
            let result = await yamlReader.yaml(kind: selection.kind, row: selection.row, context: context)
            guard !Task.isCancelled else { return }
            yamlResult = result
            isLoadingYAML = false
            yamlTask = nil
        }
    }

    func startEditingYAML() {
        guard let yaml = yamlResult?.yaml, !yaml.isEmpty else { return }
        editedYAML = yaml
        isEditingYAML = true
        applyResult = nil
        dryRunValidatedYAML = nil
    }

    func cancelEditingYAML() {
        isEditingYAML = false
        editedYAML = ""
        applyResult = nil
        dryRunValidatedYAML = nil
    }

    func dryRunEditedYAML(for selection: ClusterWorkspaceResourceSelection) {
        guard !isApplyingYAML else { return }
        isApplyingYAML = true
        applyResult = nil
        let snapshot = editedYAML

        Task { [weak self] in
            guard let self else { return }
            let result = await yamlApplier.dryRun(
                yaml: snapshot,
                context: context,
                namespace: selection.row.namespace
            )
            await MainActor.run {
                self.isApplyingYAML = false
                self.applyResult = result
                self.dryRunValidatedYAML = result.success ? snapshot : nil
                try? self.auditLog.record(AuditEvent(
                    type: .yamlDryRun,
                    contextName: self.context.contextName,
                    message: "\(selection.kind.rawValue)/\(selection.row.name) in \(selection.row.namespace ?? "-"): \(result.message)"
                ))
            }
        }
    }

    /// Apply is only reachable from the UI once a dry-run against this exact
    /// edit has succeeded (`dryRunValidatedYAML == editedYAML`); this guard is
    /// defense-in-depth against calling it any other way.
    func applyEditedYAML(for selection: ClusterWorkspaceResourceSelection) {
        guard !isApplyingYAML, dryRunValidatedYAML == editedYAML else { return }
        isApplyingYAML = true

        Task { [weak self] in
            guard let self else { return }
            let result = await yamlApplier.apply(
                yaml: editedYAML,
                context: context,
                namespace: selection.row.namespace
            )
            await MainActor.run {
                self.isApplyingYAML = false
                self.applyResult = result
                try? self.auditLog.record(AuditEvent(
                    type: result.success ? .yamlApplied : .yamlApplyFailed,
                    contextName: self.context.contextName,
                    message: "\(selection.kind.rawValue)/\(selection.row.name) in \(selection.row.namespace ?? "-"): \(result.message)"
                ))
                if result.success {
                    self.previousBaselineYAML = self.yamlResult?.yaml
                    self.isEditingYAML = false
                    self.dryRunValidatedYAML = nil
                    self.loadResource(kind: selection.kind, bypassCache: true)
                    self.loadYAML(for: selection)
                }
            }
        }
    }

    func rollbackYAML(for selection: ClusterWorkspaceResourceSelection) {
        guard let rollbackText = previousBaselineYAML, !isApplyingYAML else { return }
        isApplyingYAML = true

        Task { [weak self] in
            guard let self else { return }
            let result = await yamlApplier.apply(
                yaml: rollbackText,
                context: context,
                namespace: selection.row.namespace
            )
            await MainActor.run {
                self.isApplyingYAML = false
                self.applyResult = result
                try? self.auditLog.record(AuditEvent(
                    type: result.success ? .yamlRolledBack : .yamlApplyFailed,
                    contextName: self.context.contextName,
                    message: "\(selection.kind.rawValue)/\(selection.row.name) in \(selection.row.namespace ?? "-"): \(result.message)"
                ))
                if result.success {
                    self.previousBaselineYAML = nil
                    self.loadResource(kind: selection.kind, bypassCache: true)
                    self.loadYAML(for: selection)
                }
            }
        }
    }
}
