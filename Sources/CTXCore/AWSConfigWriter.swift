import Foundation

public enum AWSConfigWriterError: LocalizedError {
    case invalid(String)
    case profileExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let field):
            "Invalid \(field)"
        case .profileExists(let name):
            "AWS profile \(name) already exists"
        }
    }
}

public enum AWSConfigWriter {
    public static func appendProfile(_ draft: AWSProfileDraft, to url: URL = AWSConfigPaths.configURL) throws {
        try writeProfile(draft, originalName: nil, to: url)
    }

    public static func updateProfile(
        originalName: String,
        draft: AWSProfileDraft,
        to url: URL = AWSConfigPaths.configURL
    ) throws {
        try writeProfile(draft, originalName: originalName, to: url)
    }

    public static func deleteProfile(_ name: String, from url: URL = AWSConfigPaths.configURL) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        guard containsSection("profile \(name)", in: existing) else {
            return
        }

        try backup(url)
        let text = removingProfileSections(from: existing, originalName: name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeProfile(_ draft: AWSProfileDraft, originalName: String?, to url: URL) throws {
        let draft = try normalized(draft)
        let originalName = originalName?.trimmingCharacters(in: .whitespacesAndNewlines)

        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if originalName != draft.name, containsSection("profile \(draft.name)", in: existing) {
            throw AWSConfigWriterError.profileExists(draft.name)
        }

        if !existing.isEmpty {
            try backup(url)
        }

        let text = removingProfileSections(from: existing, originalName: originalName)
        let stanza = """

        [sso-session \(draft.name)]
        sso_start_url = \(draft.ssoStartURL)
        sso_region = \(draft.ssoRegion)
        sso_registration_scopes = sso:account:access

        [profile \(draft.name)]
        sso_session = \(draft.name)
        sso_account_id = \(draft.accountID)
        sso_role_name = \(draft.roleName)
        region = \(draft.defaultRegion)
        output = json
        """

        try (text.trimmingCharacters(in: .whitespacesAndNewlines) + stanza + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func normalized(_ draft: AWSProfileDraft) throws -> AWSProfileDraft {
        var draft = draft
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.ssoStartURL = draft.ssoStartURL.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.ssoRegion = draft.ssoRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.accountID = draft.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.roleName = draft.roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.defaultRegion = draft.defaultRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(draft)
        return draft
    }

    private static func validate(_ draft: AWSProfileDraft) throws {
        let fields = [
            ("profile name", draft.name),
            ("SSO start URL", draft.ssoStartURL),
            ("SSO region", draft.ssoRegion),
            ("account ID", draft.accountID),
            ("role name", draft.roleName),
            ("default region", draft.defaultRegion)
        ]

        for (label, value) in fields where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AWSConfigWriterError.invalid(label)
        }

        let forbidden = CharacterSet(charactersIn: "\n\r[]=")
        guard draft.name.rangeOfCharacter(from: forbidden) == nil else {
            throw AWSConfigWriterError.invalid("profile name")
        }

        for (label, value) in fields where value.rangeOfCharacter(from: .newlines) != nil {
            throw AWSConfigWriterError.invalid(label)
        }

        guard URL(string: draft.ssoStartURL)?.scheme?.hasPrefix("http") == true else {
            throw AWSConfigWriterError.invalid("SSO start URL")
        }

        guard draft.accountID.allSatisfy(\.isNumber), draft.accountID.count == 12 else {
            throw AWSConfigWriterError.invalid("account ID")
        }
    }

    private static func backup(_ url: URL) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("config.ctx-backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))")
        try FileManager.default.copyItem(at: url, to: backupURL)
    }

    private static func containsSection(_ section: String, in text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces) == "[\(section)]"
        }
    }

    private static func removingProfileSections(from text: String, originalName: String?) -> String {
        guard let originalName, !originalName.isEmpty else {
            return text
        }

        let removed = Set(["profile \(originalName)", "sso-session \(originalName)"])
        var output: [String] = []
        var skipping = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let section = String(trimmed.dropFirst().dropLast())
                skipping = removed.contains(section)
            }
            if !skipping {
                output.append(String(line))
            }
        }

        return output.joined(separator: "\n")
    }

    public static func updateCredentials(
        profileName: String,
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String,
        to url: URL = AWSConfigPaths.credentialsURL
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        
        let text = removingCredentialsSection(from: existing, profileName: profileName)
        let stanza = """

        [\(profileName)]
        aws_access_key_id = \(accessKeyId)
        aws_secret_access_key = \(secretAccessKey)
        aws_session_token = \(sessionToken)
        """
        
        try (text.trimmingCharacters(in: .whitespacesAndNewlines) + stanza + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func removingCredentialsSection(from text: String, profileName: String) -> String {
        let removed = "[\(profileName)]"
        var output: [String] = []
        var skipping = false
        
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                skipping = (trimmed == removed)
            }
            if !skipping {
                output.append(String(line))
            }
        }
        
        return output.joined(separator: "\n")
    }
}
