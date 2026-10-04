import CTXCore
import SwiftUI

enum ClusterWorkspaceCategory: String, CaseIterable, Identifiable {
    case workspace = "Workspace"
    case workloads = "Workloads"
    case networkAndConfig = "Network & Config"
    case cluster = "Cluster"
    case observability = "Observability"
    case delivery = "Delivery"

    var id: String { rawValue }
}

enum ClusterWorkspaceSection: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case namespaces = "Namespaces"
    case nodes = "Nodes"
    case workloads = "Workloads"
    case pods = "Pods"
    case cronjobs = "CronJobs"
    case services = "Services"
    case ingress = "Ingress"
    case configMaps = "ConfigMaps"
    case secrets = "Secrets"
    case issues = "Issues"
    case events = "Events"
    case hpa = "HPA"
    case storage = "Storage"
    case gitops = "GitOps"
    case helm = "Helm"
    case topology = "Map"
    case logs = "Logs"
    case exports = "Exports"
    case diff = "Diff"
    case portForward = "Port Forward"

    var id: String { rawValue }

    var category: ClusterWorkspaceCategory {
        switch self {
        case .overview, .topology:
            return .workspace
        case .workloads, .pods, .cronjobs:
            return .workloads
        case .services, .ingress, .configMaps, .secrets, .portForward:
            return .networkAndConfig
        case .nodes, .namespaces, .storage, .hpa:
            return .cluster
        case .issues, .events, .logs:
            return .observability
        case .gitops, .helm, .diff, .exports:
            return .delivery
        }
    }

    var badgeColor: Color {
        switch self {
        case .overview: return .blue
        case .topology: return .indigo
        case .workloads: return .purple
        case .pods: return .cyan
        case .cronjobs: return .orange
        case .services: return .teal
        case .ingress: return .blue
        case .configMaps: return Color(nsColor: .systemGray)
        case .secrets: return .red
        case .portForward: return .green
        case .nodes: return .mint
        case .namespaces: return .indigo
        case .storage: return .orange
        case .hpa: return .teal
        case .issues: return .yellow
        case .events: return .pink
        case .logs: return Color(nsColor: .darkGray)
        case .gitops: return .purple
        case .helm: return .blue
        case .diff: return .indigo
        case .exports: return .secondary
        }
    }

    var badgeIcon: String {
        switch self {
        case .overview: return "rectangle.3.group.fill"
        case .topology: return "point.topleft.down.to.point.bottomright.curvepath"
        case .workloads: return "shippingbox.fill"
        case .pods: return "circle.grid.3x3.fill"
        case .cronjobs: return "clock.arrow.2.circlepath"
        case .services: return "point.3.connected.trianglepath.dotted"
        case .ingress: return "arrow.triangle.branch"
        case .configMaps: return "doc.text.fill"
        case .secrets: return "lock.fill"
        case .portForward: return "arrowshape.turn.up.right.fill"
        case .nodes: return "server.rack"
        case .namespaces: return "square.stack.3d.up.fill"
        case .storage: return "cylinder.split.1x2.fill"
        case .hpa: return "arrow.up.and.down.square.fill"
        case .issues: return "exclamationmark.triangle.fill"
        case .events: return "waveform.path.ecg"
        case .logs: return "text.alignleft"
        case .gitops: return "arrow.triangle.pull"
        case .helm: return "shippingbox.circle.fill"
        case .diff: return "arrow.left.arrow.right"
        case .exports: return "square.and.arrow.down.fill"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .namespaces: "square.stack.3d.up"
        case .nodes: "server.rack"
        case .workloads: "shippingbox"
        case .pods: "circle.grid.3x3"
        case .cronjobs: "clock.arrow.2.circlepath"
        case .services: "point.3.connected.trianglepath.dotted"
        case .ingress: "arrow.triangle.branch"
        case .configMaps: "doc.text"
        case .secrets: "lock.doc"
        case .issues: "exclamationmark.triangle"
        case .events: "waveform.path.ecg"
        case .hpa: "arrow.up.and.down.square"
        case .storage: "cylinder.split.1x2"
        case .gitops: "arrow.triangle.pull"
        case .helm: "shippingbox.circle"
        case .topology: "point.topleft.down.to.point.bottomright.curvepath"
        case .logs: "text.alignleft"
        case .exports: "square.and.arrow.down"
        case .diff: "arrow.left.arrow.right"
        case .portForward: "arrowshape.turn.up.right"
        }
    }

    var isFuture: Bool {
        false
    }

    var resourceKind: KubernetesResourceKind? {
        switch self {
        case .namespaces: .namespaces
        case .nodes: .nodes
        case .workloads: .workloads
        case .pods: .pods
        case .cronjobs: .cronJobs
        case .services: .services
        case .ingress: .ingress
        case .configMaps: .configMaps
        case .secrets: .secretMetadata
        case .events: .events
        case .hpa: .hpa
        case .storage: .pvc
        default: nil
        }
    }

    static func section(for kind: KubernetesResourceKind) -> ClusterWorkspaceSection? {
        allCases.first { $0.resourceKind == kind }
    }
}

