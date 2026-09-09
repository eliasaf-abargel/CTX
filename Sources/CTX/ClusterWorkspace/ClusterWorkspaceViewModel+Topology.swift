import CTXCore
import Foundation

extension ClusterWorkspaceViewModel {
    /// The lists the map's structure is built from. Ingress, HPAs and PVCs only
    /// decorate it, so the map is honest before they arrive.
    static let topologySourceSections: [ClusterWorkspaceSection] = [.services, .workloads, .pods]

    /// True once every list the structure needs has come back — reachable or
    /// not. Until then an empty graph says nothing about the namespace.
    var hasLoadedTopologySources: Bool {
        Self.topologySourceSections.allSatisfy {
            !isLoading(section: $0) && resourceList(for: $0) != nil
        }
    }

    /// The map has nothing to show *yet*, as opposed to nothing to show. The
    /// pane owes the user a skeleton for as long as this holds — most visibly
    /// right after a namespace switch, when the graph has been cleared and the
    /// replacement rows have not been asked for yet.
    var isTopologyPending: Bool {
        isBuildingTopology || !hasLoadedTopologySources || !hasResolvedTopology
    }

    func loadTopologyResources() {
        loadResource(kind: .services, bypassCache: false)
        loadResource(kind: .workloads, bypassCache: false, priority: .background)
        loadResource(kind: .pods, bypassCache: false, priority: .background)
        loadResource(kind: .ingress, bypassCache: false, priority: .background)
        loadResource(kind: .hpa, bypassCache: false, priority: .background)
        loadResource(kind: .pvc, bypassCache: false, priority: .background)
        recalculateTopology()
    }

    /// Rebuilds one source graph from the loaded rows, then publishes its bounded
    /// projection for both the canvas and inspector.
    func recalculateTopology() {
        guard selectedSection == .topology || !topologyGraph.isEmpty else { return }
        topologyBuildGeneration += 1
        let generation = topologyBuildGeneration
        topologyBuildTask?.cancel()

        let services = resourceList(for: .services)?.rows ?? []
        let workloads = resourceList(for: .workloads)?.rows ?? []
        let pods = resourceList(for: .pods)?.rows ?? []
        let ingress = resourceList(for: .ingress)?.rows ?? []
        let pvcs = resourceList(for: .storage)?.rows ?? []
        let hpas = resourceList(for: .hpa)?.rows ?? []

        guard !services.isEmpty || !workloads.isEmpty || !pods.isEmpty else {
            topologyGraph = ClusterTopologyGraph(nodes: [], edges: [])
            topologyProjection = nil
            isBuildingTopology = false
            // No rows and every source list already in: the namespace really is
            // empty. No rows because they have not arrived: keep waiting.
            hasResolvedTopology = hasLoadedTopologySources
            return
        }

        isBuildingTopology = true
        let expansion = topologyExpansionState
        let persistedSearchNodeIDs = topologySearchNodeIDs
        let selector = TopologySelector(topologySelectorText)
        topologyBuildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let sourceGraph = ClusterTopologyGraphBuilder.build(
                services: services,
                workloads: workloads,
                pods: pods,
                ingress: ingress,
                pvcs: pvcs,
                hpas: hpas,
                isCancelled: { Task.isCancelled }
            )
            guard !Task.isCancelled else { return }
            let searchNodeIDs = selector?.resolve(in: sourceGraph) ?? persistedSearchNodeIDs
            let projection = TopologyRelevanceProjector.project(
                sourceGraph,
                expansion: expansion,
                searchNodeIDs: searchNodeIDs,
                focusedNodeID: nil
            )
            guard !Task.isCancelled else { return }
            await self?.publishTopology(
                projection,
                generation: generation,
                searchNodeIDs: searchNodeIDs
            )
        }
    }

    func expandTopologyGroup(_ groupID: String) {
        guard topologyProjection?.groupsByNodeID[groupID] != nil else { return }
        topologyExpansionState.expand(groupID)
        recalculateTopology()
    }

    func resetTopologyExpansion() {
        guard !topologyExpansionState.batchesByGroupID.isEmpty else { return }
        topologyExpansionState = TopologyExpansionState()
        recalculateTopology()
    }

    func collapseTopologyGroup(_ groupID: String) {
        guard topologyExpansionState.batchCount(for: groupID) > 0 else { return }
        topologyExpansionState.collapse(groupID)
        recalculateTopology()
    }

    func setTopologySelector(_ raw: String) {
        guard raw != topologySelectorText else { return }
        topologySelectorText = raw
        if let selector = TopologySelector(raw), let topologyProjection {
            topologySearchNodeIDs = topologyProjection.selectorNodeIDs(selector)
        } else {
            topologySearchNodeIDs = []
        }
        recalculateTopology()
    }

    /// Drops the map and stops the build behind it.
    ///
    /// Called when the namespace changes. Clearing the published graph and
    /// projection is the point: while the new rows load, the pane must not be
    /// able to inspect — or start a port forward against — a Service that
    /// belongs to the namespace the user just left. Bumping the generation
    /// retires any build already in flight, whose result would otherwise
    /// repopulate the graph this just emptied.
    func resetTopology() {
        topologyBuildTask?.cancel()
        topologyBuildTask = nil
        topologyBuildGeneration += 1
        isBuildingTopology = false
        hasResolvedTopology = false
        topologyGraph = ClusterTopologyGraph(nodes: [], edges: [])
        topologyProjection = nil
        topologyExpansionState = TopologyExpansionState()
        topologySearchNodeIDs = []
        topologySelectorText = ""
        topologyScopeID = UUID()
    }

    private func publishTopology(
        _ projection: TopologyProjection,
        generation: Int,
        searchNodeIDs: Set<String>
    ) {
        guard generation == topologyBuildGeneration, !Task.isCancelled else { return }
        topologyProjection = projection
        topologySearchNodeIDs = searchNodeIDs
        // Layout consumers only ever receive the bounded projection.
        topologyGraph = projection.graph
        topologyBuildTask = nil
        isBuildingTopology = false
        hasResolvedTopology = true
    }
}
