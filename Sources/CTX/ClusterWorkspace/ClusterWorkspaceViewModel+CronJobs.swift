import CTXCore
import Foundation
import SwiftUI

extension ClusterWorkspaceViewModel {
    func loadCronJobs() {
        guard cronJobs.isEmpty else { return }
        // Populate initial sample/discovered CronJob items
        let ns = selectedNamespace.displayName
        let samples: [CronJobItem] = [
            CronJobItem(
                namespace: ns,
                name: "db-backup-nightly",
                schedule: "0 2 * * *",
                activeJobs: 0,
                lastScheduleTime: Date().addingTimeInterval(-3600 * 14),
                isSuspended: false,
                age: "42d"
            ),
            CronJobItem(
                namespace: ns,
                name: "report-monthly-aggregator",
                schedule: "@monthly",
                activeJobs: 0,
                lastScheduleTime: Date().addingTimeInterval(-86400 * 18),
                isSuspended: false,
                age: "120d"
            ),
            CronJobItem(
                namespace: ns,
                name: "log-cleanup-weekly",
                schedule: "@weekly",
                activeJobs: 0,
                lastScheduleTime: Date().addingTimeInterval(-86400 * 5),
                isSuspended: false,
                age: "90d"
            )
        ]
        self.cronJobs = samples
    }
}
