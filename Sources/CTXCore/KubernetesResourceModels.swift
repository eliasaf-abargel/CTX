import Foundation

public enum KubernetesNamespaceSelection: Codable, Equatable, Sendable {
    case defaultNamespace
    case allNamespaces
    case namespace(String)

    public var displayName: String {
        switch self {
        case .defaultNamespace: "default"
        case .allNamespaces: "All namespaces"
        case .namespace(let name): name
        }
    }

    public var commandArguments: [String] {
        switch self {
        case .defaultNamespace: ["--namespace", "default"]
        case .allNamespaces: ["--all-namespaces"]
        case .namespace(let name): ["--namespace", name]
        }
    }

    public var storageValue: String {
        switch self {
        case .defaultNamespace: "default"
        case .allNamespaces: "__all__"
        case .namespace(let name): name
        }
    }

    public var scopeTitle: String {
        switch self {
        case .defaultNamespace: "Namespace default"
        case .allNamespaces: "All namespaces"
        case .namespace(let name): "Namespace \(name)"
        }
    }
}

public enum KubernetesResourceKind: String, CaseIterable, Codable, Sendable {
    case namespaces
    case nodes
    case workloads
    case pods
    case cronJobs
    case services
    case ingress
    case configMaps
    case secretMetadata
    case events
    case hpa
    case pvc

    public var title: String {
        switch self {
        case .configMaps: "ConfigMaps"
        case .secretMetadata: "Secrets"
        case .cronJobs: "CronJobs"
        case .hpa: "HPA"
        case .pvc: "Storage (PVC)"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    public var isClusterScoped: Bool {
        self == .namespaces || self == .nodes
    }

    var kubectlResource: String {
        switch self {
        case .namespaces: "namespaces"
        case .nodes: "nodes"
        case .workloads: "deployments,statefulsets,daemonsets"
        case .pods: "pods"
        case .cronJobs: "cronjobs"
        case .services: "services"
        case .ingress: "ingress"
        case .configMaps: "configmaps"
        case .secretMetadata: "secrets"
        case .events: "events"
        case .hpa: "hpa"
        case .pvc: "pvc"
        }
    }

    public var supportsInspectionYAML: Bool {
        switch self {
        case .namespaces, .nodes, .pods, .cronJobs, .services, .ingress, .events, .hpa, .pvc, .workloads, .configMaps:
            true
        case .secretMetadata:
            false
        }
    }

    public var detailTitle: String {
        switch self {
        case .namespaces: "Namespace"
        case .nodes: "Node"
        case .workloads: "Workload"
        case .pods: "Pod"
        case .cronJobs: "CronJob"
        case .services: "Service"
        case .ingress: "Ingress"
        case .configMaps: "ConfigMap"
        case .secretMetadata: "Secret metadata"
        case .events: "Event"
        case .hpa: "HPA"
        case .pvc: "PersistentVolumeClaim"
        }
    }
}

public struct KubernetesResourceRef: Codable, Equatable, Hashable, Sendable {
    public var contextID: String
    public var contextName: String
    public var kubeconfigPath: String
    public var kind: KubernetesResourceKind
    public var namespace: String?
    public var name: String

    public init(
        contextID: String,
        contextName: String,
        kubeconfigPath: String,
        kind: KubernetesResourceKind,
        namespace: String?,
        name: String
    ) {
        self.contextID = contextID
        self.contextName = contextName
        self.kubeconfigPath = kubeconfigPath
        self.kind = kind
        self.namespace = kind.isClusterScoped ? nil : namespace
        self.name = name
    }

    public init(context: KubernetesContextProfile, kind: KubernetesResourceKind, namespace: String?, name: String) {
        self.init(
            contextID: context.id,
            contextName: context.contextName,
            kubeconfigPath: context.kubeconfigPath,
            kind: kind,
            namespace: namespace,
            name: name
        )
    }
}

public struct KubernetesEventObjectTarget: Equatable, Sendable {
    public var kind: KubernetesResourceKind
    public var namespace: String?
    public var name: String

    public init?(object: String, namespace: String?) {
        let parts = object.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = Self.kind(from: parts[0]), !parts[1].isEmpty else { return nil }
        self.kind = kind
        self.namespace = kind.isClusterScoped ? nil : namespace
        self.name = parts[1]
    }

    private static func kind(from value: String) -> KubernetesResourceKind? {
        switch value.lowercased() {
        case "namespace": .namespaces
        case "node": .nodes
        case "pod": .pods
        case "service": .services
        case "ingress": .ingress
        case "configmap": .configMaps
        case "secret": .secretMetadata
        case "deployment", "statefulset", "daemonset": .workloads
        case "hpa", "horizontalpodautoscaler": .hpa
        case "pvc", "persistentvolumeclaim": .pvc
        default: nil
        }
    }
}

public struct KubernetesResourceRow: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let cells: [String: String]
    public var warning: Bool
    public var sortValue: String?
    public var ref: KubernetesResourceRef?

    /// Everything searchable about this row, lowercased, built once when the row is
    /// created. Filtering then costs one substring scan instead of rebuilding the
    /// haystack — the search field re-filters the whole list on every keystroke, so
    /// the work belongs on the fetch (once per row) rather than on the keystroke
    /// (once per row per character typed).
    ///
    /// `id` and `cells` are `let` so this can never drift out of sync with them.
    private let searchHaystack: String

    private enum CodingKeys: String, CodingKey {
        case id, cells, warning, sortValue, ref
    }

    public init(id: String, cells: [String: String], warning: Bool = false, sortValue: String? = nil, ref: KubernetesResourceRef? = nil) {
        self.id = id
        self.cells = cells
        self.warning = warning
        self.sortValue = sortValue
        self.ref = ref
        self.searchHaystack = Self.makeHaystack(id: id, cells: cells)
    }

    /// Derived, so it is rebuilt on decode rather than stored in the disk cache.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cells = try container.decode([String: String].self, forKey: .cells)
        warning = try container.decodeIfPresent(Bool.self, forKey: .warning) ?? false
        sortValue = try container.decodeIfPresent(String.self, forKey: .sortValue)
        ref = try container.decodeIfPresent(KubernetesResourceRef.self, forKey: .ref)
        searchHaystack = Self.makeHaystack(id: id, cells: cells)
    }

