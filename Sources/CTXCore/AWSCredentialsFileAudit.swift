import Foundation

public struct AWSCredentialsFileConflict: Sendable, Equatable {
    public let profileName: String
    public let overridingKeys: [String]

    public var explanation: String {
        let keys = overridingKeys.joined(separator: ", ")
        return """
        Profile "\(profileName)" also defines \(keys) in ~/.aws/credentials. \
        That file wins over ~/.aws/config, so the login writes a session for the \
        start URL in the config while the profile resolves the one in the \
        credentials file. Move those keys back to ~/.aws/config.
        """
    }
}

/// Why a profile can fail right after a successful login.
///
/// The AWS CLI merges `~/.aws/config` and `~/.aws/credentials` into one profile,
/// and the credentials file wins on every key it also defines — verified against
/// aws-cli 2.33: a `sso_start_url` there replaces the one in the config, and
/// `aws sso login` then caches a token under a start URL the profile never reads,
/// which surfaces as "Token for <url> does not exist" on an account that just
/// signed in. Static keys are harmless by comparison; the SSO provider runs ahead
/// of them in the chain.
public enum AWSCredentialsFileAudit {
    /// Keys that belong in `~/.aws/config` and silently override it from here.
    static let configOnlyKeys = [
        "sso_start_url", "sso_region", "sso_account_id", "sso_role_name", "sso_session",
        "role_arn", "source_profile", "credential_process", "mfa_serial", "region"
    ]

    public static func conflict(for profileName: String, credentialsURL: URL = AWSConfigPaths.credentialsURL) -> AWSCredentialsFileConflict? {
        guard let text = try? String(contentsOf: credentialsURL, encoding: .utf8) else { return nil }
        return conflicts(credentialsText: text).first { $0.profileName == profileName }
    }

    public static func conflicts(credentialsText: String) -> [AWSCredentialsFileConflict] {
        var found: [AWSCredentialsFileConflict] = []
        var section = ""
        var keys: [String] = []

        func flush() {
            if !section.isEmpty, !keys.isEmpty {
                found.append(AWSCredentialsFileConflict(profileName: section, overridingKeys: keys))
            }
            keys = []
        }

        for line in credentialsText.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                flush()
                section = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard !section.isEmpty, let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            if configOnlyKeys.contains(key) {
                keys.append(key)
            }
        }
        flush()
        return found
    }
}
