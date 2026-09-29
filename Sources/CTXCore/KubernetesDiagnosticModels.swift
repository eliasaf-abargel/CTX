import Foundation

public enum DiagnosticSeverity: String, Codable, Equatable, Hashable, Sendable, Comparable {
    case info = "Info"
    case warning = "Warning"
    case error = "Error"

    public var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }

    public static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    public var systemImage: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

public enum DiagnosticCategory: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case configuration = "Configuration"
    case security = "Security"
    case reliability = "Reliability"
    case runtime = "Runtime"

    public var systemImage: String {
        switch self {
        case .configuration: "gearshape.triangle"
        case .security: "shield.lefthalf.filled"
        case .reliability: "heart.slash.fill"
        case .runtime: "bolt.trianglebadge.exclamationmark"
        }
    }
}

public struct ResourceDiagnosticIssue: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let resourceID: String
    public let resourceName: String
    public let resourceNamespace: String?
    public let resourceKind: KubernetesResourceKind
    public let severity: DiagnosticSeverity
    public let category: DiagnosticCategory
    public let ruleId: String
    public let title: String
    public let message: String
    public let recommendation: String

    public init(
        resourceID: String,
        resourceName: String,
        resourceNamespace: String?,
        resourceKind: KubernetesResourceKind,
        severity: DiagnosticSeverity,
        category: DiagnosticCategory,
        ruleId: String,
        title: String,
        message: String,
        recommendation: String
    ) {
        // Deterministic from what the finding actually is (this rule, on this
        // resource) rather than a fresh UUID per recalculation — `allIssues` is
        // rebuilt from scratch on nearly every resource refresh, and a stable id
        // is what lets SwiftUI's `ForEach` recognize an unchanged finding instead
        // of treating it as newly inserted (losing scroll position, re-animating)
        // and what lets notification dispatch tell "still broken" apart from
        // "just broke."
        self.id = "\(ruleId)|\(resourceID)"
        self.resourceID = resourceID
        self.resourceName = resourceName
        self.resourceNamespace = resourceNamespace
        self.resourceKind = resourceKind
        self.severity = severity
        self.category = category
        self.ruleId = ruleId
        self.title = title
        self.message = message
        self.recommendation = recommendation
    }
}

public struct KubernetesDiagnosticReport: Equatable, Sendable {
    public var issuesByResourceID: [String: [ResourceDiagnosticIssue]]
    public var allIssues: [ResourceDiagnosticIssue]
    public var errorCount: Int
    public var warningCount: Int
    public var infoCount: Int

    public static let empty = KubernetesDiagnosticReport(
        issuesByResourceID: [:],
        allIssues: [],
        errorCount: 0,
        warningCount: 0,
        infoCount: 0
    )

    public init(
        issuesByResourceID: [String: [ResourceDiagnosticIssue]],
        allIssues: [ResourceDiagnosticIssue],
        errorCount: Int,
        warningCount: Int,
        infoCount: Int
    ) {
        self.issuesByResourceID = issuesByResourceID
        self.allIssues = allIssues
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.infoCount = infoCount
    }
}
