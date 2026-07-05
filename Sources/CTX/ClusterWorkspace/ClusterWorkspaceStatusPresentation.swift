import CTXCore
import SwiftUI

extension KubernetesCheckStatus {
    var shortLabel: String {
        switch self {
        case .notChecked: "Not checked"
        case .reachable: "Reachable"
        case .unreachable: "Unreachable"
        case .contextNotFound: "Context missing"
        case .unauthorized: "Unauthorized"
        case .kubectlMissing: "kubectl missing"
        case .timeout: "Timeout"
        case .permissionDenied: "Limited"
        case .authPluginFailed: "Auth plugin"
        case .awsSSOExpired: "AWS SSO"
        case .gcpAuthExpired: "GCP auth"
        case .tlsError: "TLS issue"
        case .kubeconfigError: "Config issue"
        case .unknownError: "Unknown error"
        }
    }

    var cardValue: String {
        switch self {
        case .notChecked: "Pending"
        case .reachable: "Reachable"
        case .unreachable: "Down"
        case .contextNotFound: "Missing"
        case .unauthorized: "Unauthorized"
        case .kubectlMissing: "Missing"
        case .timeout: "Timeout"
        case .permissionDenied: "Limited"
        case .authPluginFailed, .awsSSOExpired, .gcpAuthExpired: "Auth"
        case .tlsError: "TLS"
        case .kubeconfigError: "Config"
        case .unknownError: "Error"
        }
    }

    var cardSubtitle: String {
        switch self {
        case .notChecked: "Not checked yet"
        case .reachable: "Inspection"
        case .unreachable: "Check tunnel"
        case .contextNotFound: "Context not found"
        case .unauthorized: "Login required"
        case .kubectlMissing: "kubectl not found"
        case .timeout: "Try again"
        case .permissionDenied: "Permission denied"
        case .authPluginFailed: "Plugin failed"
        case .awsSSOExpired: "Check SSO"
        case .gcpAuthExpired: "Run gcloud auth"
        case .tlsError: "Check certificate"
        case .kubeconfigError: "Check kubeconfig"
        case .unknownError: "Refresh failed"
        }
    }

    var tint: Color {
        switch self {
        case .reachable: .green
        case .notChecked: .secondary
        case .permissionDenied, .timeout, .authPluginFailed, .awsSSOExpired, .gcpAuthExpired, .tlsError, .kubeconfigError: .orange
        case .unreachable, .contextNotFound, .unauthorized, .kubectlMissing, .unknownError: .red
        }
    }
}

extension KubernetesDiagnosticCategory {
    var presentation: (title: String, message: String, systemImage: String) {
        switch self {
        case .kubectlMissing:
            ("kubectl missing", "Install kubectl or add it to PATH.", "terminal")
        case .contextNotFound:
            ("Context not found", "Check the selected kubeconfig and context name.", "questionmark.folder")
        case .localProxyUnavailable:
            ("Local proxy refused", "Start the local tunnel, proxy, VPN, or access tool for this context.", "point.topleft.down.curvedto.point.bottomright.up")
        case .clusterUnreachable:
            ("Cluster unreachable", "Check network access, VPN, or cluster endpoint.", "wifi.exclamationmark")
        case .awsSSOExpired:
            ("AWS SSO expired", "Refresh AWS SSO credentials for this context.", "person.badge.key")
        case .gcpAuthExpired:
            ("GCP auth required", "Refresh gcloud credentials for this context.", "person.badge.key")
        case .authPluginFailed:
            ("Auth plugin failed", "Check the kubeconfig exec credential plugin.", "puzzlepiece.extension")
        case .unauthorized:
            ("Unauthorized", "Refresh credentials for this context.", "person.crop.circle.badge.exclamationmark")
        case .forbidden:
            ("Access denied", "Your identity lacks permission for this read.", "lock.shield")
        case .timeout:
            ("Connection timed out", "The API did not respond in time.", "clock.badge.exclamationmark")
        case .tlsCertificate:
            ("TLS issue", "Check the cluster certificate or endpoint.", "checkmark.shield")
        case .kubeconfig:
            ("Kubeconfig issue", "Check kubeconfig path and file permissions.", "doc.badge.gearshape")
        case .unknown:
            ("Unable to refresh", "The inspection check failed.", "exclamationmark.triangle")
        case .success:
            ("Reachable", "Inspection checks completed.", "checkmark.circle")
        }
    }

    var tint: Color {
        switch self {
        case .success: .green
        case .forbidden, .timeout, .authPluginFailed, .awsSSOExpired, .gcpAuthExpired, .tlsCertificate, .kubeconfig: .orange
        default: .red
        }
    }
}
