import Foundation

/// Provides cadence estimation and staleness evaluations for Kubernetes CronJobs.
/// Evaluates cron expressions (@daily, @weekly, @monthly, 5-field syntax) so that rare-cadence
/// jobs (e.g. monthly backups) are graded against their own schedule interval rather than a flat daily threshold.
public struct CronJobCadenceEvaluator {
    public static let defaultStaleThreshold: TimeInterval = 86400 // 24 hours

    /// Estimates the minimum interval between runs for a cron schedule string.
    public static func minInterval(for schedule: String) -> TimeInterval {
        let trimmed = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "?", with: "*")

        switch trimmed.lowercased() {
        case "@yearly", "@annually":
            return 365 * 86400
        case "@monthly":
            return 28 * 86400
        case "@weekly":
            return 7 * 86400
        case "@daily", "@midnight":
            return 86400
        case "@hourly":
            return 3600
        default:
            break
        }

        let fields = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard fields.count == 5 else { return defaultStaleThreshold }

        let month = fields[3]
        let dom = fields[2]
        let dow = fields[4]

        if month != "*" {
            return 28 * 86400
        } else if dom != "*" {
            return 28 * 86400
        } else if dow != "*" {
            return 7 * 86400
        }

        return 86400
    }

    /// Determines if a CronJob run is considered stale based on its schedule cadence and last schedule time.
    public static func isStale(lastScheduleTime: Date?, schedule: String, currentDate: Date = Date()) -> Bool {
        guard let lastScheduleTime else { return false }
        let interval = minInterval(for: schedule)
        let maxAllowedGap = max(interval * 2.5, 86400 * 2)
        return currentDate.timeIntervalSince(lastScheduleTime) > maxAllowedGap
    }
}
