import Foundation

/// How a GitOps application gets its manifests. An ArgoCD `Application` is not
/// necessarily Git-backed: it can point straight at a Helm chart repository, at an
/// OCI registry, or at a Git repo whose manifests are *rendered* by Helm. Collapsing
/// all of those into "a repo URL" is what makes most dashboards misleading, so the
/// distinction is carried through to the table.
public enum GitOpsSourceKind: String, Equatable, Sendable {
    /// Plain manifests or Kustomize overlays in a Git repository.
    case git = "Git"
    /// A chart pulled from a Helm chart repository (`spec.source.chart` is set).
    case helmChart = "Helm chart"
    /// Manifests in Git that ArgoCD renders with Helm (`spec.source.helm` is set).
    case helmFromGit = "Helm (Git)"
    /// A chart or manifest bundle pulled from an OCI registry.
    case oci = "OCI"
    case unknown = "—"
}

public struct GitOpsApplicationItem: Identifiable, Equatable, Sendable {
    public var id: String { "\(provider)/\(namespace)/\(name)" }
    public var namespace: String
    public var name: String
    /// "ArgoCD" or "Flux CD".
    public var provider: String
    /// The controller's own resource kind — Application, Kustomization, HelmRelease.
    public var kind: String
    public var sourceKind: GitOpsSourceKind
    public var syncStatus: String
    public var healthStatus: String
    /// Git repository, chart repository, or OCI reference — whichever this app uses.
    public var repoURL: String
    /// Chart name when the source is a chart; unknown for plain Git sources.
    public var chart: String
    /// Path inside the repository, for Git-backed sources.
    public var path: String
    /// What the app is *configured* to track — a branch, tag, or chart version.
    public var targetRevision: String
    /// What is *actually* deployed right now, as the controller reports it.
    public var syncedRevision: String
    /// The ApplicationSet or parent that generated this app, when it wasn't
    /// created directly.
    public var managedBy: String
    /// Additional sources on a multi-source ArgoCD application, beyond the first.
    public var additionalSourceCount: Int
    public var age: String

    public init(
        namespace: String,
        name: String,
        provider: String,
        kind: String,
        sourceKind: GitOpsSourceKind = .unknown,
        syncStatus: String,
        healthStatus: String,
        repoURL: String,
        chart: String = KubernetesGitOpsService.unknownValue,
        path: String = KubernetesGitOpsService.unknownValue,
        targetRevision: String,
        syncedRevision: String = KubernetesGitOpsService.unknownValue,
        managedBy: String = KubernetesGitOpsService.unknownValue,
        additionalSourceCount: Int = 0,
        age: String
    ) {
        self.namespace = namespace
        self.name = name
        self.provider = provider
        self.kind = kind
        self.sourceKind = sourceKind
        self.syncStatus = syncStatus
        self.healthStatus = healthStatus
        self.repoURL = repoURL
        self.chart = chart
        self.path = path
        self.targetRevision = targetRevision
        self.syncedRevision = syncedRevision
        self.managedBy = managedBy
        self.additionalSourceCount = additionalSourceCount
        self.age = age
    }
}

/// Parses what the GitOps controllers actually report.
///
/// Every field comes from the live custom resource. Where a controller has not
/// populated a field, these parsers emit `unknownValue` rather than inventing a
/// plausible default — a row that claims "Synced" because nothing was reported is
/// worse than one that admits it does not know.
public enum KubernetesGitOpsService {
    public static let unknownValue = "—"

    // MARK: - ArgoCD

