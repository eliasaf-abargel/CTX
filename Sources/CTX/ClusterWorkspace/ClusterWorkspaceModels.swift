import CTXCore
import SwiftUI

enum ClusterWorkspaceSection: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case namespaces = "Namespaces"
    case nodes = "Nodes"
    case workloads = "Workloads"
    case pods = "Pods"
    case services = "Services"
    case ingress = "Ingress"
    case configMaps = "ConfigMaps"
    case secrets = "Secrets"
    case events = "Events"
    case logs = "Logs"
    case exports = "Exports"
    case diff = "Diff"
    case portForward = "Port Forward"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .namespaces: "square.stack.3d.up"
        case .nodes: "server.rack"
        case .workloads: "shippingbox"
        case .pods: "circle.grid.3x3"
        case .services: "point.3.connected.trianglepath.dotted"
        case .ingress: "arrow.triangle.branch"
        case .configMaps: "doc.text"
        case .secrets: "lock.doc"
        case .events: "waveform.path.ecg"
        case .logs: "text.alignleft"
        case .exports: "square.and.arrow.down"
        case .diff: "arrow.left.arrow.right"
        case .portForward: "arrowshape.turn.up.right"
        }
    }

    var isFuture: Bool {
        self == .portForward
    }

    var resourceKind: KubernetesResourceKind? {
        switch self {
        case .namespaces: .namespaces
        case .nodes: .nodes
        case .workloads: .workloads
        case .pods: .pods
        case .services: .services
        case .ingress: .ingress
        case .configMaps: .configMaps
        case .secrets: .secretMetadata
        case .events: .events
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

/// Which tab of the resource inspector is active. YAML is always in the tab bar
/// (with an in-tab disabled explanation when unsupported); Logs only appears for
/// kinds where `visibleTabs(for:)` includes it.
enum CTXInspectorTab: CaseIterable, Equatable, Hashable {
    case overview
    case yaml
    case logs

    var title: String {
        switch self {
        case .overview: "Overview"
        case .yaml: "YAML"
        case .logs: "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "info.circle"
        case .yaml: "curlybraces"
        case .logs: "text.alignleft"
        }
    }

    /// Tabs actually shown for this resource kind. YAML is always shown (with an
    /// in-tab disabled explanation when unsupported — see `CTXInspectorYAMLTab`).
    /// Logs shows for Pods (real log-tailing), and for Services/Workloads (generic
    /// label-selector discovery of related Pods, then logs for whichever the user
    /// picks — see `KubernetesRelatedPods`). Every other kind has no Logs tab.
    static func visibleTabs(for kind: KubernetesResourceKind) -> [CTXInspectorTab] {
        switch kind {
        case .pods, .workloads, .services: [.overview, .yaml, .logs]
        default: [.overview, .yaml]
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
