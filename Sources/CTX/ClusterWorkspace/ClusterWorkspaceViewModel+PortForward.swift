import CTXCore
import Foundation

extension ClusterWorkspaceViewModel {
    func loadServicesForPortForward(bypassCache: Bool = false) {
        loadResource(kind: .services, bypassCache: bypassCache) { [weak self] list in
            guard let self, selectedPortForwardServiceID == nil, let first = list.rows.first else { return }
            selectPortForwardService(first)
        }
    }

    func selectPortForwardService(_ row: KubernetesResourceRow) {
        selectedPortForwardServiceID = row.id
        if let remotePort = firstServicePort(row) {
            portForwardRemotePort = "\(remotePort)"
            portForwardLocalPort = remotePort < 1024 ? "8080" : "\(remotePort)"
        }
    }

    var selectedPortForwardServiceRow: KubernetesResourceRow? {
        guard let selectedPortForwardServiceID else { return nil }
        return resourceList(for: .services)?.rows.first { $0.id == selectedPortForwardServiceID }
    }

    func startPortForward() {
        guard !isStartingPortForward, let row = selectedPortForwardServiceRow else { return }
        let ref = row.reference(kind: .services, context: context)
        guard let namespace = ref.namespace else { return }
        let localPort = Int(portForwardLocalPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let remotePort = Int(portForwardRemotePort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        isStartingPortForward = true
        portForwardIssue = nil
        let request = KubernetesPortForwardRequest(namespace: namespace, targetKind: .service, targetName: ref.name, localPort: localPort, remotePort: remotePort)
        
        Task { [weak self] in
            guard let self else { return }
            let session = await portForwardService.start(context: context, request: request, onTerminate: { [weak self] id in
                guard let self else { return }
                Task { @MainActor in
                    self.handlePortForwardTerminated(sessionID: id)
                }
            })
            guard !Task.isCancelled else { return }
            if session.status == .running {
                let inserted = self.checkAndInsertPortForwardSession(session, refName: ref.name)
                if !inserted {
                    await portForwardService.stop(sessionID: session.id)
                }
            } else {
                portForwardIssue = session.diagnostic
            }
            isStartingPortForward = false
        }
    }

    func stopPortForward(_ session: KubernetesPortForwardSession) {
        Task { [weak self] in
            guard let self else { return }
            await portForwardService.stop(sessionID: session.id)
            self.handlePortForwardTerminated(sessionID: session.id)
        }
    }

    private func firstServicePort(_ row: KubernetesResourceRow) -> Int? {
        let ports = row.cells["Ports"] ?? ""
        let first = ports.split(separator: ",").first?.split(separator: "/").first ?? ""
        return Int(first.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
