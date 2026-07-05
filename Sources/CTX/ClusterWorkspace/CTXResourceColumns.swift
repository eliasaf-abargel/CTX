import CTXCore
import SwiftUI

/// A single column definition for `CTXResourceTable`. `key` must match a key in
/// `KubernetesResourceRow.cells`.
struct CTXTableColumn: Identifiable, Equatable {
    enum Alignment {
        case leading
        case trailing
    }

    var id: String { key }
    let key: String
    var title: String
    var minWidth: CGFloat
    var idealWidth: CGFloat
    var maxWidth: CGFloat
    var alignment: Alignment = .leading
    /// Higher priority survives longer when the table has to shed columns to fit a
    /// compact width. Ties keep their original left-to-right order.
    var priority: Int = 0
    var hideOnCompact: Bool = false
    var monospaced: Bool = false
    /// Exactly one column per kind should be `isFlexible` — it absorbs unused width
    /// on a wide window instead of the table leaving a dead strip of background,
    /// and shrinks first (down to `minWidth`) on a narrow one.
    var isFlexible: Bool = false
    /// Only set for values someone would actually copy elsewhere — a name, an IP, a
    /// hostname. Age/status/counts are read at a glance, never pasted anywhere, so an
    /// icon there is visual noise, not a convenience.
    var copyable: Bool = false

    static func text(_ key: String, min: CGFloat, ideal: CGFloat, max: CGFloat, priority: Int = 1, hideOnCompact: Bool = false, flexible: Bool = false, copyable: Bool = false) -> CTXTableColumn {
        CTXTableColumn(key: key, title: key, minWidth: min, idealWidth: ideal, maxWidth: max, priority: priority, hideOnCompact: hideOnCompact, isFlexible: flexible, copyable: copyable)
    }

    static func numeric(_ key: String, min: CGFloat, ideal: CGFloat, max: CGFloat, priority: Int = 1, hideOnCompact: Bool = false) -> CTXTableColumn {
        CTXTableColumn(key: key, title: key, minWidth: min, idealWidth: ideal, maxWidth: max, alignment: .trailing, priority: priority, hideOnCompact: hideOnCompact)
    }
}

