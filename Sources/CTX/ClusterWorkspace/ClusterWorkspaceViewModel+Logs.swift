import CTXCore
import Foundation

extension ClusterWorkspaceViewModel {
    var selectedLogPodRow: KubernetesResourceRow? {
        guard let id = selectedLogPodID else { return nil }
        return resourceList(for: .pods)?.rows.first { $0.id == id }
    }

    func selectLogPod(_ row: KubernetesResourceRow) {
        let ref = row.reference(kind: .pods, context: context)
        guard let namespace = ref.namespace else { return }
        selectedLogPodID = row.id
        selectedLogContainer = nil
        logContainers = []
        logsResult = nil
        logsTask?.cancel()
        logsTask = Task { [weak self] in
            guard let self else { return }
            let containers = await logsReader.containers(namespace: namespace, pod: ref.name, context: context)
            guard !Task.isCancelled else { return }
            logContainers = containers
            selectedLogContainer = containers.first
            await loadLogs(namespace: namespace, pod: ref.name, container: containers.first)
        }
    }

    func selectLogContainer(_ container: String) {
        selectedLogContainer = container
        reloadLogs()
    }

    func setLogTailLines(_ lines: Int) {
        guard logTailLines != lines else { return }
        logTailLines = lines
        reloadLogs()
    }

    func reloadLogs() {
        guard let row = selectedLogPodRow else { return }
        let ref = row.reference(kind: .pods, context: context)
        guard let namespace = ref.namespace else { return }
        logsTask?.cancel()
        let container = selectedLogContainer
        logsTask = Task { [weak self] in
            guard let self else { return }
            await loadLogs(namespace: namespace, pod: ref.name, container: container)
        }
    }

    func loadLogs(namespace: String, pod: String, container: String?) async {
        isLoadingLogs = true
        let result = await logsReader.logs(namespace: namespace, pod: pod, container: container, tailLines: logTailLines, context: context)
        guard !Task.isCancelled else { return }
        logsResult = result
        isLoadingLogs = false
    }
}
