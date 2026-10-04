import CTXCore
import Foundation

func pod(_ name: String, cells extra: [String: String], warning: Bool = false) -> KubernetesResourceRow {
    var cells = ["Namespace": "shop", "Name": name, "Status": "Running", "Restarts": "0"]
    cells.merge(extra) { _, new in new }
    return KubernetesResourceRow(id: "shop/\(name)", cells: cells, warning: warning)
}

/// A fully-declared, healthy pod is the only thing that scores 100.
func testHygieneScoreRewardsFullyDeclaredHealthyPods() throws {
    let healthy = pod("api", cells: [
        "CPU Request Cores": "0.25", "Memory Request Bytes": "536870912", "Memory Limit": "1073741824"
    ])
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: healthy) == 100)

    // Each omission costs, and they accumulate.
    let noRequests = pod("api", cells: ["Memory Limit": "1073741824"])
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: noRequests) == 70, "got \(KubernetesRemediationAdvisor.workloadHygieneScore(pod: noRequests))")

    let nothingDeclared = pod("api", cells: [:])
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: nothingDeclared) == 60)

    let crashing = pod("api", cells: [
        "Status": "CrashLoopBackOff", "Restarts": "12",
        "CPU Request Cores": "0.25", "Memory Request Bytes": "1", "Memory Limit": "1"
    ], warning: true)
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: crashing) == 40)
}

/// The display cells now render an em dash for an undeclared request. The score used
/// to test for the ASCII "-", so after that change unset requests silently stopped
/// costing anything and every cluster's score drifted upward.
func testHygieneScoreReadsRawRequestsNotDisplayCells() throws {
    let displayOnly = pod("api", cells: [
        "CPU": KubernetesGitOpsService.unknownValue,
        "Memory": KubernetesGitOpsService.unknownValue
    ])
    // No raw request cells → the omission is still counted.
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: displayOnly) == 60,
           "got \(KubernetesRemediationAdvisor.workloadHygieneScore(pod: displayOnly))")
}

/// Workload rows carry no CPU or memory cells — the workloads list never asks for
/// them — so including them penalised every workload for data that was never
/// fetched, dragging the cluster score down by construction.
func testHygieneScoreIsPodsOnly() throws {
    let pods = [
        pod("a", cells: ["CPU Request Cores": "0.1", "Memory Request Bytes": "1", "Memory Limit": "1"]),
        pod("b", cells: ["CPU Request Cores": "0.1", "Memory Request Bytes": "1", "Memory Limit": "1"])
    ]
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pods: pods) == 100)

    // A workload-shaped row (no request cells at all) would score 60; it must not be
    // able to reach the cluster figure.
    let workloadShaped = KubernetesResourceRow(
        id: "shop/web", cells: ["Namespace": "shop", "Kind": "Deployment", "Name": "web", "Ready": "3/3"]
    )
    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pod: workloadShaped) < 100)

    assert(KubernetesRemediationAdvisor.workloadHygieneScore(pods: []) == 100, "no pods is not a failing cluster")
}

func testTopologyFailureEvaluatorPodFailures() {
    let crashingPod = TopologyFailureEvaluator.evaluatePod(cells: ["Status": "CrashLoopBackOff (Exit Code 137)", "Restarts": "14", "Ready": "0/1"])
    assert(crashingPod.isFailed)
    if case .failed(let reason, _, let exitCode, let restarts) = crashingPod {
        assert(reason.contains("CrashLoopBackOff"))
        assert(restarts == 14)
        assert(exitCode == 137)
    }

    let healthyPod = TopologyFailureEvaluator.evaluatePod(cells: ["Status": "Running", "Restarts": "0", "Ready": "1/1"])
    assert(healthyPod.isHealthy)

    for terminalStatus in ["Succeeded", "Completed"] {
        let terminal = TopologyFailureEvaluator.evaluatePod(cells: [
            "Status": terminalStatus, "Restarts": "0", "Ready": "0/1"
        ])
        assert(terminal.isIdle, "\(terminalStatus) must be idle before Ready evaluation")
    }
}

func testTopologyFailureEvaluatorServiceFailures() {
    let serviceNoPods = TopologyFailureEvaluator.evaluateService(cells: ["Selector": "app=missing"], matchedPodsCount: 0, workloadHealth: .healthy)
    assert(serviceNoPods.isFailed)
    if case .failed(let reason, _, _, _) = serviceNoPods {
        assert(reason == "No Target Endpoints")
    }
}

// MARK: - Cluster map graph

/// A cluster shaped like the ones the old map got wrong: two Deployments in one
/// namespace sharing an `app=shop` label (canary + stable), one Service in front
/// of both, a second Service selecting only the canary, one Ingress naming one
/// backend, one PVC mounted by exactly one pod, and an HPA on the stable
/// Deployment.
private func sampleMapRows() -> (
    services: [KubernetesResourceRow],
    workloads: [KubernetesResourceRow],
    pods: [KubernetesResourceRow],
    ingress: [KubernetesResourceRow],
    pvcs: [KubernetesResourceRow],
    hpas: [KubernetesResourceRow]
) {
    let services = [
        KubernetesResourceRow(id: "shop/shop-web", cells: [
            "Namespace": "shop", "Name": "shop-web", "Type": "ClusterIP",
            "Ports": "80/TCP", "Selector": "app=shop"
        ]),
        KubernetesResourceRow(id: "shop/shop-canary", cells: [
            "Namespace": "shop", "Name": "shop-canary", "Type": "ClusterIP",
            "Ports": "80/TCP", "Selector": "app=shop,track=canary"
        ])
    ]
    let workloads = [
        KubernetesResourceRow(id: "shop/shop-stable", cells: [
            "Namespace": "shop", "Name": "shop-stable", "Kind": "Deployment",
            "Ready": "1/1", "Selector": "app=shop"
        ]),
        KubernetesResourceRow(id: "shop/shop-canary", cells: [
            "Namespace": "shop", "Name": "shop-canary", "Kind": "Deployment",
            "Ready": "1/1", "Selector": "app=shop"
        ])
    ]
    let pods = [
        KubernetesResourceRow(id: "shop/shop-stable-aaa", cells: [
            "Namespace": "shop", "Name": "shop-stable-aaa", "Status": "Running",
            "Ready": "1/1", "Restarts": "0", "Labels": "app=shop",
            "Owner": "ReplicaSet/shop-stable-7d9f8b6c5 -> Deployment/shop-stable",
            "PVCs": "shop-data"
        ]),
        KubernetesResourceRow(id: "shop/shop-canary-bbb", cells: [
            "Namespace": "shop", "Name": "shop-canary-bbb", "Status": "Running",
            "Ready": "1/1", "Restarts": "0", "Labels": "app=shop,track=canary",
            "Owner": "ReplicaSet/shop-canary-5c4d3e2f1 -> Deployment/shop-canary",
            "PVCs": ""
        ])
    ]
    let ingress = [
        KubernetesResourceRow(id: "shop/shop-ingress", cells: [
            "Namespace": "shop", "Name": "shop-ingress", "Hosts": "shop.example.com",
            "TLS": "Yes", "Services": "shop-web"
        ])
    ]
    let pvcs = [
        KubernetesResourceRow(id: "shop/shop-data", cells: [
            "Namespace": "shop", "Name": "shop-data", "Status": "Bound", "Capacity": "10Gi"
        ]),
        // Exists in the namespace but nobody mounts it — must not appear.
        KubernetesResourceRow(id: "shop/orphan-data", cells: [
            "Namespace": "shop", "Name": "orphan-data", "Status": "Bound", "Capacity": "1Gi"
        ])
    ]
    let hpas = [
        KubernetesResourceRow(id: "shop/shop-hpa", cells: [
            "Namespace": "shop", "Name": "shop-hpa", "Reference": "Deployment/shop-stable",
            "MinPods": "1", "MaxPods": "5", "Replicas": "1"
        ])
    ]
    return (services, workloads, pods, ingress, pvcs, hpas)
}

