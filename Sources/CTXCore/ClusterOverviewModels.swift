import Foundation

public enum KubernetesCheckStatus: String, Codable, Equatable, Sendable {
    case notChecked
    case reachable
    case unreachable
    case contextNotFound
    case unauthorized
    case kubectlMissing
    case timeout
    case permissionDenied
    case authPluginFailed
    case awsSSOExpired
    case gcpAuthExpired
    case tlsError
    case kubeconfigError
    case unknownError
}

public enum KubernetesDiagnosticCategory: String, Codable, Equatable, Sendable {
    case success
    case kubectlMissing
    case contextNotFound
    case clusterUnreachable
    case localProxyUnavailable
    case authPluginFailed
    case awsSSOExpired
    case gcpAuthExpired
    case unauthorized
    case forbidden
    case timeout
    case tlsCertificate
    case kubeconfig
    case unknown
}

public struct KubernetesCommandDiagnostic: Codable, Equatable, Sendable {
    public var commandKind: String
    public var contextName: String
    public var kubeconfigPath: String
    public var exitCode: Int32?
    public var durationMilliseconds: Int
    public var category: KubernetesDiagnosticCategory
    public var stderrSummary: String
    public var timestamp: Date

    public init(
        commandKind: String,
        contextName: String,
        kubeconfigPath: String,
        exitCode: Int32?,
        durationMilliseconds: Int,
        category: KubernetesDiagnosticCategory,
        stderrSummary: String,
        timestamp: Date = Date()
    ) {
        self.commandKind = commandKind
        self.contextName = contextName
        self.kubeconfigPath = kubeconfigPath
        self.exitCode = exitCode
        self.durationMilliseconds = durationMilliseconds
        self.category = category
        self.stderrSummary = stderrSummary
        self.timestamp = timestamp
    }

    public var safeSummary: String {
        let path = kubeconfigPath.isEmpty ? "default kubeconfig" : kubeconfigPath
        return "\(commandKind) · context=\(contextName) · kubeconfig=\(path) · category=\(category.rawValue) · exit=\(exitCode.map(String.init) ?? "n/a") · \(durationMilliseconds)ms · \(stderrSummary)"
    }
}

public struct KubernetesPermissionSummary: Codable, Equatable, Sendable {
    public var resource: String
    public var allowed: Bool?
    public var status: KubernetesCheckStatus

    public init(resource: String, allowed: Bool?, status: KubernetesCheckStatus) {
        self.resource = resource
        self.allowed = allowed
        self.status = status
    }
}

public struct KubernetesNamespacesSummary: Codable, Equatable, Sendable {
    public var count: Int?
    public var activeNamespace: String
    public var status: KubernetesCheckStatus

    public init(count: Int?, activeNamespace: String, status: KubernetesCheckStatus) {
        self.count = count
        self.activeNamespace = activeNamespace
        self.status = status
    }

    public static func summarize(rows: [KubernetesResourceRow], status: KubernetesCheckStatus, activeNamespace: String) -> KubernetesNamespacesSummary {
        guard status == .reachable else {
            return KubernetesNamespacesSummary(count: nil, activeNamespace: activeNamespace, status: status)
        }
        return KubernetesNamespacesSummary(count: rows.count, activeNamespace: activeNamespace, status: .reachable)
    }
}

public struct KubernetesNodesSummary: Codable, Equatable, Sendable {
    public var total: Int?
    public var ready: Int?
    public var notReady: Int?
    public var status: KubernetesCheckStatus

    public init(total: Int?, ready: Int?, notReady: Int?, status: KubernetesCheckStatus) {
        self.total = total
        self.ready = ready
        self.notReady = notReady
        self.status = status
    }

    public static func summarize(rows: [KubernetesResourceRow], status: KubernetesCheckStatus) -> KubernetesNodesSummary {
        guard status == .reachable else {
            return KubernetesNodesSummary(total: nil, ready: nil, notReady: nil, status: status)
        }
        let total = rows.count
        let ready = rows.filter { ($0.cells["Ready"] ?? "") == "Ready" }.count
        let notReady = total - ready
        return KubernetesNodesSummary(total: total, ready: ready, notReady: notReady, status: .reachable)
    }
}

