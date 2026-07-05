import Foundation

public struct LocalProfileDiscoveryResult: Sendable {
    public var profiles: [CloudProfile]
    public var kubernetesContexts: [KubernetesContextProfile]
    public var currentKubeContext: String
    public var activeGCPProfile: String

    public init(
        profiles: [CloudProfile],
        kubernetesContexts: [KubernetesContextProfile],
        currentKubeContext: String,
        activeGCPProfile: String
    ) {
        self.profiles = profiles
        self.kubernetesContexts = kubernetesContexts
        self.currentKubeContext = currentKubeContext
        self.activeGCPProfile = activeGCPProfile
    }
}

public final class LocalProfileDiscoveryService: Sendable {
    private let awsConfigURL: URL
    private let kubeConfigDiscoveryService: KubeConfigDiscoveryService

    public init(
        awsConfigURL: URL = AWSConfigPaths.configURL,
        kubeConfigDiscoveryService: KubeConfigDiscoveryService = KubeConfigDiscoveryService()
    ) {
        self.awsConfigURL = awsConfigURL
        self.kubeConfigDiscoveryService = kubeConfigDiscoveryService
    }

    public func discover() -> LocalProfileDiscoveryResult {
        let kube = kubeConfigDiscoveryService.discover()
        return discover(kube: kube)
    }

    public func discover(kubeconfigPaths: [URL]) -> LocalProfileDiscoveryResult {
        let kube = kubeConfigDiscoveryService.discover(paths: kubeconfigPaths)
        return discover(kube: kube)
    }

    private func discover(kube: KubeConfigDiscoveryResult) -> LocalProfileDiscoveryResult {
        var profiles = awsProfiles()
        profiles.append(contentsOf: gcpProfiles())
        profiles.append(contentsOf: azureProfiles())
        profiles.append(contentsOf: kube.contexts.map(KubernetesProfileAdapter.cloudProfile))

        return LocalProfileDiscoveryResult(
            profiles: profiles,
            kubernetesContexts: kube.contexts,
            currentKubeContext: kube.currentContext,
            activeGCPProfile: GCPConfigParser.parseActiveConfig()
        )
    }

    private func awsProfiles() -> [CloudProfile] {
        let text = (try? String(contentsOf: awsConfigURL, encoding: .utf8)) ?? ""
        return AWSConfigParser.parse(text).filter { $0.name != "default" }
    }

    private func gcpProfiles() -> [CloudProfile] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: GCPConfigPaths.configurationsDirURL, includingPropertiesForKeys: nil) else {
            return []
        }

        return fileURLs.compactMap { fileURL in
            let filename = fileURL.lastPathComponent
            guard filename.hasPrefix("config_") else { return nil }
            let configName = String(filename.dropFirst("config_".count))
            return GCPConfigParser.parse(contentsOf: fileURL, name: configName)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func azureProfiles() -> [CloudProfile] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: AzureConfigPaths.profilesDirURL, includingPropertiesForKeys: nil) else {
            return []
        }

        return fileURLs.compactMap { fileURL in
            guard fileURL.pathExtension == "json" else { return nil }
            return AzureConfigParser.parse(contentsOf: fileURL)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
