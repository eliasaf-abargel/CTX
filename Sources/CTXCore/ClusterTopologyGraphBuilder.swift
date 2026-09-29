import Foundation

/// Assembles `ClusterTopologyGraph` from the resource rows the workspace has
/// already loaded, deriving every edge from a field Kubernetes itself owns.
public enum ClusterTopologyGraphBuilder {
    /// Builds the graph from the rows already loaded by the workspace. Pure and
    /// synchronous so it can run off the main actor and be asserted on in tests.
    public static func build(
        services: [KubernetesResourceRow],
        workloads: [KubernetesResourceRow],
        pods: [KubernetesResourceRow],
        ingress: [KubernetesResourceRow],
        pvcs: [KubernetesResourceRow],
        hpas: [KubernetesResourceRow],
        diagnostics: KubernetesDiagnosticReport? = nil,
        isCancelled: () -> Bool = { false }
    ) -> ClusterTopologyGraph {
        var nodes: [TopologyGraphNode] = []
        var edges: [TopologyGraphEdge] = []
        guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }

        let podIndex = TopologyLabelIndex(rows: pods, isCancelled: isCancelled) {
            KubernetesRelatedPods.parseSelector($0.cells["Labels"] ?? "")
        }
        guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
        var podHealth: [String: TopologyNodeHealthState] = [:]
        for pod in pods {
            guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
            podHealth[pod.id] = TopologyFailureEvaluator.evaluatePod(cells: pod.cells)
        }

        // Pods first: everything else attaches to them, and their health rolls up.
        for pod in pods {
            guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
            let health = podHealth[pod.id] ?? .healthy
            let issues = diagnostics?.issuesByResourceID[pod.id]?.count ?? 0
            nodes.append(TopologyGraphNode(
                id: TopologyGraphNode.id(kind: .pod, rowID: pod.id),
                kind: .pod,
                name: pod.name,
                namespace: pod.ns,
                subtitle: "\(pod.cells["Status"] ?? "-") · \(pod.cells["Ready"] ?? "-") ready · \(pod.cells["Restarts"] ?? "0") restarts",
                health: health,
                row: pod,
                issueCount: issues
            ))
        }

        // Workloads own pods through ownerReferences — exact, and it survives two
        // Deployments sharing an `app=` label (canary/stable), which selector
        // cross-matching silently merged into one.
        let workloadsByKey = Dictionary(workloads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var podsByWorkload: [String: [KubernetesResourceRow]] = [:]
        guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }

        for pod in pods {
            guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
            guard let owner = TopologyRowReferences.owner(of: pod, workloadsByKey: workloadsByKey) else { continue }
            podsByWorkload[owner.id, default: []].append(pod)
        }

        var workloadHealthByKey: [String: TopologyNodeHealthState] = [:]
        guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
        for workload in workloads {
            guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
            workloadHealthByKey[workload.id] = TopologyFailureEvaluator.evaluateWorkload(
                cells: workload.cells,
                podsHealth: (podsByWorkload[workload.id] ?? []).compactMap { podHealth[$0.id] }
            )
        }

        for workload in workloads {
            guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
            let owned = podsByWorkload[workload.id] ?? []
            let health = workloadHealthByKey[workload.id] ?? .healthy
            let id = TopologyGraphNode.id(kind: .workload, rowID: workload.id)
            let issues = diagnostics?.issuesByResourceID[workload.id]?.count ?? 0
            nodes.append(TopologyGraphNode(
                id: id,
                kind: .workload,
                name: workload.name,
                namespace: workload.ns,
                subtitle: "\(workload.cells["Kind"] ?? "Workload") · \(workload.cells["Ready"] ?? "-") ready",
                health: health,
                row: workload,
                issueCount: issues
            ))
            for pod in owned {
                guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
                edges.append(TopologyGraphEdge(
                    source: id,
                    target: TopologyGraphNode.id(kind: .pod, rowID: pod.id),
                    kind: .owns
                ))
            }
        }

        // Services. Two edges come out of one: the workload the Service fronts
        // (which survives a scale-to-zero), and any pod it reaches that that
        // workload doesn't already account for.
        let workloadIndex = TopologyLabelIndex(rows: workloads, isCancelled: isCancelled) {
            KubernetesRelatedPods.parseSelector($0.cells["Selector"] ?? "")
        }

        var serviceHealthByKey: [String: TopologyNodeHealthState] = [:]
        for service in services {
            guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
            let selector = KubernetesRelatedPods.parseSelector(service.cells["Selector"] ?? "")
            let matched = podIndex.matching(namespace: service.ns, selector: selector)
            let activeMatched = matched.filter { podHealth[$0.id]?.isIdle != true }

            // A workload serves a Service when its own pod template carries
            // every label the Service selects on — the same subset test the
            // kube-proxy endpoint controller effectively performs, one level up.
            let targeted = workloadIndex.matching(namespace: service.ns, selector: selector)
            let targetedHealth = targeted.compactMap { workloadHealthByKey[$0.id] }

            let backendHealth = activeMatched.isEmpty
                ? TopologyHealthRollup.serviceBackend(targetedHealth)
                : TopologyHealthRollup.worst(activeMatched.compactMap { podHealth[$0.id] })
            let health = TopologyFailureEvaluator.evaluateService(
                cells: service.cells,
                matchedPodsCount: activeMatched.count,
                workloadHealth: backendHealth
            )
            serviceHealthByKey[service.id] = health
            let id = TopologyGraphNode.id(kind: .service, rowID: service.id)
            let issues = diagnostics?.issuesByResourceID[service.id]?.count ?? 0
            nodes.append(TopologyGraphNode(
                id: id,
                kind: .service,
                name: service.name,
                namespace: service.ns,
                subtitle: "\(service.cells["Type"] ?? "ClusterIP") · \(service.cells["Ports"] ?? "no ports") · \(activeMatched.count) endpoint\(activeMatched.count == 1 ? "" : "s")",
                health: health,
                row: service,
                issueCount: issues
            ))

            var reachedViaWorkload = Set<String>()
            for workload in targeted {
                guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
                edges.append(TopologyGraphEdge(
                    source: id,
                    target: TopologyGraphNode.id(kind: .workload, rowID: workload.id),
                    kind: .targets
                ))
                for pod in podsByWorkload[workload.id] ?? [] {
                    guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
                    reachedViaWorkload.insert(pod.id)
                }
            }
            for pod in activeMatched where !reachedViaWorkload.contains(pod.id) {
                guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
                edges.append(TopologyGraphEdge(
                    source: id,
                    target: TopologyGraphNode.id(kind: .pod, rowID: pod.id),
                    kind: .selects
                ))
            }
        }