public struct KubernetesPodsSummary: Codable, Equatable, Sendable {
    public var total: Int?
    public var running: Int
    public var pending: Int
    public var failed: Int
    public var crashLoopBackOff: Int
    public var failing: Int
    public var status: KubernetesCheckStatus

    public init(total: Int?, running: Int, pending: Int, failed: Int, crashLoopBackOff: Int, failing: Int, status: KubernetesCheckStatus) {
        self.total = total
        self.running = running
        self.pending = pending
        self.failed = failed
        self.crashLoopBackOff = crashLoopBackOff
        self.failing = failing
        self.status = status
    }

    public static func summarize(rows: [KubernetesResourceRow], status: KubernetesCheckStatus) -> KubernetesPodsSummary {
        guard status == .reachable else {
            return KubernetesPodsSummary(total: nil, running: 0, pending: 0, failed: 0, crashLoopBackOff: 0, failing: 0, status: status)
        }
        let statuses = rows.map { ($0.cells["Status"] ?? "").lowercased() }
        let running = statuses.filter { $0 == "running" }.count
        let pending = statuses.filter { $0 == "pending" }.count
        let failed = statuses.filter { $0 == "failed" }.count
        let crashLoop = statuses.filter { $0.contains("crashloop") || $0.contains("backoff") }.count
        return KubernetesPodsSummary(total: rows.count, running: running, pending: pending, failed: failed, crashLoopBackOff: crashLoop, failing: pending + failed + crashLoop, status: .reachable)
    }
}

public struct KubernetesWorkloadsSummary: Codable, Equatable, Sendable {
    public var total: Int?
    public var healthy: Int
    public var unhealthy: Int
    public var status: KubernetesCheckStatus

    public init(total: Int?, healthy: Int, unhealthy: Int, status: KubernetesCheckStatus) {
        self.total = total
        self.healthy = healthy
        self.unhealthy = unhealthy
        self.status = status
    }

    public static func summarize(rows: [KubernetesResourceRow], status: KubernetesCheckStatus) -> KubernetesWorkloadsSummary {
        guard status == .reachable else {
            return KubernetesWorkloadsSummary(total: nil, healthy: 0, unhealthy: 0, status: status)
        }
        let unhealthy = rows.filter(\.warning).count
        return KubernetesWorkloadsSummary(total: rows.count, healthy: rows.count - unhealthy, unhealthy: unhealthy, status: .reachable)
    }
}

public struct KubernetesServicesSummary: Codable, Equatable, Sendable {
    public var total: Int?
    public var exposed: Int
    public var status: KubernetesCheckStatus

    public init(total: Int?, exposed: Int, status: KubernetesCheckStatus) {
        self.total = total
        self.exposed = exposed
        self.status = status
    }

