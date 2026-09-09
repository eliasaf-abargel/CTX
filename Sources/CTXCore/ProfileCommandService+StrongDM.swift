import Foundation

extension ProfileCommandService {
    internal func loginStrongDM(_ profile: CloudProfile, email: String?, onOutput: (@Sendable (String) -> Void)?) async -> CommandResult {
        let connected = await runLogin(["sdm", "connect", profile.name], onOutput: onOutput)
        guard connected.exitCode != 0, !Task.isCancelled else { return connected }
        let status = await run(["sdm", "status"])
        // A working session plus a resource failure is not a reason to repeat SSO.
        guard status.exitCode != 0 else { return connected }
        if ["local_service_unavailable", "cli_missing"].contains(LocalDiagnostics.commandCategory(status)) {
            return status
        }
        guard !Task.isCancelled else { return CommandResult(exitCode: 130, output: "Cancelled") }
        var args = ["sdm", "login"]
        if let email, !email.isEmpty { args += ["--email", email] }
        let authenticated = await runLogin(args, onOutput: onOutput)
        guard authenticated.exitCode == 0, !Task.isCancelled else { return authenticated }
        // A printed SSO URL is presentation data, not completion of resource connection.
        return await runLogin(["sdm", "connect", profile.name], onOutput: onOutput)
    }

    internal func disconnectStrongDM(_ profile: CloudProfile) async -> CommandResult {
        let result = await run(["sdm", "disconnect", profile.name])
        guard result.exitCode != 0, !Task.isCancelled else { return result }
        let status = await run(["sdm", "status"])
        if status.exitCode == 0, Self.strongDMConnectionState(in: status.output, resource: profile.name) == false {
            return CommandResult(exitCode: 0, output: "Resource is already disconnected")
        }
        return result
    }

    /// CLI tables separate columns with two or more spaces. Exact names and exact
    /// status values avoid matching sibling resources or "not connected" as connected.
    public static func strongDMConnectionState(in text: String, resource: String) -> Bool? {
        for line in text.components(separatedBy: .newlines) {
            let columns = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\s{2,}"#, with: "\t", options: .regularExpression)
                .components(separatedBy: "\t")
            guard columns.count >= 2, columns[0] == resource else { continue }
            switch columns[1].lowercased() {
            case "connected": return true
            case "not connected", "disconnected": return false
            default: return nil
            }
        }
        return nil
    }
}