struct ClusterWorkspaceMetric: Identifiable {
    var id: String { title }
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var targetSection: ClusterWorkspaceSection? = nil
}

struct ClusterOverviewNotice {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let diagnostics: String
    let commandHint: String
}

struct ClusterWorkspaceResourceSelection: Equatable {
    let section: ClusterWorkspaceSection
    let kind: KubernetesResourceKind
    let row: KubernetesResourceRow
}

/// Which tab of the resource inspector is active. YAML and Diagnostics are always
/// in the tab bar; Logs only appears for kinds where `visibleTabs(for:)` includes it.
enum CTXInspectorTab: CaseIterable, Equatable, Hashable {
    case overview
    case spec
    case diagnostics
    case yaml
    case logs

    var title: String {
        switch self {
        case .overview: "Overview"
        case .spec: "Spec & Config"
        case .diagnostics: "Diagnostics"
        case .yaml: "YAML"
        case .logs: "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "info.circle"
        case .spec: "slider.horizontal.3"
        case .diagnostics: "stethoscope"
        case .yaml: "curlybraces"
        case .logs: "text.alignleft"
        }
    }

    /// Tabs actually shown for this resource kind.
    static func visibleTabs(for kind: KubernetesResourceKind) -> [CTXInspectorTab] {
        switch kind {
        case .pods, .workloads, .services: [.overview, .spec, .diagnostics, .yaml, .logs]
        case .configMaps, .secretMetadata: [.overview, .spec, .diagnostics, .yaml]
        default: [.overview, .diagnostics, .yaml]
        }
    }
}

/// The single source of truth for "what's on screen right now": a resource
/// selection plus the active inspector tab, bundled as one value rather than two
/// independent flags that could disagree (that mismatch — a YAML-loading flag
/// left `true` after the resource it belonged to was cleared — was the exact bug
/// behind "YAML opens then instantly closes" from an earlier pass). Switching tabs
/// mutates `tab` on the *same* value, which SwiftUI's `.sheet(item:)` treats as
/// "update this presentation's content," not "dismiss and present a new one" —
/// `id` is derived only from the resource, never the tab, on purpose.
struct ClusterWorkspacePresentation: Identifiable, Equatable {
    let selection: ClusterWorkspaceResourceSelection
    var tab: CTXInspectorTab

    var id: String { "\(selection.kind.rawValue)|\(selection.row.id)" }
}

enum ClusterWorkspaceLayoutMode: Equatable {
    case compact
    case regular
    case expanded
    case wide

    init(width: CGFloat) {
        if width < 860 {
            self = .compact
        } else if width < 1180 {
            self = .regular
        } else if width < 1560 {
            self = .expanded
        } else {
            self = .wide
        }
    }
}

enum ClusterWorkspaceLayout {
    /// The horizontal padding every workspace screen applies to its content.
    static let pagePadding: CGFloat = 22
}

/// The workspace detail pane's width, measured once at the top and read by anything
/// that needs to size itself to the page — chiefly `CTXResourceTable`, which cannot
/// reliably measure its own frame from inside the page's scroll view.
private struct WorkspaceContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var workspaceContentWidth: CGFloat {
        get { self[WorkspaceContentWidthKey.self] }
        set { self[WorkspaceContentWidthKey.self] = newValue }
    }
}
