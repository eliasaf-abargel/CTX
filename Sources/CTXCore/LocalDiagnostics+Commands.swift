import Foundation

extension LocalDiagnostics {
    public func recordCommand(arguments: [String], result: CommandResult, durationMs: Int) {
        let tool = arguments.first ?? ""
        let verb = arguments.dropFirst().first ?? ""
        let safeTool = ["aws", "sdm", "gcloud", "az", "tsh", "kubectl"].contains(tool) ? tool : "other"
        let safeVerb = ["get", "connect", "disconnect", "login", "logout", "status", "sso", "sts", "auth", "config", "configure", "account", "kube"].contains(verb) ? verb : "other"
        try? record(step: "cli_\(safeTool)_\(safeVerb)", durationMs: durationMs,
                    outcome: result.exitCode == 0 ? "success" : "error", exitCode: result.exitCode,
                    category: Self.commandCategory(result))
    }

    public static func commandCategory(_ result: CommandResult) -> String {
        if result.exitCode == 0 { return "success" }
        if result.exitCode == 127 { return "cli_missing" }
        if result.exitCode == 130 { return "cancelled" }
        let text = result.output.lowercased()
        if text.contains("timed out") || text.contains("timeout") { return "timeout" }
        if text.contains("connection refused") || text.contains("daemon is not running") { return "local_service_unavailable" }
        if text.contains("not connected") || text.contains("disconnected") { return "not_connected" }
        if text.contains("not logged in") || text.contains("authentication") || text.contains("login required") || text.contains("missing password") || text.contains("missing token") || text.contains("expired") { return "authentication_required" }
        if text.contains("denied") || text.contains("forbidden") { return "access_denied" }
        return "command_failed"
    }
}