    public static func parseArgoCDApplications(_ items: [[String: Any]]) -> [GitOpsApplicationItem] {
        items.compactMap { item in
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            guard let name = metadata["name"] as? String, !name.isEmpty else { return nil }
            let spec = item["spec"] as? [String: Any] ?? [:]
            let status = item["status"] as? [String: Any] ?? [:]

            // ArgoCD 2.6+ supports `sources` (plural). The first entry is the one
            // shown; the rest are counted so a multi-source app never silently
            // looks like a single-source one.
            let multiSources = spec["sources"] as? [[String: Any]] ?? []
            let source = (spec["source"] as? [String: Any]) ?? multiSources.first ?? [:]
            let additional = max(0, multiSources.count - 1)

            let repoURL = (source["repoURL"] as? String) ?? ""
            let chart = (source["chart"] as? String) ?? ""
            let path = (source["path"] as? String) ?? ""
            let sourceKind = argoSourceKind(repoURL: repoURL, chart: chart, source: source)

            let syncDict = status["sync"] as? [String: Any] ?? [:]

            return GitOpsApplicationItem(
                namespace: (metadata["namespace"] as? String) ?? unknownValue,
                name: name,
                provider: "ArgoCD",
                kind: "Application",
                sourceKind: sourceKind,
                syncStatus: value(syncDict["status"]),
                healthStatus: value((status["health"] as? [String: Any])?["status"]),
                repoURL: value(repoURL),
                chart: value(chart),
                path: value(path),
                targetRevision: value(source["targetRevision"]),
                syncedRevision: shortRevision(syncDict["revision"] as? String),
                managedBy: argoOwner(metadata),
                additionalSourceCount: additional,
                age: relativeAge(from: metadata["creationTimestamp"] as? String)
            )
        }
    }

    /// A chart-sourced app sets `chart` and uses `repoURL` as the *chart repository*;
    /// a Git-sourced app that ArgoCD renders through Helm sets `source.helm` instead.
    /// Both are "Helm" to a user, but they are not the same thing, and the target
    /// revision means something different in each (chart version vs branch/tag).
    static func argoSourceKind(repoURL: String, chart: String, source: [String: Any]) -> GitOpsSourceKind {
        if repoURL.lowercased().hasPrefix("oci://") { return .oci }
        if !chart.isEmpty { return .helmChart }
        if source["helm"] is [String: Any] { return .helmFromGit }
        if !repoURL.isEmpty { return .git }
        return .unknown
    }

    /// Apps produced by an ApplicationSet carry it as an owner reference. Surfacing
    /// it explains why editing the app directly would be reverted.
    private static func argoOwner(_ metadata: [String: Any]) -> String {
        let owners = metadata["ownerReferences"] as? [[String: Any]] ?? []
        guard let owner = owners.first(where: { ($0["kind"] as? String) == "ApplicationSet" }) ?? owners.first,
              let kind = owner["kind"] as? String,
              let name = owner["name"] as? String
        else { return unknownValue }
        return "\(kind)/\(name)"
    }

    // MARK: - Flux

    public static func parseFluxKustomizations(_ items: [[String: Any]]) -> [GitOpsApplicationItem] {
        items.compactMap { item in
            fluxItem(item, kind: "Kustomization", sourceKind: .git) { spec, status in
                let sourceRef = spec["sourceRef"] as? [String: Any] ?? [:]
                return FluxSource(
                    repo: value(sourceRef["name"]),
                    chart: unknownValue,
                    path: value(spec["path"]),
                    target: unknownValue,
                    synced: shortRevision(status["lastAppliedRevision"] as? String)
                )
            }
        }
    }

    public static func parseFluxHelmReleases(_ items: [[String: Any]]) -> [GitOpsApplicationItem] {
        items.compactMap { item in
            fluxItem(item, kind: "HelmRelease", sourceKind: .helmChart) { spec, status in
                // Flux nests the chart under `spec.chart.spec`; `chartRef` is the
                // newer OCI-style form.
                let chartSpec = ((spec["chart"] as? [String: Any])?["spec"] as? [String: Any]) ?? [:]
                let sourceRef = (chartSpec["sourceRef"] as? [String: Any])
                    ?? (spec["chartRef"] as? [String: Any])
                    ?? [:]
                let applied = (status["lastAppliedRevision"] as? String)
                    ?? (status["lastAttemptedRevision"] as? String)
                return FluxSource(
                    repo: value(sourceRef["name"]),
                    chart: value(chartSpec["chart"] ?? sourceRef["name"]),
                    path: unknownValue,
                    target: value(chartSpec["version"]),
                    synced: value(applied)
                )
            }
        }
    }

