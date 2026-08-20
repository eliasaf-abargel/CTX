import Foundation

public enum TopologyNodeHealthState: Equatable, Sendable {
    case healthy
    /// Deliberately not running: scaled to zero, suspended, completed. Distinct
    /// from `healthy` because it explains an absence, and — the reason this case
    /// exists at all — distinct from `failed`, which is what a Service in front
    /// of a scaled-to-zero Deployment used to be reported as. On a cluster where
    /// most workloads are parked at zero replicas that single mislabel turned
    /// the map into a wall of red and buried the handful of real failures.
    case idle(reason: String)
    case degraded(reason: String)
    case failed(reason: String, details: String, exitCode: Int?, restartCount: Int)

    public var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isDegraded: Bool {
        if case .degraded = self { return true }
        return false
    }

    /// True only for states a human should act on — what "Needs attention"
    /// counts, and what the failures lens shows.
    public var needsAttention: Bool { isFailed || isDegraded }

    public var summaryTitle: String {
        switch self {
        case .healthy: "Healthy"
        case .idle(let reason): reason
        case .degraded(let reason): "Degraded (\(reason))"
        case .failed(let reason, _, _, _): "Failed (\(reason))"
        }
    }
}

public enum TopologyFailureEvaluator {
    public static func evaluatePod(cells: [String: String]) -> TopologyNodeHealthState {
        let status = (cells["Status"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let restartsStr = cells["Restarts"] ?? "0"
        let readyStr = cells["Ready"] ?? "1/1"

        let restarts = parseRestartCount(restartsStr)
        let exitCode = parseExitCode(status: status)

        let criticalFailures = ["CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "Error", "OOMKilled", "Evicted", "Failed", "CreateContainerConfigError"]
        let lowerStatus = status.lowercased()

        // A completed pod commonly reports 0/N Ready because its containers have
        // exited successfully. Completion is terminal and expected, so classify it
        // before readiness checks and keep it out of active endpoint counts.
        if lowerStatus == "succeeded" || lowerStatus == "completed" {
            return .idle(reason: "Completed")
        }

        for critical in criticalFailures {
            if lowerStatus.contains(critical.lowercased()) {
                let details = "Pod failed with status '\(status)'. Restart count: \(restarts)."
                return .failed(reason: status, details: details, exitCode: exitCode, restartCount: restarts)
            }
        }

        if readyStr.contains("0/") || lowerStatus.contains("pending") || lowerStatus.contains("terminating") {
            return .degraded(reason: "Pod Not Ready (\(readyStr))")
        }

        if restarts >= 5 {
            return .degraded(reason: "\(restarts) Restarts")
        }

        return .healthy
    }

    public static func evaluateWorkload(cells: [String: String], podsHealth: [TopologyNodeHealthState]) -> TopologyNodeHealthState {
        let readyStr = cells["Ready"] ?? ""
        let readyParts = readyStr.split(separator: "/")
        if readyParts.count == 2, let ready = Int(readyParts[0]), let total = Int(readyParts[1]) {
            if total == 0 {
                // `spec.replicas: 0` is a deployment decision, not an outage.
                return .idle(reason: "Scaled to zero")
            }
            if ready == 0 {
                return .failed(reason: "0/\(total) Replicas Ready", details: "All pod replicas for this workload have failed or are unavailable.", exitCode: nil, restartCount: 0)
            } else if ready < total {
                return .degraded(reason: "\(ready)/\(total) Replicas Ready")
            }
        }

        if let failingPod = podsHealth.first(where: { $0.isFailed }) {
            if case .failed(let reason, let details, let exitCode, let restartCount) = failingPod {
                return .failed(reason: "Pod Failure (\(reason))", details: details, exitCode: exitCode, restartCount: restartCount)
            }
        }

        if podsHealth.contains(where: { $0.isDegraded }) {
            return .degraded(reason: "Pod Replicas Degraded")
        }

        return .healthy
    }

    public static func evaluateService(cells: [String: String], matchedPodsCount: Int, workloadHealth: TopologyNodeHealthState) -> TopologyNodeHealthState {
        let selector = cells["Selector"] ?? ""
        if workloadHealth.isFailed {
            if case .failed(let reason, let details, let exitCode, let restarts) = workloadHealth {
                return .failed(reason: "Workload Down (\(reason))", details: details, exitCode: exitCode, restartCount: restarts)
            }
        }

        if workloadHealth.isDegraded {
            return .degraded(reason: "Workload Replicas Unhealthy")
        }

        if !selector.isEmpty && matchedPodsCount == 0 {
            // No endpoints is only a fault when something was supposed to be
            // running. If the workload behind this selector is parked at zero
            // replicas, the empty Service is the expected consequence — say so
            // instead of raising an alarm the user cannot act on.
            if workloadHealth.isIdle {
                return .idle(reason: "Scaled to zero — no endpoints")
            }
            return .failed(
                reason: "No Target Endpoints",
                details: "Service selector '\(selector)' does not match any active pods in namespace.",
                exitCode: nil,
                restartCount: 0
            )
        }

        return .healthy
    }

    public static func parseRestartCount(_ string: String) -> Int {
        let numbers = string.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
        return numbers.first ?? 0
    }

    public static func parseExitCode(status: String) -> Int? {
        if status.contains("137") || status.contains("OOMKilled") {
            return 137
        } else if status.contains("139") {
            return 139
        } else if status.contains("1") {
            return 1
        }
        return nil
    }
}