        // Ingress → Service by the backend name in the rule, scoped to the
        // ingress's own namespace (a backend name only ever resolves in-namespace).
        let servicesByKey = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for route in ingress {
            guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
            let backends = TopologyRowReferences.names(in: route.cells["Services"])
            let resolved = backends.compactMap { servicesByKey["\(route.ns)/\($0)"] }
            let hosts = route.cells["Hosts"] ?? ""
            let id = TopologyGraphNode.id(kind: .ingress, rowID: route.id)
            let issues = diagnostics?.issuesByResourceID[route.id]?.count ?? 0
            nodes.append(TopologyGraphNode(
                id: id,
                kind: .ingress,
                name: route.name,
                namespace: route.ns,
                subtitle: (hosts.isEmpty ? "*" : hosts) + (route.cells["TLS"] == "Yes" ? " · TLS" : ""),
                // An Ingress is as healthy as what it routes to — reusing the
                // verdict already computed for those Services rather than
                // re-deriving one that could disagree with the card next to it.
                health: resolved.isEmpty && !backends.isEmpty
                    ? .degraded(reason: "Backend service not found")
                    : TopologyHealthRollup.worst(resolved.compactMap { serviceHealthByKey[$0.id] }),
                row: route,
                issueCount: issues
            ))
            for service in resolved {
                guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
                edges.append(TopologyGraphEdge(
                    source: id,
                    target: TopologyGraphNode.id(kind: .service, rowID: service.id),
                    kind: .routes
                ))
            }
        }

        // Only PVCs some pod actually mounts become nodes. The old model attached
        // every PVC in the namespace to every service in it — one 4-PVC namespace
        // with 10 services rendered 40 storage cards for 4 volumes.
        let pvcsByKey = Dictionary(pvcs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var mountedPVCs: [String: KubernetesResourceRow] = [:]
        for pod in pods {
            guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
            for claim in TopologyRowReferences.names(in: pod.cells["PVCs"]) {
                guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
                guard let pvc = pvcsByKey["\(pod.ns)/\(claim)"] else { continue }
                mountedPVCs[pvc.id] = pvc
                edges.append(TopologyGraphEdge(
                    source: TopologyGraphNode.id(kind: .pod, rowID: pod.id),
                    target: TopologyGraphNode.id(kind: .pvc, rowID: pvc.id),
                    kind: .mounts
                ))
            }
        }
        for pvc in mountedPVCs.values {
            guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
            let bound = pvc.cells["Status"] == "Bound"
            let issues = diagnostics?.issuesByResourceID[pvc.id]?.count ?? 0
            nodes.append(TopologyGraphNode(
                id: TopologyGraphNode.id(kind: .pvc, rowID: pvc.id),
                kind: .pvc,
                name: pvc.name,
                namespace: pvc.ns,
                subtitle: "\(pvc.cells["Capacity"] ?? "-") · \(pvc.cells["StorageClass"] ?? "-")",
                health: bound ? .healthy : .degraded(reason: pvc.cells["Status"] ?? "Unbound"),
                row: pvc,
                issueCount: issues
            ))
        }

        // HPA → its scale target. Dropped when the target isn't loaded, rather
        // than drawn floating with nothing on the other end.
        for hpa in hpas {
            guard !isCancelled() else { return ClusterTopologyGraph(nodes: [], edges: []) }
            let reference = hpa.cells["Reference"] ?? ""
            guard let slash = reference.firstIndex(of: "/") else { continue }
            let targetName = String(reference[reference.index(after: slash)...])
            guard let workload = workloadsByKey["\(hpa.ns)/\(targetName)"] else { continue }
            let id = TopologyGraphNode.id(kind: .hpa, rowID: hpa.id)
            let issues = diagnostics?.issuesByResourceID[hpa.id]?.count ?? 0
            nodes.append(TopologyGraphNode(
                id: id,
                kind: .hpa,
                name: hpa.name,
                namespace: hpa.ns,
                subtitle: "\(hpa.cells["Replicas"] ?? "?") now · \(hpa.cells["MinPods"] ?? "?")–\(hpa.cells["MaxPods"] ?? "?")",
                health: .healthy,
                row: hpa,
                issueCount: issues
            ))
            edges.append(TopologyGraphEdge(
                source: id,
                target: TopologyGraphNode.id(kind: .workload, rowID: workload.id),
                kind: .scales
            ))
        }

        return ClusterTopologyGraph(nodes: nodes, edges: edges)
    }
}