    private struct FluxSource {
        let repo: String
        let chart: String
        let path: String
        let target: String
        let synced: String
    }

    /// Flux reports readiness through the standard `Ready` condition rather than a
    /// dedicated sync/health pair, so both columns derive from it — including the
    /// "not reported yet" case, which stays unknown instead of defaulting to healthy.
    private static func fluxItem(
        _ item: [String: Any],
        kind: String,
        sourceKind: GitOpsSourceKind,
        source: ([String: Any], [String: Any]) -> FluxSource
    ) -> GitOpsApplicationItem? {
        let metadata = item["metadata"] as? [String: Any] ?? [:]
        guard let name = metadata["name"] as? String, !name.isEmpty else { return nil }
        let spec = item["spec"] as? [String: Any] ?? [:]
        let status = item["status"] as? [String: Any] ?? [:]
        let conditions = status["conditions"] as? [[String: Any]] ?? []
        let ready = conditions.first { ($0["type"] as? String) == "Ready" }

        let syncStatus: String
        let healthStatus: String
        if spec["suspend"] as? Bool == true {
            syncStatus = "Suspended"
            healthStatus = unknownValue
        } else {
            switch ready?["status"] as? String {
            case "True":
                syncStatus = "Synced"
                healthStatus = "Healthy"
            case "False":
                syncStatus = "OutOfSync"
                healthStatus = (ready?["reason"] as? String) ?? "Degraded"
            default:
                syncStatus = "Progressing"
                healthStatus = unknownValue
            }
        }

        let resolved = source(spec, status)
        return GitOpsApplicationItem(
            namespace: (metadata["namespace"] as? String) ?? unknownValue,
            name: name,
            provider: "Flux CD",
            kind: kind,
            sourceKind: sourceKind,
            syncStatus: syncStatus,
            healthStatus: healthStatus,
            repoURL: resolved.repo,
            chart: resolved.chart,
            path: resolved.path,
            targetRevision: resolved.target,
            syncedRevision: resolved.synced,
            age: relativeAge(from: metadata["creationTimestamp"] as? String)
        )
    }

    // MARK: - Shared

    private static func value(_ raw: Any?) -> String {
        guard let text = raw as? String, !text.isEmpty else { return unknownValue }
        return text
    }

    /// Shortens a commit SHA for display while keeping everything that carries
    /// meaning. Chart versions and branch names are not SHAs and are returned
    /// untouched; Flux's `main@sha1:abcdef…` form keeps its branch, because
    /// "which branch" is half of what the field is telling you — dropping it left
    /// a bare hash with no indication of what it was tracking.
    public static func shortRevision(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return unknownValue }

        // Flux: "<branch>@<algorithm>:<digest>" (or the older "<branch>/<digest>").
        for separator in ["@", "/"] where raw.contains(separator) {
            let parts = raw.components(separatedBy: separator)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            let digest = parts[1].components(separatedBy: ":").last ?? parts[1]
            guard let short = abbreviated(digest) else { continue }
            return "\(parts[0])@\(short)"
        }

        // ArgoCD: a bare SHA, or an OCI digest as "sha256:<digest>".
        let bare = raw.components(separatedBy: ":").last ?? raw
        return abbreviated(bare) ?? raw
    }

    /// Only abbreviates something that is unambiguously a hex digest — a chart
    /// version like "56.2.1" or a tag must survive intact.
    private static func abbreviated(_ candidate: String) -> String? {
        guard candidate.count >= 40, candidate.allSatisfy(\.isHexDigit) else { return nil }
        return String(candidate.prefix(7))
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter = ISO8601DateFormatter()

    static func relativeAge(from timestamp: String?) -> String {
        guard let timestamp, !timestamp.isEmpty else { return unknownValue }
        guard let date = fractionalFormatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp) else {
            return unknownValue
        }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}