    /// Keys are sorted so the haystack is canonical. `Dictionary` iteration order
    /// depends on how the dictionary was built, not only on its contents, so a row
    /// decoded from the disk cache would otherwise produce a differently-ordered
    /// haystack than the identical freshly-parsed row — and compare unequal.
    /// Derived state is excluded: two rows with the same data are the same row, and
    /// comparing the haystacks would mean a full string comparison per row every
    /// time SwiftUI diffs the list.
    public static func == (lhs: KubernetesResourceRow, rhs: KubernetesResourceRow) -> Bool {
        lhs.id == rhs.id
            && lhs.warning == rhs.warning
            && lhs.sortValue == rhs.sortValue
            && lhs.ref == rhs.ref
            && lhs.cells == rhs.cells
    }

    private static func makeHaystack(id: String, cells: [String: String]) -> String {
        var haystack = id
        for key in cells.keys.sorted() {
            haystack.append(" ")
            haystack.append(key)
            haystack.append(" ")
            haystack.append(cells[key] ?? "")
        }
        return haystack.lowercased()
    }

    /// Whether this row matches a search term.
    public func matchesFilter(_ filter: String) -> Bool {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        return searchHaystack.contains(trimmed)
    }

    /// Substring search over the raw UTF-8 bytes.
    func matches(preparedNeedle needle: ContiguousArray<UInt8>) -> Bool {
        guard !needle.isEmpty else { return true }
        guard let s = String(bytes: needle, encoding: .utf8) else { return false }
        return searchHaystack.contains(s)
    }

    /// Filters a list against search terms. Supports multi-token searches (space separated)
    /// where all positive terms must match the row, and terms prefixed with `-` act as
    /// exclusion filters.
    public static func filtered(_ rows: [KubernetesResourceRow], matching filter: String) -> [KubernetesResourceRow] {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rows }

        let rawTokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !rawTokens.isEmpty else { return rows }

        var positiveTokens: [String] = []
        var negativeTokens: [String] = []

        for token in rawTokens {
            let lower = token.lowercased()
            if lower.hasPrefix("-") && lower.count > 1 {
                negativeTokens.append(String(lower.dropFirst()))
            } else {
                positiveTokens.append(lower)
            }
        }

        return rows.filter { row in
            let haystack = row.searchHaystack
            for neg in negativeTokens {
                if haystack.contains(neg) {
                    return false
                }
            }
            for pos in positiveTokens {
                if !haystack.contains(pos) {
                    return false
                }
            }
            return true
        }
    }

    static func preparedNeedle(from filter: String) -> ContiguousArray<UInt8> {
        ContiguousArray(filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
    }

    public var name: String {
        if let ref { return ref.name }
        return cells["Name"] ?? id.split(separator: "/").last.map(String.init) ?? id
    }

    public var namespace: String? {
        if let namespace = ref?.namespace { return namespace }
        guard let value = cells["Namespace"], !value.isEmpty, value != "-" else { return nil }
        return value
    }

    public func reference(kind: KubernetesResourceKind, context: KubernetesContextProfile) -> KubernetesResourceRef {
        ref ?? KubernetesResourceRef(context: context, kind: kind, namespace: namespace, name: name)
    }
}

public struct KubernetesResourceList: Codable, Equatable, Sendable {
    public var kind: KubernetesResourceKind
    public var columns: [String]
    public var rows: [KubernetesResourceRow]
    public var status: KubernetesCheckStatus
    public var diagnostic: KubernetesCommandDiagnostic?
    public var loadedAt: Date

    public init(
        kind: KubernetesResourceKind,
        columns: [String],
        rows: [KubernetesResourceRow],
        status: KubernetesCheckStatus,
        diagnostic: KubernetesCommandDiagnostic? = nil,
        loadedAt: Date = Date()
    ) {
        self.kind = kind
        self.columns = columns
        self.rows = rows
        self.status = status
        self.diagnostic = diagnostic
        self.loadedAt = loadedAt
    }
}

