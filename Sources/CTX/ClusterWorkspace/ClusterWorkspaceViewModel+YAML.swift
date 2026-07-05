import CTXCore
import Foundation

extension ClusterWorkspaceViewModel {
    func loadYAML(for selection: ClusterWorkspaceResourceSelection) {
        yamlTask?.cancel()
        yamlResult = nil
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
}
