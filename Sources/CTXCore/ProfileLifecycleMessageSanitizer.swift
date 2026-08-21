import Foundation

extension ProfileStore {
    internal func sanitizedLifecycleMessage(_ message: String) -> String {
        let limited = String(message.prefix(1_500))
        let redactedAssignments = limited.replacingOccurrences(
            of: #"(?i)(["']?(?:secretaccesskey|accesskeyid|sessiontoken|aws_access_key_id|aws_secret_access_key|aws_session_token|token|secret|password|credential|authorization|api[_-]?key)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|Bearer\s+[A-Za-z0-9._~+/=-]+|[^\s,;}\]]+)"#,
            with: "$1[REDACTED]",
            options: .regularExpression
        )
        let redactedBearerValues = redactedAssignments.replacingOccurrences(
            of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
        return redactedBearerValues.replacingOccurrences(
            of: #"(https?://[^\s?]+)\?[^\s]+"#,
            with: "$1?[REDACTED]",
            options: .regularExpression
        )
    }
}
