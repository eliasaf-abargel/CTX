import CTXCore
import Foundation

extension ClusterWorkspaceViewModel {
    func loadTopologyResources() {
        loadResource(kind: .services, bypassCache: false)
        loadResource(kind: .workloads, bypassCache: false, priority: .background)
        loadResource(kind: .pods, bypassCache: false, priority: .background)
        loadResource(kind: .ingress, bypassCache: false, priority: .background)
    }

    func recalculateTopology() {
        let services = resourceList(for: .services)?.rows ?? []
        let workloads = resourceList(for: .workloads)?.rows ?? []
        let pods = resourceList(for: .pods)?.rows ?? []
        let ingress = resourceList(for: .ingress)?.rows ?? []

        // Cache parsed selectors for pods to avoid re-parsing on every match check
        let podLabelsCache = pods.map { (pod: $0, labels: KubernetesRelatedPods.parseSelector($0.cells["Labels"] ?? "")) }

        // Group by namespace for faster lookup
        let podsByNamespace = Dictionary(grouping: podLabelsCache, by: { $0.pod.namespace })
        let workloadsByNamespace = Dictionary(grouping: workloads, by: { $0.namespace })
        let ingressByNamespace = Dictionary(grouping: ingress, by: { $0.namespace })

        self.topologyRelations = services.map { service in
            let ns = service.namespace
            let nsPods = podsByNamespace[ns] ?? []
            let nsWorkloads = workloadsByNamespace[ns] ?? []
            let nsIngress = ingressByNamespace[ns] ?? []

            // 1. Related pods for this service
            let serviceSelector = KubernetesRelatedPods.parseSelector(service.cells["Selector"] ?? "")
            let relatedPods = nsPods.filter {
                KubernetesRelatedPods.matches(podLabels: $0.labels, selector: serviceSelector)
            }.map { $0.pod }

            // 2. Related workloads
            let relatedPodIDs = Set(relatedPods.map(\.id))
            let relatedWorkloads: [KubernetesResourceRow]
            if relatedPodIDs.isEmpty {
                relatedWorkloads = []
            } else {
                relatedWorkloads = nsWorkloads.filter { workload in
                    let workloadSelector = KubernetesRelatedPods.parseSelector(workload.cells["Selector"] ?? "")
                    let workloadPods = nsPods.filter {
                        KubernetesRelatedPods.matches(podLabels: $0.labels, selector: workloadSelector)
                    }
                    return workloadPods.contains { relatedPodIDs.contains($0.pod.id) }
                }
            }

            // 3. Related ingress
            let relatedIngress = nsIngress.filter { row in
                (row.cells["Services"] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .contains(service.name)
            }

            return TopologyServiceRelation(
                service: service,
                workloads: relatedWorkloads,
                pods: relatedPods,
                ingress: relatedIngress
            )
        }
    }
}
