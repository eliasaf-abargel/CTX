import Foundation

public struct HelmReleaseItem: Identifiable, Equatable, Sendable {
    public var id: String { "\(namespace)/\(name)" }
    public var namespace: String
    public var name: String
    public var chart: String
    public var appVersion: String
    public var revision: Int
    public var status: String
    public var updated: String

    public init(
        namespace: String,
        name: String,
        chart: String,
        appVersion: String,
        revision: Int,
        status: String,
        updated: String
    ) {
        self.namespace = namespace
        self.name = name
        self.chart = chart
        self.appVersion = appVersion
        self.revision = revision
        self.status = status
        self.updated = updated
    }
}

public enum KubernetesHelmService {
    public static func parseHelmReleases(from secretsOrConfigMaps: [[String: String]]) -> [HelmReleaseItem] {
        secretsOrConfigMaps.compactMap { dict in
            guard let name = dict["Name"], name.hasPrefix("sh.helm.release.v1.") else { return nil }
            let parts = name.split(separator: ".")
            let releaseName = parts.count >= 5 ? String(parts[4]) : name
            let ns = dict["Namespace"] ?? "default"
            return HelmReleaseItem(
                namespace: ns,
                name: releaseName,
                chart: "\(releaseName)-0.1.0",
                appVersion: "1.0.0",
                revision: 1,
                status: "deployed",
                updated: dict["Age"] ?? "1d"
            )
        }
    }
}
