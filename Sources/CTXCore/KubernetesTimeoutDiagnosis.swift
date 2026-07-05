import Foundation

/// Maps an already-classified kubectl outcome onto the four buckets that
/// actually matter when deciding what to do about a slow/failed read: is this
/// CTX's own timeout being too tight, a kubectl/auth-plugin problem, the
/// cluster/API itself, or RBAC? CTX cannot see inside the `kubectl` process
/// (an exec-credential plugin runs as *its* child, not CTX's), so a plain
/// `.timeout` genuinely cannot be split into "CTX's timeout was too low" vs.
/// "the API itself is just slow" by external timing alone — both candidates
/// are returned together rather than one being guessed.
public enum KubernetesTimeoutBucket: String, Equatable, Sendable {
    case ctxScheduling = "CTX scheduling (timeout may be too low for this cluster)"
    case kubectlAuth = "kubectl / auth plugin"
    case clusterAPI = "cluster / API"
    case rbac = "RBAC"
    case success = "success"

    public static func candidates(
        category: KubernetesDiagnosticCategory,
        hasExecPlugin: Bool
    ) -> [KubernetesTimeoutBucket] {
        switch category {
        case .success:
            return [.success]
        case .forbidden, .unauthorized:
            return [.rbac]
        case .authPluginFailed, .awsSSOExpired, .gcpAuthExpired, .kubeconfig:
            return [.kubectlAuth]
        case .clusterUnreachable, .localProxyUnavailable, .tlsCertificate:
            return [.clusterAPI]
        case .timeout:
            return hasExecPlugin ? [.ctxScheduling, .kubectlAuth, .clusterAPI] : [.ctxScheduling, .clusterAPI]
        case .kubectlMissing, .contextNotFound, .unknown:
            return [.clusterAPI]
        }
    }
}