private func buildSampleMap() -> ClusterTopologyGraph {
    let rows = sampleMapRows()
    return ClusterTopologyGraphBuilder.build(
        services: rows.services,
        workloads: rows.workloads,
        pods: rows.pods,
        ingress: rows.ingress,
        pvcs: rows.pvcs,
        hpas: rows.hpas
    )
}

func testMapDrawsEveryObjectExactlyOnce() {
    let graph = buildSampleMap()
    assert(Set(graph.nodes.map(\.id)).count == graph.nodes.count)
    // 2 services + 2 workloads + 2 pods + 1 ingress + 1 mounted PVC + 1 HPA.
    assert(graph.nodes.count == 9, "expected 9 nodes, got \(graph.nodes.count)")
}

func testMapKeepsAPodSharedByTwoServices() {
    let graph = buildSampleMap()
    let canaryPod = TopologyGraphNode.id(kind: .pod, rowID: "shop/shop-canary-bbb")
    // Both `shop-web` (app=shop) and `shop-canary` (app=shop,track=canary) reach
    // this pod — the old builder dropped whichever service it visited second, so
    // the pod appeared under one of them and vanished from the other.
    for service in ["shop/shop-web", "shop/shop-canary"] {
        let id = TopologyGraphNode.id(kind: .service, rowID: service)
        assert(graph.lineage(of: id).contains(canaryPod), "\(service) cannot reach the canary pod")
    }
    // …and it is still exactly one node.
    assert(graph.nodes.filter { $0.id == canaryPod }.count == 1)
}

