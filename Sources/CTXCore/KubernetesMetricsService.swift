import Foundation

/// Models for resource metrics (CPU millicores, Memory MiB, PVC disk usage bytes).
public struct KubernetesResourceMetrics: Identifiable, Equatable, Sendable {
    public var id: String { "\(namespace)/\(name)" }
    public let namespace: String
    public let name: String
    public let cpuMilli: Int64
    public let memoryMiB: Int64
    public let cpuRequestMilli: Int64?
    public let cpuLimitMilli: Int64?
    public let memoryRequestMiB: Int64?
    public let memoryLimitMiB: Int64?
    public let diskUsedBytes: Int64?
    public let diskCapacityBytes: Int64?

    public init(
        namespace: String,
        name: String,
        cpuMilli: Int64,
        memoryMiB: Int64,
        cpuRequestMilli: Int64? = nil,
        cpuLimitMilli: Int64? = nil,
        memoryRequestMiB: Int64? = nil,
        memoryLimitMiB: Int64? = nil,
        diskUsedBytes: Int64? = nil,
        diskCapacityBytes: Int64? = nil
    ) {
        self.namespace = namespace
        self.name = name
        self.cpuMilli = cpuMilli
        self.memoryMiB = memoryMiB
        self.cpuRequestMilli = cpuRequestMilli
        self.cpuLimitMilli = cpuLimitMilli
        self.memoryRequestMiB = memoryRequestMiB
        self.memoryLimitMiB = memoryLimitMiB
        self.diskUsedBytes = diskUsedBytes
        self.diskCapacityBytes = diskCapacityBytes
    }

    public var cpuUsageFormatted: String {
        "\(cpuMilli)m"
    }

    public var memoryUsageFormatted: String {
        "\(memoryMiB) MiB"
    }

    public var cpuLimitPercent: Int? {
        guard let cpuLimitMilli, cpuLimitMilli > 0 else { return nil }
        return Int((Double(cpuMilli) / Double(cpuLimitMilli)) * 100.0)
    }

    public var memoryLimitPercent: Int? {
        guard let memoryLimitMiB, memoryLimitMiB > 0 else { return nil }
        return Int((Double(memoryMiB) / Double(memoryLimitMiB)) * 100.0)
    }

    public var diskUsedPercent: Int? {
        guard let diskUsedBytes, let diskCapacityBytes, diskCapacityBytes > 0 else { return nil }
        return Int((Double(diskUsedBytes) / Double(diskCapacityBytes)) * 100.0)
    }
}

/// Helper service for metrics processing and ranking top resource consumers.
public struct KubernetesMetricsService {
    public static func topCPUConsumers(from items: [KubernetesResourceMetrics], limit: Int = 10) -> [KubernetesResourceMetrics] {
        Array(items.sorted { $0.cpuMilli > $1.cpuMilli }.prefix(limit))
    }

    public static func topMemoryConsumers(from items: [KubernetesResourceMetrics], limit: Int = 10) -> [KubernetesResourceMetrics] {
        Array(items.sorted { $0.memoryMiB > $1.memoryMiB }.prefix(limit))
    }
}
