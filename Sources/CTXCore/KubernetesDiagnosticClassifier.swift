import Foundation

enum KubernetesDiagnosticClassifier {
    static func status(from category: KubernetesDiagnosticCategory) -> KubernetesCheckStatus {
        switch category {
        case .success: .reachable
        case .kubectlMissing: .kubectlMissing
        case .contextNotFound: .contextNotFound
        case .unauthorized: .unauthorized
        case .forbidden: .permissionDenied
        case .timeout: .timeout
        case .authPluginFailed: .authPluginFailed
        case .awsSSOExpired: .awsSSOExpired
        case .gcpAuthExpired: .gcpAuthExpired
        case .tlsCertificate: .tlsError
        case .kubeconfig: .kubeconfigError
        case .clusterUnreachable, .localProxyUnavailable: .unreachable
        case .unknown: .unknownError
        }
    }

    static func category(from result: KubectlResult) -> KubernetesDiagnosticCategory {
        if result.timedOut { return .timeout }
        if result.exitCode == 0 { return .success }
        let message = "\(result.stderr) \(result.stdout)".lowercased()
        if message.contains("context") && (message.contains("does not exist") || message.contains("not found")) { return .contextNotFound }
        if message.contains("no context exists") { return .contextNotFound }
        if message.contains("forbidden") { return .forbidden }
        if message.contains("unauthorized") || message.contains("must be logged in") { return .unauthorized }
        if message.contains("sso") && (message.contains("expired") || message.contains("login") || message.contains("token")) { return .awsSSOExpired }
        if message.contains("gcloud") || message.contains("invalid_grant") { return .gcpAuthExpired }
        if message.contains("exec plugin") || (message.contains("executable") && message.contains("failed")) { return .authPluginFailed }
        if message.contains("certificate") || message.contains("tls") || message.contains("x509") { return .tlsCertificate }
        if message.contains("kubeconfig") || message.contains("no such file") || message.contains("permission denied") { return .kubeconfig }
        if message.contains("timeout") || message.contains("timed out") || message.contains("deadline exceeded") || message.contains("i/o timeout") { return .timeout }
        if (message.contains("127.0.0.1") || message.contains("localhost")) && (message.contains("connection refused") || message.contains("was refused")) { return .localProxyUnavailable }
        if message.contains("connection refused") || message.contains("was refused") || message.contains("no route to host") || message.contains("dial tcp") || message.contains("server api group list") { return .clusterUnreachable }
        return .unknown
    }

    static func sanitize(_ value: String) -> String {
        var text = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)(bearer\s+)[A-Za-z0-9._\-=/+]+"#,
            #"(?i)(token[=:]\s*)[A-Za-z0-9._\-=/+]+"#,
            #"(?i)(id-token[=:]\s*)[A-Za-z0-9._\-=/+]+"#,
            #"(?i)(refresh-token[=:]\s*)[A-Za-z0-9._\-=/+]+"#,
            #"(?i)(client-certificate-data[=:]\s*)[A-Za-z0-9._\-=/+]+"#,
            #"(?i)(client-key-data[=:]\s*)[A-Za-z0-9._\-=/+]+"#
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "$1[redacted]", options: .regularExpression)
        }
        return String(text.prefix(500))
    }

    static func safeKubeconfigPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard trimmed.hasPrefix(home) else { return trimmed }
        return "~" + trimmed.dropFirst(home.count)
    }
}

extension KubernetesDiagnosticCategory {
    public var presentationSummary: String {
        switch self {
        case .success: "read completed"
        case .kubectlMissing: "kubectl was not found"
        case .contextNotFound: "context was not found"
        case .clusterUnreachable: "cluster endpoint was unreachable"
        case .localProxyUnavailable: "local proxy or tunnel was unavailable"
        case .authPluginFailed: "credential plugin failed"
        case .awsSSOExpired: "AWS SSO credentials need refresh"
        case .gcpAuthExpired: "GCP credentials need refresh"
        case .unauthorized: "credentials were rejected"
        case .forbidden: "read permission was denied"
        case .timeout: "read timed out"
        case .tlsCertificate: "TLS or certificate validation failed"
        case .kubeconfig: "kubeconfig could not be used"
        case .unknown: "read failed"
        }
    }
}
