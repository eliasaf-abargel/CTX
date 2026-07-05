import Foundation

/// Pure decision logic for the Logs pod picker — deliberately free of any reader,
/// ViewModel, or SwiftUI dependency so it's directly unit-testable (unlike the
/// view model, which lives in the app target and can't be imported by
/// `CTXCoreTests`).
public enum PodLogSelection {
    /// Sort priority: healthy pods first, then pods with a problem worth noticing,
    /// then pods still starting, then pods that are done. Ties keep their
    /// original (namespace/name) order — `sorted` is stable.
    public enum Rank: Int, Comparable {
        case runningReady = 0
        case warning = 1
        case pending = 2
        case completed = 3

        public static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public static func rank(for row: KubernetesResourceRow) -> Rank {
        let status = (row.cells["Status"] ?? "").lowercased()
        if status.contains("crashloop") || status.contains("backoff") || status == "failed" || status == "error" || row.warning {
            return .warning
        }
        if status == "pending" || status == "containercreating" {
            return .pending
        }
        if status == "succeeded" || status == "completed" || status == "terminated" || status == "terminating" {
            return .completed
        }
        return .runningReady
    }

    /// Running/Ready first, then Warning/CrashLoop/Error, then Pending, then
    /// Completed/Terminated — stable within each group.
    public static func sortedForPicker(_ rows: [KubernetesResourceRow]) -> [KubernetesResourceRow] {
        rows.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank(for: lhs.element)
                let rhsRank = rank(for: rhs.element)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The pod to auto-select when the picker first has data: exactly one pod
    /// means there's nothing to choose, so skip the picker entirely. Two or more
    /// means CTX must not guess — the caller shows a picker instead.
    public static func autoSelectCandidate(from rows: [KubernetesResourceRow]) -> KubernetesResourceRow? {
        rows.count == 1 ? rows.first : nil
    }
}
