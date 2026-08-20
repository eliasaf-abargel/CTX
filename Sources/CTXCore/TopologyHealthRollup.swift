import Foundation

/// Folds the verdicts of several backing objects into the one verdict a node
/// upstream of them should show, so a card never disagrees with the card it
/// points at.
enum TopologyHealthRollup {
    static func worst(_ states: [TopologyNodeHealthState]) -> TopologyNodeHealthState {
        if let failed = states.first(where: { $0.isFailed }) { return failed }
        if let degraded = states.first(where: { $0.isDegraded }) { return degraded }
        return .healthy
    }

    /// Same ordering, plus the case that only matters behind a Service: when
    /// every workload it fronts is parked at zero replicas, the missing
    /// endpoints are a deployment decision rather than an outage.
    static func serviceBackend(_ states: [TopologyNodeHealthState]) -> TopologyNodeHealthState {
        if let failed = states.first(where: { $0.isFailed }) { return failed }
        if let degraded = states.first(where: { $0.isDegraded }) { return degraded }
        if !states.isEmpty, states.allSatisfy(\.isIdle) {
            return .idle(reason: "Scaled to zero")
        }
        return .healthy
    }
}
