import Foundation

/// Where CTX looks for a kubeconfig when nothing else points somewhere specific.
///
/// Previously lived alongside `KubeConfigParser`, an entirely separate parser that
/// nothing referenced — `KubeConfigDiscoveryService` does its own parsing. The parser
/// went; only the paths were ever used.
public enum KubeConfigPaths {
    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kube")
            .appendingPathComponent("config")
    }

    public static var configURL: URL {
        if let path = UserDefaults.standard.string(forKey: CTXDefaultsKey.kubeconfigPath), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return defaultConfigURL
    }
}