/// A Service whose Deployment sits at `replicas: 0` has no endpoints by design.
/// Reporting that as a failure is what turned a cluster with 87 parked workloads
/// into a map that was almost entirely red.
func testMapTreatsScaledToZeroAsIdleNotBroken() {
    let service = KubernetesResourceRow(id: "parked/api", cells: [
        "Namespace": "parked", "Name": "api", "Type": "ClusterIP", "Selector": "app=api"
    ])
    let workload = KubernetesResourceRow(id: "parked/api", cells: [
        "Namespace": "parked", "Name": "api", "Kind": "Deployment",
        "Ready": "0/0", "Selector": "app=api"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [workload], pods: [], ingress: [], pvcs: [], hpas: []
    )
    let serviceNode = graph.node(TopologyGraphNode.id(kind: .service, rowID: "parked/api"))
    let workloadNode = graph.node(TopologyGraphNode.id(kind: .workload, rowID: "parked/api"))
    assert(workloadNode?.health.isIdle == true, "got \(String(describing: workloadNode?.health))")
    assert(serviceNode?.health.isIdle == true, "got \(String(describing: serviceNode?.health))")
    assert(serviceNode?.health.needsAttention == false)
    // And the chain still holds with zero pods to bridge it.
    let targets = graph.edges.filter { $0.kind == .targets }
    assert(targets.count == 1, "expected the Service→Deployment edge to survive scale-to-zero")
}

/// A Service with a selector nothing answers, and no workload behind it either,
/// is still a real fault — idle must not swallow the genuine case.
func testMapStillFlagsAServiceWithNoBackendAtAll() {
    let service = KubernetesResourceRow(id: "n/orphan", cells: [
        "Namespace": "n", "Name": "orphan", "Type": "ClusterIP", "Selector": "app=gone"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [], pods: [], ingress: [], pvcs: [], hpas: []
    )
    assert(graph.node(TopologyGraphNode.id(kind: .service, rowID: "n/orphan"))?.health.isFailed == true)
}

func testMapUsesOwnerReferencesNotSharedLabels() {
    let graph = buildSampleMap()
    let stable = TopologyGraphNode.id(kind: .workload, rowID: "shop/shop-stable")
    let owned = graph.edgesOut(stable).filter { $0.kind == .owns }.map(\.target)
    // Both Deployments carry `app=shop`; only the ownerReference tells them apart.
    assert(owned == [TopologyGraphNode.id(kind: .pod, rowID: "shop/shop-stable-aaa")], "got \(owned)")
}

func testMapOnlyLinksVolumesThatAreActuallyMounted() {
    let graph = buildSampleMap()
    assert(graph.node(TopologyGraphNode.id(kind: .pvc, rowID: "shop/orphan-data")) == nil)
    let mounts = graph.edges.filter { $0.kind == .mounts }
    assert(mounts.count == 1, "expected 1 mount edge, got \(mounts.count)")
    assert(mounts[0].source == TopologyGraphNode.id(kind: .pod, rowID: "shop/shop-stable-aaa"))
}

func testMapRoutesIngressToItsNamedBackendOnly() {
    let graph = buildSampleMap()
    let routes = graph.edgesOut(TopologyGraphNode.id(kind: .ingress, rowID: "shop/shop-ingress"))
    assert(routes.count == 1)
    assert(routes[0].target == TopologyGraphNode.id(kind: .service, rowID: "shop/shop-web"))
}

func testMapLineageReachesTheWholeChain() {
    let graph = buildSampleMap()
    let lineage = graph.lineage(of: TopologyGraphNode.id(kind: .ingress, rowID: "shop/shop-ingress"))
    // Ingress → shop-web → both pods → their Deployments → the PVC and the HPA.
    assert(lineage.count == 9, "expected the whole connected component, got \(lineage.count)")
    // A pod's own lineage must not pull in unrelated namespaces' objects.
    assert(graph.lineage(of: TopologyGraphNode.id(kind: .pvc, rowID: "shop/shop-data")).count == 9)
}

/// dbt's selector syntax is how you interrogate a lineage graph. Getting the
/// direction wrong would silently answer the opposite question.
func testMapSelectorWalksTheRequestedDirection() {
    let graph = buildSampleMap()
    let web = TopologyGraphNode.id(kind: .service, rowID: "shop/shop-web")
    let ingress = TopologyGraphNode.id(kind: .ingress, rowID: "shop/shop-ingress")
    let stablePod = TopologyGraphNode.id(kind: .pod, rowID: "shop/shop-stable-aaa")

    // Bare term: just the match.
    assert(TopologySelector("shop-web")?.resolve(in: graph) == [web])

    // `name+` reaches what depends on it, not what it depends on.
    let downstream = TopologySelector("shop-web+")?.resolve(in: graph) ?? []
    assert(downstream.contains(stablePod), "shop-web+ should reach its pods")
    assert(!downstream.contains(ingress), "shop-web+ must not walk back up to the Ingress")

    // `+name` is the mirror image.
    let upstream = TopologySelector("+shop-web")?.resolve(in: graph) ?? []
    assert(upstream.contains(ingress), "+shop-web should reach the Ingress")
    assert(!upstream.contains(stablePod), "+shop-web must not walk down to the pods")

    // `+name+` is both directions at once. Note it is *not* the same as the
    // undirected connected component: dbt's `+model+` follows dependency
    // direction, so a sibling that merely shares a downstream pod is excluded.
    let both = TopologySelector("+shop-web+")?.resolve(in: graph) ?? []
    assert(both == graph.ancestors(of: web).union(graph.descendants(of: web)))
    assert(both.contains(ingress) && both.contains(stablePod))
    assert(both.isSubset(of: graph.lineage(of: web)))

    assert(TopologySelector("   ") == nil)
    assert(TopologySelector("+")  == nil)
    assert(TopologySelector("nothing-matches-this")?.resolve(in: graph).isEmpty == true)
}

/// A namespace whose pods are owned by a CRD we cannot resolve (Argo Workflows
/// is the real case) produced 140 objects joined by 16 edges — one endless
/// column of finished pods. Grouping turns that back into a map.
func testMapGroupsInterchangeableHealthyPods() {
    let workload = KubernetesResourceRow(id: "run/runner", cells: [
        "Namespace": "run", "Name": "runner", "Kind": "Deployment", "Ready": "20/20", "Selector": "app=runner"
    ])
    var pods: [KubernetesResourceRow] = (0..<20).map { i in
        KubernetesResourceRow(id: "run/runner-\(i)", cells: [
            "Namespace": "run", "Name": "runner-\(i)", "Status": "Running", "Ready": "1/1",
            "Restarts": "0", "Labels": "app=runner", "Owner": "Deployment/runner"
        ])
    }
    // One of them is broken.
    pods.append(KubernetesResourceRow(id: "run/runner-bad", cells: [
        "Namespace": "run", "Name": "runner-bad", "Status": "CrashLoopBackOff", "Ready": "0/1",
        "Restarts": "9", "Labels": "app=runner", "Owner": "Deployment/runner"
    ]))

    let raw = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods, ingress: [], pvcs: [], hpas: []
    )
    assert(raw.nodes.count == 22, "expected workload + 21 pods, got \(raw.nodes.count)")

    let grouped = TopologyRelevanceProjector.project(
        raw,
        options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    ).graph
    // workload + five visible healthy pods + one group + the crash-looping pod.
    assert(grouped.nodes.count == 8, "expected 8 nodes, got \(grouped.nodes.count)")

    let group = grouped.nodes.first { $0.kind == .podGroup }
    assert(group?.name == "15 pods", "got \(String(describing: group?.name))")

    // The broken pod must survive as its own clickable node.
    let broken = grouped.nodes.first { $0.kind == .pod && $0.health.isFailed }
    assert(broken?.name == "runner-bad")
    assert(broken?.health.isFailed == true)

    // And the chain still holds: the workload reaches both.
    let workloadID = TopologyGraphNode.id(kind: .workload, rowID: "run/runner")
    assert(grouped.edgesOut(workloadID).count == 7, "workload should manage visible pods, the group, and the broken pod")
}

/// Pods with different parents must never merge, or the map would claim a
/// relationship that does not exist.
func testMapNeverGroupsPodsWithDifferentParents() {
    let workloads = ["a", "b"].map { name in
        KubernetesResourceRow(id: "run/\(name)", cells: [
            "Namespace": "run", "Name": name, "Kind": "Deployment", "Ready": "8/8", "Selector": "app=\(name)"
        ])
    }
    let pods = ["a", "b"].flatMap { owner in
        (0..<8).map { i in
            KubernetesResourceRow(id: "run/\(owner)-\(i)", cells: [
                "Namespace": "run", "Name": "\(owner)-\(i)", "Status": "Running", "Ready": "1/1",
                "Restarts": "0", "Labels": "app=\(owner)", "Owner": "Deployment/\(owner)"
            ])
        }
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: workloads, pods: pods, ingress: [], pvcs: [], hpas: []
    )
    let grouped = TopologyRelevanceProjector.project(
        source,
        options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    ).graph

    assert(grouped.nodes.filter { $0.kind == .podGroup }.count == 2, "one group per owner")
    for workload in workloads {
        let id = TopologyGraphNode.id(kind: .workload, rowID: workload.id)
        assert(grouped.edgesOut(id).count == 6, "\(workload.name) should manage five pods and its own group")
    }
}

/// Below the threshold nothing is hidden — a three-replica Deployment still
/// shows its three pods.
func testMapLeavesSmallPodSetsAlone() {
    let workload = KubernetesResourceRow(id: "run/small", cells: [
        "Namespace": "run", "Name": "small", "Kind": "Deployment", "Ready": "3/3", "Selector": "app=small"
    ])
    let pods = (0..<3).map { i in
        KubernetesResourceRow(id: "run/small-\(i)", cells: [
            "Namespace": "run", "Name": "small-\(i)", "Status": "Running", "Ready": "1/1",
            "Restarts": "0", "Labels": "app=small", "Owner": "Deployment/small"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods, ingress: [], pvcs: [], hpas: []
    )
    let grouped = TopologyRelevanceProjector.project(
        source,
        options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    ).graph
    assert(grouped.nodes.filter { $0.kind == .podGroup }.isEmpty)
    assert(grouped.nodes.filter { $0.kind == .pod }.count == 3)
}

func testMapLayoutFlowsLeftToRight() {
    let graph = buildSampleMap()
    let layout = TopologyGraphLayout.layout(graph)
    assert(layout.positions.count == graph.nodes.count)
    for edge in graph.edges {
        guard let source = layout.positions[edge.source], let target = layout.positions[edge.target] else {
            assertionFailure("unpositioned edge \(edge.id)")
            continue
        }
        assert(source.x < target.x, "edge \(edge.id) points backwards")
    }
    assert(layout.size.width > 0 && layout.size.height > 0)
}

func testMapLayoutTerminatesOnACycle() {
    // A malformed graph must squash a column, not hang the app.
    let a = TopologyGraphNode(id: "a", kind: .service, name: "a", namespace: "n", subtitle: "", health: .healthy, row: KubernetesResourceRow(id: "n/a", cells: [:]))
    let b = TopologyGraphNode(id: "b", kind: .service, name: "b", namespace: "n", subtitle: "", health: .healthy, row: KubernetesResourceRow(id: "n/b", cells: [:]))
    let cyclic = ClusterTopologyGraph(
        nodes: [a, b],
        edges: [
            TopologyGraphEdge(source: "a", target: "b", kind: .routes),
            TopologyGraphEdge(source: "b", target: "a", kind: .routes)
        ]
    )
    assert(TopologyGraphLayout.layout(cyclic).positions.count == 2)
}

func testTopologyHitIndexMatchesRepresentativeLayoutFrames() {
    let graph = buildSampleMap()
    let layout = TopologyGraphLayout.layout(graph)
    let index = TopologyHitIndex(layout: layout)

    for node in graph.nodes {
        guard let frame = layout.frame(node.id) else {
            assertionFailure("missing frame for \(node.id)")
            continue
        }
        let samples = [
            CGPoint(x: frame.minX + 0.5, y: frame.minY + 0.5),
            CGPoint(x: frame.midX, y: frame.midY),
            CGPoint(x: frame.maxX - 0.5, y: frame.maxY - 0.5)
        ]
        for point in samples {
            let linear = graph.nodes.first {
                layout.frame($0.id)?.contains(point) == true
            }?.id
            assert(index.nodeID(at: point) == linear, "hit mismatch at \(point)")
        }
    }

    for point in [
        CGPoint.zero,
        CGPoint(x: layout.size.width + 1, y: layout.size.height + 1),
        CGPoint(x: TopologyGraphLayout.padding - 1, y: TopologyGraphLayout.padding)
    ] {
        let linear = graph.nodes.first {
            layout.frame($0.id)?.contains(point) == true
        }?.id
        assert(index.nodeID(at: point) == linear, "empty-space mismatch at \(point)")
    }
}

func testTopologyHitIndexMatchesLargeSyntheticLayout() {
    var layout = TopologyGraphLayout.Result()
    let columnStride = TopologyGraphLayout.nodeWidth + TopologyGraphLayout.columnGap
    let rowStride = TopologyGraphLayout.nodeHeight + TopologyGraphLayout.rowGap
    for column in 0..<12 {
        for row in 0..<180 {
            layout.positions["\(column)-\(row)"] = CGPoint(
                x: TopologyGraphLayout.padding + CGFloat(column) * columnStride,
                y: TopologyGraphLayout.padding + CGFloat(row) * rowStride
            )
        }
    }
    let index = TopologyHitIndex(layout: layout)
    let orderedIDs = layout.positions.keys.sorted()

    for column in 0..<12 {
        for row in stride(from: 0, to: 180, by: 7) {
            let origin = layout.positions["\(column)-\(row)"]!
            for offset in [
                CGPoint(x: 1, y: 1),
                CGPoint(x: TopologyGraphLayout.nodeWidth / 2, y: TopologyGraphLayout.nodeHeight / 2),
                CGPoint(x: TopologyGraphLayout.nodeWidth - 1, y: TopologyGraphLayout.nodeHeight - 1),
                CGPoint(x: TopologyGraphLayout.nodeWidth + 1, y: TopologyGraphLayout.nodeHeight / 2)
            ] {
                let point = CGPoint(x: origin.x + offset.x, y: origin.y + offset.y)
                let linear = orderedIDs.first {
                    layout.frame($0)?.contains(point) == true
                }
                assert(index.nodeID(at: point) == linear, "synthetic hit mismatch at \(point)")
            }
        }
    }

    assert(index.neighbor(of: "5-80", toward: .up) == "5-79")
    assert(index.neighbor(of: "5-80", toward: .down) == "5-81")
    assert(index.neighbor(of: "5-80", toward: .left) == "4-80")
    assert(index.neighbor(of: "5-80", toward: .right) == "6-80")
}

/// An empty map and an identifier that was never laid out are both ordinary
/// states — a namespace still loading, or a caret left on a node the projection
/// has since folded into a group.
func testTopologyHitIndexHandlesEmptyLayoutsAndUnknownNodes() {
    let empty = TopologyHitIndex(layout: TopologyGraphLayout.Result())
    assert(empty.orderedNodeIDs.isEmpty)
    assert(empty.frame(of: "anything") == nil)
    assert(empty.nodeID(at: .zero) == nil)
    assert(empty.nodeID(at: CGPoint(x: 120, y: 80)) == nil)

    var single = TopologyGraphLayout.Result()
    single.positions["only"] = CGPoint(x: 10, y: 10)
    let index = TopologyHitIndex(layout: single)
    for direction in [
        TopologyHitIndex.Direction.left, .right, .up, .down
    ] {
        assert(index.neighbor(of: "missing", toward: direction) == nil)
        assert(index.neighbor(of: "only", toward: direction) == nil, "a lone node has no neighbour")
    }
    assert(index.orderedNodeIDs == ["only"])
    assert(index.frame(of: "only")?.origin == CGPoint(x: 10, y: 10))
}

/// Arrow keys stop at the edges of the map rather than wrapping, so the ends of
/// every column and row must report no neighbour.
func testTopologyHitIndexStopsAtLayoutBoundaries() {
    var layout = TopologyGraphLayout.Result()
    let columnStride = TopologyGraphLayout.nodeWidth + TopologyGraphLayout.columnGap
    let rowStride = TopologyGraphLayout.nodeHeight + TopologyGraphLayout.rowGap
    for column in 0..<3 {
        for row in 0..<4 {
            layout.positions["c\(column)r\(row)"] = CGPoint(
                x: TopologyGraphLayout.padding + CGFloat(column) * columnStride,
                y: TopologyGraphLayout.padding + CGFloat(row) * rowStride
            )
        }
    }
    let index = TopologyHitIndex(layout: layout)

    assert(index.orderedNodeIDs.first == "c0r0", "reading order starts at the top of the first column")
    assert(index.orderedNodeIDs.prefix(4) == ["c0r0", "c0r1", "c0r2", "c0r3"])
    assert(index.orderedNodeIDs.count == 12)

    assert(index.neighbor(of: "c0r0", toward: .up) == nil)
    assert(index.neighbor(of: "c0r0", toward: .left) == nil)
    assert(index.neighbor(of: "c2r3", toward: .down) == nil)
    assert(index.neighbor(of: "c2r3", toward: .right) == nil)
    assert(index.neighbor(of: "c1r2", toward: .up) == "c1r1")
    assert(index.neighbor(of: "c1r2", toward: .down) == "c1r3")
    assert(index.neighbor(of: "c1r2", toward: .left) == "c0r2")
    assert(index.neighbor(of: "c1r2", toward: .right) == "c2r2")
}

/// `CGRect.contains` excludes its far edges. The index has to agree with it
/// exactly, or a click one pixel inside a pill would select a different node
/// than the tooltip under the same pixel describes.
func testTopologyHitIndexAgreesWithFrameContainmentOnEdges() {
    let graph = buildSampleMap()
    let layout = TopologyGraphLayout.layout(graph)
    let index = TopologyHitIndex(layout: layout)

    var probes: [CGPoint] = []
    for id in layout.positions.keys.sorted() {
        guard let frame = layout.frame(id) else { continue }
        probes.append(contentsOf: [
            CGPoint(x: frame.maxX, y: frame.midY),
            CGPoint(x: frame.maxX - 0.01, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.maxY),
            CGPoint(x: frame.midX, y: frame.maxY - 0.01),
            CGPoint(x: frame.maxX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.minY),
            // The gutter between two columns, and between two rows.
            CGPoint(x: frame.maxX + TopologyGraphLayout.columnGap / 2, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.maxY + TopologyGraphLayout.rowGap / 2)
        ])
    }

    for point in probes {
        let linear = layout.positions.keys.sorted().first {
            layout.frame($0)?.contains(point) == true
        }
        assert(index.nodeID(at: point) == linear, "edge disagreement at \(point)")
    }
}

func testCompletedPodsAreIdleAndNotActiveServiceEndpoints() {
    let service = KubernetesResourceRow(id: "jobs/report", cells: [
        "Namespace": "jobs", "Name": "report", "Selector": "app=report"
    ])
    let workload = KubernetesResourceRow(id: "jobs/report", cells: [
        "Namespace": "jobs", "Name": "report", "Kind": "Deployment",
        "Ready": "0/1", "Selector": "app=report"
    ])
    let pod = KubernetesResourceRow(id: "jobs/report-finished", cells: [
        "Namespace": "jobs", "Name": "report-finished", "Status": "Succeeded",
        "Ready": "0/1", "Restarts": "0", "Labels": "app=report",
        "Owner": "Deployment/report"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [workload], pods: [pod],
        ingress: [], pvcs: [], hpas: []
    )
    let podID = TopologyGraphNode.id(kind: .pod, rowID: pod.id)
    let serviceID = TopologyGraphNode.id(kind: .service, rowID: service.id)
    assert(graph.node(podID)?.health.isIdle == true)
    assert(graph.node(serviceID)?.subtitle.contains("0 endpoints") == true)
    assert(graph.edgesOut(serviceID).contains { $0.kind == .targets })
    assert(!graph.edgesOut(serviceID).contains { $0.kind == .selects && $0.target == podID })
}

func testTerminalBarePodsNeverReceiveServiceEndpointEdges() {
    let service = KubernetesResourceRow(id: "batch/results", cells: [
        "Namespace": "batch", "Name": "results", "Selector": "job=report"
    ])
    let terminal = KubernetesResourceRow(id: "batch/report-finished", cells: [
        "Namespace": "batch", "Name": "report-finished", "Status": "Completed",
        "Ready": "0/1", "Labels": "job=report", "Owner": "Job/report"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [], pods: [terminal],
        ingress: [], pvcs: [], hpas: []
    )
    let serviceID = TopologyGraphNode.id(kind: .service, rowID: service.id)
    assert(graph.edgesOut(serviceID).isEmpty)
    assert(graph.node(serviceID)?.subtitle.contains("0 endpoints") == true)
}

func testServicePreservesTargetedWorkloadFailureWithoutActivePods() {
    let service = KubernetesResourceRow(id: "n/api", cells: [
        "Namespace": "n", "Name": "api", "Selector": "app=api"
    ])
    let failedWorkload = KubernetesResourceRow(id: "n/api", cells: [
        "Namespace": "n", "Name": "api", "Kind": "Deployment",
        "Ready": "0/2", "Selector": "app=api"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [failedWorkload], pods: [],
        ingress: [], pvcs: [], hpas: []
    )
    let serviceHealth = graph.node(
        TopologyGraphNode.id(kind: .service, rowID: service.id)
    )?.health
    assert(serviceHealth?.isFailed == true)
    if let serviceHealth, case .failed(let reason, _, _, _) = serviceHealth {
        assert(reason.contains("Workload Down"))
    }
}

func testUnresolvedOwnersNeverCreateWorkloadOwnershipEdges() {
    let actual = KubernetesResourceRow(id: "n/actual", cells: [
        "Namespace": "n", "Name": "actual", "Kind": "Deployment",
        "Ready": "1/1", "Selector": "app=shared"
    ])
    let other = KubernetesResourceRow(id: "n/other", cells: [
        "Namespace": "n", "Name": "other", "Kind": "Deployment",
        "Ready": "1/1", "Selector": "app=shared"
    ])
    let resolved = KubernetesResourceRow(id: "n/resolved", cells: [
        "Namespace": "n", "Name": "resolved", "Status": "Running", "Ready": "1/1",
        "Labels": "app=shared", "Owner": "Deployment/actual"
    ])
    let unresolved = KubernetesResourceRow(id: "n/unresolved", cells: [
        "Namespace": "n", "Name": "unresolved", "Status": "Running", "Ready": "1/1",
        "Labels": "app=shared", "Owner": "Job/external-controller"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [actual, other], pods: [resolved, unresolved],
        ingress: [], pvcs: [], hpas: []
    )
    let resolvedID = TopologyGraphNode.id(kind: .pod, rowID: resolved.id)
    let actualEdges = graph.edgesOut(TopologyGraphNode.id(kind: .workload, rowID: actual.id))
    let otherEdges = graph.edgesOut(TopologyGraphNode.id(kind: .workload, rowID: other.id))
    assert(actualEdges.contains { $0.target == resolvedID })
    assert(!otherEdges.contains { $0.target == resolvedID })
    let unresolvedID = TopologyGraphNode.id(kind: .pod, rowID: unresolved.id)
    assert(!actualEdges.contains { $0.target == unresolvedID })
    assert(!otherEdges.contains { $0.target == unresolvedID })
    assert(graph.edgesIn(unresolvedID).isEmpty, "an unresolved owner must remain unattached without a Service")
}

func testTopologyProjectionCapsGroupsAndExpandsInBatches() {
    let workload = KubernetesResourceRow(id: "scale/work", cells: [
        "Namespace": "scale", "Name": "work", "Kind": "Deployment",
        "Ready": "60/60", "Selector": "app=work"
    ])
    let pods = (0..<60).map { index in
        KubernetesResourceRow(id: "scale/work-\(index)", cells: [
            "Namespace": "scale", "Name": "work-\(index)", "Status": "Running",
            "Ready": "1/1", "Labels": "app=work", "Owner": "Deployment/work"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods,
        ingress: [], pvcs: [], hpas: []
    )
    let options = TopologyProjectionOptions(
        budget: 100, perParentCap: 5, sampleNameLimit: 3, expansionBatchSize: 20
    )
    let initial = TopologyRelevanceProjector.project(source, options: options)
    let group = initial.groupsByNodeID.values.first { $0.kind == .healthyPods }
    assert(initial.graph.nodes.count == 7, "workload + five pods + one group")
    assert(group?.hiddenCount == 55)
    assert(group?.sampleNames.count == 3)

    var expansion = TopologyExpansionState()
    expansion.expand(group!.nodeID)
    let expanded = TopologyRelevanceProjector.project(
        source, options: options, expansion: expansion
    )
    assert(expanded.graph.nodes.count == 27, "one expansion must reveal exactly 20 pods")
    assert(expanded.groupsByNodeID[group!.nodeID]?.hiddenCount == 35)
}

func testTopologyProjectionKeepsHiddenTerminalPodsSearchable() {
    let pods = (0..<8).map { index in
        KubernetesResourceRow(id: "batch/job-\(index)", cells: [
            "Namespace": "batch", "Name": "job-\(index)", "Status": "Completed",
            "Ready": "0/1", "Labels": "job=batch", "Owner": "Job/nightly"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [], pods: pods,
        ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source,
        options: TopologyProjectionOptions(budget: 50, sampleNameLimit: 2)
    )
    assert(projection.graph.nodes.count == 1)
    assert(projection.graph.nodes[0].kind == .terminalGroup)
    let hiddenID = TopologyGraphNode.id(kind: .pod, rowID: "batch/job-7")
    assert(projection.searchNodeIDs(matching: "job-7") == [hiddenID])
    assert(projection.materializing(nodeIDs: [hiddenID]).node(hiddenID) != nil)

    let focused = TopologyRelevanceProjector.project(
        source,
        options: TopologyProjectionOptions(budget: 50),
        focusedNodeID: hiddenID
    )
    assert(focused.graph.node(hiddenID) != nil, "focus must outrank terminal grouping")
    assert(TopologyProjectionOptions(budget: 10_000).budget == TopologyProjectionOptions.hardCeiling)
}

func testTopologySearchOutranksProjectionBudget() {
    let pods = (0..<20).map { index in
        KubernetesResourceRow(id: "search/task-\(index)", cells: [
            "Namespace": "search", "Name": "task-\(index)", "Status": "Succeeded",
            "Ready": "0/1", "Owner": "Job/archive"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [], pods: pods,
        ingress: [], pvcs: [], hpas: []
    )
    let searchedID = TopologyGraphNode.id(kind: .pod, rowID: "search/task-19")
    let projection = TopologyRelevanceProjector.project(
        source,
        options: TopologyProjectionOptions(budget: 1),
        searchNodeIDs: [searchedID]
    )
    assert(projection.graph.nodes.map(\.id) == [searchedID])
}

func testTopologyMaterializationReplacesSyntheticMembershipCleanly() {
    let workload = KubernetesResourceRow(id: "batch/nightly", cells: [
        "Namespace": "batch", "Name": "nightly", "Kind": "Deployment",
        "Ready": "0/0", "Selector": "job=nightly"
    ])
    let pods = (0..<10).map { index in
        KubernetesResourceRow(id: "batch/nightly-\(index)", cells: [
            "Namespace": "batch", "Name": "nightly-\(index)", "Status": "Completed",
            "Ready": "0/1", "Labels": "job=nightly", "Owner": "Deployment/nightly"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods,
        ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source, options: TopologyProjectionOptions(budget: 50)
    )
    let materializedID = TopologyGraphNode.id(kind: .pod, rowID: "batch/nightly-9")
    let materialized = projection.materializing(nodeIDs: [materializedID])
    let workloadID = TopologyGraphNode.id(kind: .workload, rowID: workload.id)
    let owns = materialized.edgesOut(workloadID).filter { $0.kind == .owns }
    assert(owns.filter { $0.target == materializedID }.count == 1)
    assert(owns.filter { materialized.node($0.target)?.kind == .terminalGroup }.count == 1)
    assert(Set(owns.map(\.id)).count == owns.count)
}

func testTopologyEligibleCountsUseUnprojectedFilteredObjects() {
    let active = KubernetesResourceRow(id: "count/active", cells: [
        "Namespace": "count", "Name": "active", "Status": "Running", "Ready": "1/1"
    ])
    let inactive = KubernetesResourceRow(id: "count/inactive", cells: [
        "Namespace": "count", "Name": "inactive", "Status": "Completed", "Ready": "0/1"
    ])
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [], pods: [active, inactive],
        ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source, options: TopologyProjectionOptions(budget: 10)
    )

    assert(projection.sourceNodeCount == 2)
    assert(projection.eligibleSourceNodeIDs(TopologyMapFilter()).count == 1)
    assert(projection.eligibleSourceNodeIDs(
        TopologyMapFilter(searchText: "inactive", includesInactive: true)
    ) == [TopologyGraphNode.id(kind: .pod, rowID: inactive.id)])
}

/// A namespace of grouped pods. Searching for one that the projection folded
/// into a group must not be answered with "No match": the object exists, the
/// map just has not materialised it yet.
func testMapSnapshotWaitsForGroupedMatchInsteadOfClaimingNoMatch() {
    let workload = KubernetesResourceRow(id: "run/fleet", cells: [
        "Namespace": "run", "Name": "fleet", "Kind": "Deployment",
        "Ready": "60/60", "Selector": "app=fleet"
    ])
    let pods = (0..<60).map { index in
        KubernetesResourceRow(id: "run/fleet-\(index)", cells: [
            "Namespace": "run", "Name": "fleet-\(index)", "Status": "Running",
            "Ready": "1/1", "Restarts": "0", "Labels": "app=fleet",
            "Owner": "Deployment/fleet"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods, ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source, options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    )

    let hidden = TopologyMapSnapshot(
        projected: projection.graph,
        projection: projection,
        filter: TopologyMapFilter(searchText: "fleet-59")
    )
    assert(hidden.graph.isEmpty, "the grouped pod is not on the map yet")
    assert(hidden.eligibleCount == 1, "but the source has exactly one match")
    assert(hidden.vacancy == .awaitingProjection, "got \(hidden.vacancy)")

    let materialized = TopologyMapSnapshot(
        projected: projection.materializing(nodeIDs: hidden.eligibleSourceNodeIDs),
        projection: projection,
        filter: TopologyMapFilter(searchText: "fleet-59")
    )
    assert(materialized.vacancy == .none)
    assert(materialized.visibleRealCount == 1)

    let absent = TopologyMapSnapshot(
        projected: projection.graph,
        projection: projection,
        filter: TopologyMapFilter(searchText: "no-such-object")
    )
    assert(absent.vacancy == .noSearchMatch, "got \(absent.vacancy)")
}

/// The toolbar's three numbers have to add up: what is drawn, what the filters
/// match, and what grouping took away.
func testMapSnapshotCountsDrawnGroupedAndEligibleSeparately() {
    let workload = KubernetesResourceRow(id: "run/fleet", cells: [
        "Namespace": "run", "Name": "fleet", "Kind": "Deployment",
        "Ready": "60/60", "Selector": "app=fleet"
    ])
    let pods = (0..<60).map { index in
        KubernetesResourceRow(id: "run/fleet-\(index)", cells: [
            "Namespace": "run", "Name": "fleet-\(index)", "Status": "Running",
            "Ready": "1/1", "Restarts": "0", "Labels": "app=fleet",
            "Owner": "Deployment/fleet"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods, ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source, options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    )
    let snapshot = TopologyMapSnapshot(
        projected: projection.graph, projection: projection, filter: TopologyMapFilter()
    )

    assert(snapshot.vacancy == .none)
    assert(snapshot.syntheticGroupCount == 1)
    assert(snapshot.visibleRealCount == 6, "workload plus five pods, got \(snapshot.visibleRealCount)")
    assert(snapshot.eligibleCount == 61, "got \(snapshot.eligibleCount)")
    assert(snapshot.projectionHiddenCount == 55, "got \(snapshot.projectionHiddenCount)")
}

/// A pod going CrashLoopBackOff must not move the map. Structure decides the
/// layout; name and health only decide what is painted on it.
func testTopologyIdentitySeparatesStructureFromPresentation() {
    func pod(_ name: String, health: TopologyNodeHealthState) -> TopologyGraphNode {
        TopologyGraphNode(
            id: "pod/ns/\(name)",
            kind: .pod,
            name: name,
            namespace: "ns",
            subtitle: health.summaryTitle,
            health: health,
            row: KubernetesResourceRow(id: "ns/\(name)", cells: ["Namespace": "ns", "Name": name])
        )
    }
    let edge = TopologyGraphEdge(source: "pod/ns/a", target: "pod/ns/b", kind: .owns)
    let healthy = ClusterTopologyGraph(
        nodes: [pod("a", health: .healthy), pod("b", health: .healthy)], edges: [edge]
    )
    let crashing = ClusterTopologyGraph(
        nodes: [
            pod("a", health: .healthy),
            pod("b", health: .failed(
                reason: "CrashLoopBackOff", details: "", exitCode: 1, restartCount: 9
            ))
        ],
        edges: [edge]
    )

    assert(TopologyStructuralIdentity(healthy) == TopologyStructuralIdentity(crashing),
           "health must not force a relayout")
    assert(TopologyPresentationIdentity(healthy) != TopologyPresentationIdentity(crashing),
           "health must still force a redraw")

    let disconnected = ClusterTopologyGraph(nodes: healthy.nodes, edges: [])
    assert(TopologyStructuralIdentity(healthy) != TopologyStructuralIdentity(disconnected))

    // Node order is an accident of how the graph was assembled, not a change.
    let reordered = ClusterTopologyGraph(nodes: healthy.nodes.reversed(), edges: [edge])
    assert(TopologyStructuralIdentity(healthy) == TopologyStructuralIdentity(reordered))
    assert(TopologyPresentationIdentity(healthy) == TopologyPresentationIdentity(reordered))
}

/// Arrow keys follow the lineage, not the paint: right from a Service reaches
/// the workload it selects, and the first press with no caret lands rather than
/// steps.
func testTopologyKeyboardNavigationFollowsEdgesBeforeGeometry() {
    let service = KubernetesResourceRow(id: "run/api", cells: [
        "Namespace": "run", "Name": "api", "Type": "ClusterIP", "Selector": "app=api"
    ])
    let workload = KubernetesResourceRow(id: "run/api", cells: [
        "Namespace": "run", "Name": "api", "Kind": "Deployment",
        "Ready": "1/1", "Selector": "app=api"
    ])
    let pod = KubernetesResourceRow(id: "run/api-0", cells: [
        "Namespace": "run", "Name": "api-0", "Status": "Running", "Ready": "1/1",
        "Restarts": "0", "Labels": "app=api", "Owner": "Deployment/api"
    ])
    let graph = ClusterTopologyGraphBuilder.build(
        services: [service], workloads: [workload], pods: [pod],
        ingress: [], pvcs: [], hpas: []
    )
    let layout = TopologyGraphLayout.layout(graph)
    let index = TopologyHitIndex(layout: layout)

    let landing = TopologyKeyboardNavigation.next(
        from: nil, toward: .right, in: graph, layout: layout, hitIndex: index
    )
    assert(landing == index.orderedNodeIDs.first, "the first press must land, not step")

    let serviceID = graph.nodes.first { $0.kind == .service }!.id
    let workloadID = graph.nodes.first { $0.kind == .workload }!.id
    let right = TopologyKeyboardNavigation.next(
        from: serviceID, toward: .right, in: graph, layout: layout, hitIndex: index
    )
    assert(right == workloadID, "right from a service must reach what it selects, got \(right ?? "nil")")

    let back = TopologyKeyboardNavigation.next(
        from: workloadID, toward: .left, in: graph, layout: layout, hitIndex: index
    )
    assert(back == serviceID, "left must walk back up the edge, got \(back ?? "nil")")

    // Nothing is above or below anything in a single chain, so vertical presses
    // have nowhere to go rather than wrapping to an unrelated column.
    assert(TopologyKeyboardNavigation.next(
        from: workloadID, toward: .up, in: graph, layout: layout, hitIndex: index
    ) == nil)
}

/// The three lengths describe one map. The short and medium forms exist so a
/// narrow toolbar can stop printing the long one — not so they can round the
/// numbers into something friendlier than the truth.
func testTopologyCountSummaryAgreesAtEveryLength() {
    let grouped = TopologyCountSummary(
        visibleRealCount: 6,
        syntheticGroupCount: 1,
        eligibleCount: 61,
        projectionHiddenCount: 55
    )
    assert(grouped.full == "Showing 6 real + 1 group · 61 filter-eligible · 55 grouped/omitted",
           "got \(grouped.full)")
    assert(grouped.medium == "6 of 61 shown", "got \(grouped.medium)")
    assert(grouped.short == "6/61", "got \(grouped.short)")

    // Nothing hidden: a ratio of a number to itself invites the reader to look
    // for the missing objects, so both short forms drop the denominator.
    let whole = TopologyCountSummary(
        visibleRealCount: 12,
        syntheticGroupCount: 0,
        eligibleCount: 12,
        projectionHiddenCount: 0
    )
    assert(whole.full == "Showing 12 real · 12 filter-eligible", "got \(whole.full)")
    assert(whole.medium == "12 shown", "got \(whole.medium)")
    assert(whole.short == "12", "got \(whole.short)")

    let plural = TopologyCountSummary(
        visibleRealCount: 2,
        syntheticGroupCount: 3,
        eligibleCount: 40,
        projectionHiddenCount: 38
    )
    assert(plural.full.contains("3 groups"), "got \(plural.full)")
}

/// Whatever the snapshot counted is what the toolbar says, at every length.
func testTopologyCountSummaryFollowsTheSnapshot() {
    let workload = KubernetesResourceRow(id: "run/fleet", cells: [
        "Namespace": "run", "Name": "fleet", "Kind": "Deployment",
        "Ready": "60/60", "Selector": "app=fleet"
    ])
    let pods = (0..<60).map { index in
        KubernetesResourceRow(id: "run/fleet-\(index)", cells: [
            "Namespace": "run", "Name": "fleet-\(index)", "Status": "Running",
            "Ready": "1/1", "Restarts": "0", "Labels": "app=fleet",
            "Owner": "Deployment/fleet"
        ])
    }
    let source = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [workload], pods: pods, ingress: [], pvcs: [], hpas: []
    )
    let projection = TopologyRelevanceProjector.project(
        source, options: TopologyProjectionOptions(budget: 100, perParentCap: 5)
    )
    let snapshot = TopologyMapSnapshot(
        projected: projection.graph, projection: projection, filter: TopologyMapFilter()
    )
    let summary = TopologyCountSummary(snapshot)

    assert(summary.short == "\(snapshot.visibleRealCount)/\(snapshot.eligibleCount)",
           "got \(summary.short)")
    assert(summary.full.contains("\(snapshot.projectionHiddenCount) grouped/omitted"),
           "got \(summary.full)")
}

func testTopologyBuilderStopsDuringLargeInputCancellation() {
    let pods = (0..<1_000).map { index in
        KubernetesResourceRow(id: "cancel/pod-\(index)", cells: [
            "Namespace": "cancel", "Name": "pod-\(index)", "Status": "Running",
            "Ready": "1/1", "Labels": "app=cancel"
        ])
    }
    var checks = 0
    let graph = ClusterTopologyGraphBuilder.build(
        services: [], workloads: [], pods: pods,
        ingress: [], pvcs: [], hpas: [],
        isCancelled: {
            checks += 1
            return checks > 10
        }
    )
    assert(graph.isEmpty)
    assert(checks < pods.count, "cancellation should stop before traversing all rows")
}


func runKubernetesTopologyTests() throws {
    try testHygieneScoreRewardsFullyDeclaredHealthyPods()
    try testHygieneScoreReadsRawRequestsNotDisplayCells()
    try testHygieneScoreIsPodsOnly()
    testTopologyFailureEvaluatorPodFailures()
    testTopologyFailureEvaluatorServiceFailures()
    testMapDrawsEveryObjectExactlyOnce()
    testMapKeepsAPodSharedByTwoServices()
    testMapTreatsScaledToZeroAsIdleNotBroken()
    testMapStillFlagsAServiceWithNoBackendAtAll()
    testMapUsesOwnerReferencesNotSharedLabels()
    testMapOnlyLinksVolumesThatAreActuallyMounted()
    testMapRoutesIngressToItsNamedBackendOnly()
    testMapLineageReachesTheWholeChain()
    testMapSelectorWalksTheRequestedDirection()
    testMapGroupsInterchangeableHealthyPods()
    testMapNeverGroupsPodsWithDifferentParents()
    testMapLeavesSmallPodSetsAlone()
    testMapLayoutFlowsLeftToRight()
    testMapLayoutTerminatesOnACycle()
    testTopologyHitIndexMatchesRepresentativeLayoutFrames()
    testTopologyHitIndexMatchesLargeSyntheticLayout()
    testTopologyHitIndexHandlesEmptyLayoutsAndUnknownNodes()
    testTopologyHitIndexStopsAtLayoutBoundaries()
    testTopologyHitIndexAgreesWithFrameContainmentOnEdges()
    testCompletedPodsAreIdleAndNotActiveServiceEndpoints()
    testTerminalBarePodsNeverReceiveServiceEndpointEdges()
    testServicePreservesTargetedWorkloadFailureWithoutActivePods()
    testUnresolvedOwnersNeverCreateWorkloadOwnershipEdges()
    testTopologyProjectionCapsGroupsAndExpandsInBatches()
    testTopologyProjectionKeepsHiddenTerminalPodsSearchable()
    testTopologySearchOutranksProjectionBudget()
    testTopologyMaterializationReplacesSyntheticMembershipCleanly()
    testTopologyEligibleCountsUseUnprojectedFilteredObjects()
    testMapSnapshotWaitsForGroupedMatchInsteadOfClaimingNoMatch()
    testMapSnapshotCountsDrawnGroupedAndEligibleSeparately()
    testTopologyIdentitySeparatesStructureFromPresentation()
    testTopologyKeyboardNavigationFollowsEdgesBeforeGeometry()
    testTopologyCountSummaryAgreesAtEveryLength()
    testTopologyCountSummaryFollowsTheSnapshot()
    testTopologyBuilderStopsDuringLargeInputCancellation()
}