/// Per-kind column definitions, replacing the old hand-tuned `width(for:)` +
/// `compactColumns`/`regularColumns` name-filtering pair in `ClusterResourceListView`
/// with one declarative source of truth per resource kind.
///
/// Copy-icon policy (`copyable: true`): resource name, namespace, an event's object
/// reference or message, a service's cluster/external IP and ports, an ingress host
/// or assigned address, a node's IP — values someone would paste into a terminal,
/// browser, or ticket. Never on age, status, ready/available counts, label/key
/// counts, restarts, roles, versions, or generic type strings — those are read, not
/// copied.
enum CTXResourceColumns {
    static func columns(for kind: KubernetesResourceKind) -> [CTXTableColumn] {
        switch kind {
        case .namespaces:
            [
                .text("Name", min: 140, ideal: 220, max: 420, priority: 3, flexible: true, copyable: true),
                .text("Status", min: 70, ideal: 90, max: 110, priority: 2),
                .numeric("Age", min: 55, ideal: 65, max: 80, priority: 2),
                .numeric("Labels", min: 55, ideal: 65, max: 80, priority: 1, hideOnCompact: true)
            ]
        case .nodes:
            [
                .text("Name", min: 140, ideal: 220, max: 420, priority: 3, flexible: true, copyable: true),
                .text("Ready", min: 60, ideal: 70, max: 80, priority: 3),
                .text("Roles", min: 90, ideal: 130, max: 200, priority: 2),
                .text("Version", min: 90, ideal: 110, max: 150, priority: 1, hideOnCompact: true),
                .numeric("Age", min: 55, ideal: 65, max: 80, priority: 2),
                .text("IP", min: 100, ideal: 120, max: 160, priority: 1, hideOnCompact: true, copyable: true)
            ]
        case .workloads:
            [
                .text("Namespace", min: 100, ideal: 150, max: 260, priority: 2, copyable: true),
                .text("Kind", min: 80, ideal: 100, max: 130, priority: 2),
                .text("Name", min: 140, ideal: 220, max: 420, priority: 3, flexible: true, copyable: true),
                .text("Ready", min: 60, ideal: 70, max: 90, priority: 3),
                .numeric("Available", min: 70, ideal: 80, max: 100, priority: 1, hideOnCompact: true),
                .numeric("Age", min: 55, ideal: 65, max: 80, priority: 2)
            ]
        case .pods:
            [
                .text("Namespace", min: 100, ideal: 150, max: 260, priority: 2, copyable: true),
                .text("Name", min: 140, ideal: 220, max: 420, priority: 3, flexible: true, copyable: true),
                .text("Status", min: 80, ideal: 100, max: 130, priority: 3),
                .text("Ready", min: 55, ideal: 65, max: 80, priority: 2),
                .numeric("Restarts", min: 65, ideal: 80, max: 100, priority: 1, hideOnCompact: true),
                .numeric("Age", min: 55, ideal: 65, max: 80, priority: 2),
                .text("Node", min: 100, ideal: 140, max: 220, priority: 1, hideOnCompact: true)
            ]
        case .services:
            [
                .text("Namespace", min: 100, ideal: 150, max: 260, priority: 2, copyable: true),
                .text("Name", min: 140, ideal: 210, max: 420, priority: 3, flexible: true, copyable: true),
                .text("Type", min: 80, ideal: 100, max: 130, priority: 2),
                .text("Cluster IP", min: 100, ideal: 130, max: 160, priority: 1, hideOnCompact: true, copyable: true),
                .text("External", min: 90, ideal: 120, max: 200, priority: 1, hideOnCompact: true, copyable: true),
                .text("Ports", min: 110, ideal: 170, max: 280, priority: 2, copyable: true),
                .numeric("Age", min: 55, ideal: 65, max: 80, priority: 1, hideOnCompact: true)
            ]
        case .ingress:
            [
                .text("Namespace", min: 100, ideal: 150, max: 260, priority: 2, copyable: true),
                .text("Name", min: 140, ideal: 200, max: 380, priority: 3, flexible: true, copyable: true),
                .text("Class", min: 70, ideal: 90, max: 120, priority: 1, hideOnCompact: true),
                .text("Hosts", min: 130, ideal: 200, max: 340, priority: 2, copyable: true),
                .text("TLS", min: 50, ideal: 60, max: 80, priority: 1, hideOnCompact: true),
                .text("Address", min: 100, ideal: 150, max: 240, priority: 1, hideOnCompact: true, copyable: true),
                .numeric("Age", min: 55, ideal: 65, max: 80, priority: 1, hideOnCompact: true)
            ]
        case .configMaps:
            [
                .text("Namespace", min: 100, ideal: 150, max: 260, priority: 2, copyable: true),
                .text("Name", min: 140, ideal: 220, max: 420, priority: 3, flexible: true, copyable: true),
                .numeric("Keys", min: 55, ideal: 65, max: 80, priority: 2),
                .numeric("Age", min: 55, ideal: 65, max: 80, priority: 2)
            ]
        case .secretMetadata:
            [
                .text("Namespace", min: 100, ideal: 150, max: 260, priority: 2, copyable: true),
                .text("Name", min: 140, ideal: 220, max: 420, priority: 3, flexible: true, copyable: true),
                .text("Type", min: 110, ideal: 150, max: 220, priority: 1, hideOnCompact: true),
                .numeric("Keys", min: 55, ideal: 65, max: 80, priority: 2),
                .numeric("Age", min: 55, ideal: 65, max: 80, priority: 2)
            ]
        case .events:
            [
                .text("Namespace", min: 100, ideal: 150, max: 260, priority: 2, copyable: true),
                .text("Object", min: 130, ideal: 200, max: 340, priority: 3, copyable: true),
                .text("Type", min: 70, ideal: 90, max: 110, priority: 2),
                .text("Reason", min: 100, ideal: 130, max: 180, priority: 2),
                .text("Message", min: 160, ideal: 280, max: 520, priority: 3, flexible: true, copyable: true),
                .text("Last", min: 55, ideal: 65, max: 80, priority: 1, hideOnCompact: true),
                .numeric("Count", min: 55, ideal: 65, max: 80, priority: 1, hideOnCompact: true)
            ]
        }
    }
}
