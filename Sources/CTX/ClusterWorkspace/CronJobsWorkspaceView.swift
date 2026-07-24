import CTXCore
import SwiftUI

struct CronJobsWorkspaceView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CTXSectionHeader(
                title: "CronJobs",
                subtitle: "Scheduled recurring workload tasks and execution status"
            )

            if viewModel.isLoading(section: .cronjobs) {
                CTXGlassPanel {
                    ResourceSkeletonView(title: "Loading CronJobs")
                }
            } else if viewModel.cronJobs.isEmpty {
                CTXGlassPanel {
                    CTXEmptyStateView(
                        title: "No CronJobs found",
                        message: "There are no CronJobs configured in the selected namespace scope.",
                        systemImage: "clock.arrow.2.circlepath"
                    )
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.cronJobs) { cronJob in
                            CronJobRowCard(cronJob: cronJob)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .onAppear {
            viewModel.loadCronJobs()
        }
    }
}

public struct CronJobItem: Identifiable, Equatable, Sendable {
    public var id: String { "\(namespace)/\(name)" }
    public let namespace: String
    public let name: String
    public let schedule: String
    public let activeJobs: Int
    public let lastScheduleTime: Date?
    public let isSuspended: Bool
    public let age: String

    public init(
        namespace: String,
        name: String,
        schedule: String,
        activeJobs: Int = 0,
        lastScheduleTime: Date? = nil,
        isSuspended: Bool = false,
        age: String = "—"
    ) {
        self.namespace = namespace
        self.name = name
        self.schedule = schedule
        self.activeJobs = activeJobs
        self.lastScheduleTime = lastScheduleTime
        self.isSuspended = isSuspended
        self.age = age
    }

    public var isStale: Bool {
        CronJobCadenceEvaluator.isStale(lastScheduleTime: lastScheduleTime, schedule: schedule)
    }

    public var statusText: String {
        if isSuspended {
            return "Suspended"
        } else if isStale {
            return "Stale Cadence"
        } else if activeJobs > 0 {
            return "Active (\(activeJobs))"
        } else {
            return "Scheduled"
        }
    }

    public var statusColor: Color {
        if isSuspended { return .secondary }
        if isStale { return .orange }
        if activeJobs > 0 { return .green }
        return .blue
    }
}

struct CronJobRowCard: View {
    let cronJob: CronJobItem

    var body: some View {
        CTXGlassPanel(padding: 14) {
            HStack(spacing: 16) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(cronJob.statusColor)
                    .frame(width: 34, height: 34)
                    .background(cronJob.statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(cronJob.name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(cronJob.namespace)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }

                    HStack(spacing: 12) {
                        Text("Schedule: \(cronJob.schedule)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)

                        if let lastRun = cronJob.lastScheduleTime {
                            Text("Last Run: \(lastRun.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Last Run: Never")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Text(cronJob.statusText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(cronJob.statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(cronJob.statusColor.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule().stroke(cronJob.statusColor.opacity(0.25), lineWidth: 0.5)
                        }

                    Text(cronJob.age)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