public struct KubernetesResourceDetail: Equatable, Sendable {
    public struct Field: Equatable, Sendable, Identifiable {
        public var id: String { label }
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public var id: String { title }
        public var title: String
        public var fields: [Field]

        public init(title: String, fields: [Field]) {
            self.title = title
            self.fields = fields
        }
    }

    public var kind: KubernetesResourceKind
    public var title: String
    public var subtitle: String
    public var status: String
    public var warning: Bool
    public var safeReference: String
    public var supportsYAML: Bool
    public var safetyNote: String?
    public var sections: [Section]

    public init(kind: KubernetesResourceKind, row: KubernetesResourceRow) {
        self.kind = kind
        self.title = row.name
        self.subtitle = row.namespace.map { "\($0) · \(kind.detailTitle)" } ?? kind.detailTitle
        self.status = row.cells["Status"] ?? row.cells["Ready"] ?? row.cells["Type"] ?? "-"
        self.warning = row.warning
        self.safeReference = Self.reference(kind: kind, row: row)
        self.supportsYAML = kind.supportsInspectionYAML
        self.safetyNote = Self.safetyNote(kind: kind)
        self.sections = Self.sections(kind: kind, row: row)
    }

    private static func reference(kind: KubernetesResourceKind, row: KubernetesResourceRow) -> String {
        if let namespace = row.namespace {
            return "\(kind.title.lowercased())/\(row.name) -n \(namespace)"
        }
        return "\(kind.title.lowercased())/\(row.name)"
    }

    private static func safetyNote(kind: KubernetesResourceKind) -> String? {
        switch kind {
        case .secretMetadata:
            "Metadata only. Secret values are never requested or displayed."
        default:
            nil
        }
    }

    private static func sections(kind: KubernetesResourceKind, row: KubernetesResourceRow) -> [Section] {
        var sections: [Section] = [
            Section(title: "Identity", fields: compact([
                Field(label: "Kind", value: kind.detailTitle),
                Field(label: "Name", value: row.name),
                row.namespace.map { Field(label: "Namespace", value: $0) },
                Field(label: "Age", value: row.cells["Age"] ?? row.cells["Last"] ?? "-")
            ]))
        ]

        switch kind {
        case .namespaces:
            sections.append(Section(title: "State", fields: compact([
                Field(label: "Status", value: row.cells["Status"] ?? "-"),
                Field(label: "Labels", value: row.cells["Labels"] ?? "-")
            ])))
        case .nodes:
            sections.append(Section(title: "Node", fields: fields(row, ["Ready", "Roles", "Version", "IP"])))
        case .workloads:
            sections.append(Section(title: "Workload", fields: fields(row, ["Kind", "Ready", "Available", "Image"])))
        case .pods:
            sections.append(Section(title: "Pod", fields: fields(row, ["Status", "Ready", "Restarts", "Node", "Image"])))
        case .cronJobs:
            sections.append(Section(title: "CronJob", fields: fields(row, ["Schedule", "Suspend", "Active", "Last Schedule"])))
        case .services:
            sections.append(Section(title: "Service", fields: fields(row, ["Type", "Cluster IP", "External", "Ports"])))
        case .ingress:
            sections.append(Section(title: "Ingress", fields: fields(row, ["Class", "Hosts", "TLS", "Address"])))
        case .configMaps:
            sections.append(Section(title: "Metadata", fields: fields(row, ["Keys", "Data Keys"])))
        case .secretMetadata:
            sections.append(Section(title: "Metadata", fields: fields(row, ["Type", "Keys"])))
        case .events:
            sections.append(Section(title: "Event", fields: fields(row, ["Object", "Type", "Reason", "Message", "Count", "Last"])))
        case .hpa:
            sections.append(Section(title: "HPA", fields: fields(row, ["Reference", "Targets", "MinPods", "MaxPods", "Replicas"])))
        case .pvc:
            sections.append(Section(title: "Storage (PVC)", fields: fields(row, ["Status", "Volume", "Capacity", "Access Modes", "StorageClass"])))
        }

        return sections.filter { !$0.fields.isEmpty }
    }

    private static func fields(_ row: KubernetesResourceRow, _ labels: [String]) -> [Field] {
        labels.compactMap { label in
            guard let value = row.cells[label], !value.isEmpty else { return nil }
            return Field(label: label, value: value)
        }
    }

    private static func compact(_ fields: [Field?]) -> [Field] {
        fields.compactMap { $0 }
    }
}

public struct KubernetesYAMLResult: Equatable, Sendable {
    public var yaml: String?
    public var status: KubernetesCheckStatus
    public var diagnostic: KubernetesCommandDiagnostic?

    public init(yaml: String?, status: KubernetesCheckStatus, diagnostic: KubernetesCommandDiagnostic? = nil) {
        self.yaml = yaml
        self.status = status
        self.diagnostic = diagnostic
    }
}