    public static func summarize(rows: [KubernetesResourceRow], status: KubernetesCheckStatus) -> KubernetesServicesSummary {
        guard status == .reachable else {
            return KubernetesServicesSummary(total: nil, exposed: 0, status: status)
        }
        let exposed = rows.filter {
            let external = ($0.cells["External"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !external.isEmpty && external != "-"
        }.count
        return KubernetesServicesSummary(total: rows.count, exposed: exposed, status: .reachable)
    }
}

public struct KubernetesIngressSummary: Codable, Equatable, Sendable {
    public var total: Int?
    public var routed: Int
    public var tls: Int
    public var status: KubernetesCheckStatus

    public init(total: Int?, routed: Int, tls: Int, status: KubernetesCheckStatus) {
        self.total = total
        self.routed = routed
        self.tls = tls
        self.status = status
    }

    public static func summarize(rows: [KubernetesResourceRow], status: KubernetesCheckStatus) -> KubernetesIngressSummary {
        guard status == .reachable else {
            return KubernetesIngressSummary(total: nil, routed: 0, tls: 0, status: status)
        }
        let routed = rows.filter {
            let hosts = ($0.cells["Hosts"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let address = ($0.cells["Address"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !hosts.isEmpty || !address.isEmpty
        }.count
        let tls = rows.filter { ($0.cells["TLS"] ?? "").localizedCaseInsensitiveContains("yes") }.count
        return KubernetesIngressSummary(total: rows.count, routed: routed, tls: tls, status: .reachable)
    }
}

public struct KubernetesConfigMapsSummary: Codable, Equatable, Sendable {
    public var total: Int?
    public var totalKeys: Int
    public var status: KubernetesCheckStatus

    public init(total: Int?, totalKeys: Int, status: KubernetesCheckStatus) {
        self.total = total
        self.totalKeys = totalKeys
        self.status = status
    }

    public static func summarize(rows: [KubernetesResourceRow], status: KubernetesCheckStatus) -> KubernetesConfigMapsSummary {
        guard status == .reachable else {
            return KubernetesConfigMapsSummary(total: nil, totalKeys: 0, status: status)
        }
        let totalKeys = rows.reduce(0) { sum, row in
            sum + (Int(row.cells["Keys"] ?? "") ?? 0)
        }
        return KubernetesConfigMapsSummary(total: rows.count, totalKeys: totalKeys, status: .reachable)
    }
}

public struct KubernetesSecretsSummary: Codable, Equatable, Sendable {
    public var total: Int?
    public var totalKeys: Int
    public var status: KubernetesCheckStatus

    public init(total: Int?, totalKeys: Int, status: KubernetesCheckStatus) {
        self.total = total
        self.totalKeys = totalKeys
        self.status = status
    }

    public static func summarize(rows: [KubernetesResourceRow], status: KubernetesCheckStatus) -> KubernetesSecretsSummary {
        guard status == .reachable else {
            return KubernetesSecretsSummary(total: nil, totalKeys: 0, status: status)
        }
        let totalKeys = rows.reduce(0) { sum, row in
            sum + (Int(row.cells["Keys"] ?? "") ?? 0)
        }
        return KubernetesSecretsSummary(total: rows.count, totalKeys: totalKeys, status: .reachable)
    }
}

public struct KubernetesEventsSummary: Codable, Equatable, Sendable {
    public var warningCount: Int?
    public var latestWarningReason: String?
    public var latestWarningObject: String?
    public var latestWarningLastSeen: String?
    public var topWarningReason: String?
    public var topWarningObject: String?
    public var topWarningCount: Int
    public var status: KubernetesCheckStatus

    public init(
        warningCount: Int?,
        latestWarningReason: String? = nil,
        latestWarningObject: String? = nil,
        latestWarningLastSeen: String? = nil,
        topWarningReason: String? = nil,
        topWarningObject: String? = nil,
        topWarningCount: Int = 0,
        status: KubernetesCheckStatus
    ) {
        self.warningCount = warningCount
        self.latestWarningReason = latestWarningReason
        self.latestWarningObject = latestWarningObject
        self.latestWarningLastSeen = latestWarningLastSeen
        self.topWarningReason = topWarningReason
        self.topWarningObject = topWarningObject
        self.topWarningCount = topWarningCount
        self.status = status
    }

    public static func summarize(rows: [KubernetesResourceRow], status: KubernetesCheckStatus) -> KubernetesEventsSummary {
        guard status == .reachable else {
            return KubernetesEventsSummary(warningCount: nil, status: status)
        }
        let warnings = rows.filter { row in
            let type = (row.cells["Type"] ?? "").lowercased()
            return type == "warning" || type == "error" || row.warning
        }
        let latest = warnings.first
        let top = warnings.reduce(into: [String: (reason: String, object: String, count: Int)]()) { groups, row in
            let reason = row.cells["Reason"] ?? ""
            let object = row.cells["Object"] ?? ""
            let key = "\(reason)\n\(object)"
            groups[key, default: (reason, object, 0)].count += 1
        }.values.max { lhs, rhs in
            lhs.count == rhs.count ? false : lhs.count < rhs.count
        }
        return KubernetesEventsSummary(
            warningCount: warnings.count,
            latestWarningReason: latest?.cells["Reason"],
            latestWarningObject: latest?.cells["Object"],
            latestWarningLastSeen: latest?.cells["Last"],
            topWarningReason: top?.reason,
            topWarningObject: top?.object,
            topWarningCount: top?.count ?? 0,
            status: .reachable
        )
    }
}

public struct KubernetesOverviewSummary: Codable, Equatable, Sendable {
    public var apiStatus: KubernetesCheckStatus
    public var rbac: [KubernetesPermissionSummary]
    public var namespaces: KubernetesNamespacesSummary
    public var nodes: KubernetesNodesSummary
    public var pods: KubernetesPodsSummary
    public var workloads: KubernetesWorkloadsSummary
    public var services: KubernetesServicesSummary
    public var ingress: KubernetesIngressSummary
    public var events: KubernetesEventsSummary
    public var diagnostics: [KubernetesCommandDiagnostic]

    public init(
        apiStatus: KubernetesCheckStatus,
        rbac: [KubernetesPermissionSummary],
        namespaces: KubernetesNamespacesSummary,
        nodes: KubernetesNodesSummary,
        pods: KubernetesPodsSummary,
        workloads: KubernetesWorkloadsSummary = KubernetesWorkloadsSummary(total: nil, healthy: 0, unhealthy: 0, status: .notChecked),
        services: KubernetesServicesSummary = KubernetesServicesSummary(total: nil, exposed: 0, status: .notChecked),
        ingress: KubernetesIngressSummary = KubernetesIngressSummary(total: nil, routed: 0, tls: 0, status: .notChecked),
        events: KubernetesEventsSummary,
        diagnostics: [KubernetesCommandDiagnostic] = []
    ) {
        self.apiStatus = apiStatus
        self.rbac = rbac
        self.namespaces = namespaces
        self.nodes = nodes
        self.pods = pods
        self.workloads = workloads
        self.services = services
        self.ingress = ingress
        self.events = events
        self.diagnostics = diagnostics
    }

    public static func notChecked(namespace: String) -> KubernetesOverviewSummary {
        KubernetesOverviewSummary(
            apiStatus: .notChecked,
            rbac: KubernetesRBACResource.allCases.map {
                KubernetesPermissionSummary(resource: $0.label, allowed: nil, status: .notChecked)
            },
            namespaces: KubernetesNamespacesSummary(count: nil, activeNamespace: namespace, status: .notChecked),
            nodes: KubernetesNodesSummary(total: nil, ready: nil, notReady: nil, status: .notChecked),
            pods: KubernetesPodsSummary(total: nil, running: 0, pending: 0, failed: 0, crashLoopBackOff: 0, failing: 0, status: .notChecked),
            workloads: KubernetesWorkloadsSummary(total: nil, healthy: 0, unhealthy: 0, status: .notChecked),
            services: KubernetesServicesSummary(total: nil, exposed: 0, status: .notChecked),
            ingress: KubernetesIngressSummary(total: nil, routed: 0, tls: 0, status: .notChecked),
            events: KubernetesEventsSummary(warningCount: nil, status: .notChecked),
            diagnostics: []
        )
    }

    public var hasLoadedData: Bool {
        apiStatus == .reachable ||
            namespaces.count != nil ||
            nodes.total != nil ||
            pods.total != nil ||
            workloads.total != nil ||
            services.total != nil ||
            ingress.total != nil ||
            events.warningCount != nil ||
            rbac.contains { $0.allowed != nil }
    }

    public var primaryFailure: KubernetesCommandDiagnostic? {
        diagnostics.first { $0.category != .success }
    }
}

public enum KubernetesRBACResource: CaseIterable, Sendable {
    case namespaces
    case nodes
    case pods
    case deployments
    case services
    case events
    case configMaps
    case secretsMetadata

    public var label: String {
        switch self {
        case .namespaces: "Namespaces"
        case .nodes: "Nodes"
        case .pods: "Pods"
        case .deployments: "Deployments"
        case .services: "Services"
        case .events: "Events"
        case .configMaps: "ConfigMaps"
        case .secretsMetadata: "Secrets metadata"
        }
    }

    public var kubectlResource: String {
        switch self {
        case .configMaps: "configmaps"
        case .secretsMetadata: "secrets"
        default: label.lowercased()
        }
    }

    public var allNamespaces: Bool {
        switch self {
        case .namespaces, .nodes: false
        default: true
        }
    }
}
