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

        try ConfigBackup.snapshot(url)
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
            try ConfigBackup.snapshot(url)
        }

        let text = removingProfileSections(from: existing, originalName: originalName)

        // One sso-session per Identity Center portal, not per profile. A second session
        // for the same start URL registers a second OIDC client, and logging in through
        // one invalidates the other's token - so profiles on the same portal could not
        // be used at the same time.
        let sessionName = existingSSOSession(
            matchingStartURL: draft.ssoStartURL,
            region: draft.ssoRegion,
            in: text
        ) ?? draft.name

        var blocks: [String] = []
        if sessionName == draft.name {
            blocks.append("""
            [sso-session \(draft.name)]
            sso_start_url = \(draft.ssoStartURL)
            sso_region = \(draft.ssoRegion)
            sso_registration_scopes = sso:account:access
            """)
        }
        blocks.append("""
        [profile \(draft.name)]
        sso_session = \(sessionName)
        sso_account_id = \(draft.accountID)
        sso_role_name = \(draft.roleName)
        region = \(draft.defaultRegion)
        output = json
        """)
        let stanza = "\n" + blocks.joined(separator: "\n\n")

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

    private static func containsSection(_ section: String, in text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces) == "[\(section)]"
        }
    }

    /// One portal's duplicate sessions, collapsed onto the first one seen.
    public struct SSOSessionConsolidation: Equatable, Sendable {
        public let canonicalSession: String
        public let mergedSessions: [String]
        public let repointedProfiles: [String]

        public init(canonicalSession: String, mergedSessions: [String], repointedProfiles: [String]) {
            self.canonicalSession = canonicalSession
            self.mergedSessions = mergedSessions
            self.repointedProfiles = repointedProfiles
        }
    }

    /// Collapses `[sso-session …]` blocks that describe the same portal onto a single
    /// session, repointing the affected profiles.
    ///
    /// Configs written before sessions were shared hold one session per profile. Each
    /// registers its own OIDC client against the same Identity Center, so signing in to
    /// one profile invalidates the cached token of its siblings. Returns an empty array
    /// and leaves the file untouched when there is nothing to merge.
    @discardableResult
    public static func consolidateSSOSessions(
        in url: URL = AWSConfigPaths.configURL
    ) throws -> [SSOSessionConsolidation] {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !existing.isEmpty else { return [] }

        let parsed = blocks(in: existing)

        // Portal identity is the start URL plus its region, in first-seen order.
        var order: [String] = []
        var sessionsByPortal: [String: [String]] = [:]
        for block in parsed {
            guard let header = block.header,
                  let name = sectionValue(header, prefix: "sso-session ")
            else { continue }
            var keys: [String: String] = [:]
            for line in block.lines.dropFirst() {
                if let (key, value) = INIDocument.keyValue(ofLine: line) {
                    keys[key] = value
                }
            }
            guard let start = keys["sso_start_url"] else { continue }
            let portal = "\(start)\u{1}\(keys["sso_region"] ?? "")"
            if sessionsByPortal[portal] == nil { order.append(portal) }
            sessionsByPortal[portal, default: []].append(name)
        }

        var canonicalFor: [String: String] = [:]
        var merged: [(canonical: String, dropped: [String])] = []
        for portal in order {
            let names = sessionsByPortal[portal] ?? []
            guard names.count > 1, let canonical = names.first else { continue }
            let dropped = Array(names.dropFirst())
            for name in dropped { canonicalFor[name] = canonical }
            merged.append((canonical, dropped))
        }
        guard !merged.isEmpty else { return [] }

        var repointed: [String: [String]] = [:]
        var rebuilt: [String] = []
        for block in parsed {
            if let header = block.header,
               let name = sectionValue(header, prefix: "sso-session "),
               canonicalFor[name] != nil {
                continue
            }
            guard let header = block.header,
                  let profile = profileName(from: header)
            else {
                rebuilt.append(contentsOf: block.lines)
                continue
            }
            rebuilt.append(block.lines[0])
            for line in block.lines.dropFirst() {
                if let (key, value) = INIDocument.keyValue(ofLine: line),
                   key == "sso_session",
                   let canonical = canonicalFor[value] {
                    rebuilt.append("sso_session = \(canonical)")
                    repointed[canonical, default: []].append(profile)
                } else {
                    rebuilt.append(line)
                }
            }
        }

        try ConfigBackup.snapshot(url)
        let text = rebuilt.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)

        return merged.map {
            SSOSessionConsolidation(
                canonicalSession: $0.canonical,
                mergedSessions: $0.dropped,
                repointedProfiles: repointed[$0.canonical] ?? []
            )
        }
    }

    private struct ConfigBlock {
        var header: String?
        var lines: [String]
    }

    private static func blocks(in text: String) -> [ConfigBlock] {
        var result: [ConfigBlock] = []
        var current = ConfigBlock(header: nil, lines: [])

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let section = INIDocument.sectionName(ofLine: String(line)) {
                result.append(current)
                current = ConfigBlock(header: section, lines: [String(line)])
            } else {
                current.lines.append(String(line))
            }
        }
        result.append(current)
        return result
    }

    /// Name of an existing `[sso-session …]` describing the same portal, if there is one.
    private static func existingSSOSession(
        matchingStartURL startURL: String,
        region: String,
        in text: String
    ) -> String? {
        var current: String?
        var keys: [String: String] = [:]

        func matched() -> String? {
            guard let current,
                  keys["sso_start_url"] == startURL,
                  keys["sso_region"] == region
            else { return nil }
            return current
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let section = INIDocument.sectionName(ofLine: String(line)) {
                if let name = matched() { return name }
                current = sectionValue(section, prefix: "sso-session ")
                keys = [:]
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard current != nil, let (key, value) = INIDocument.keyValue(ofLine: trimmed) else { continue }
            keys[key] = value
        }
        return matched()
    }

    /// Session names still referenced by profiles other than `excludingProfile`.
    private static func ssoSessionsInUse(in text: String, excludingProfile: String) -> Set<String> {
        var used: Set<String> = []
        var currentProfile: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let section = INIDocument.sectionName(ofLine: String(line)) {
                currentProfile = profileName(from: section)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let profile = currentProfile, profile != excludingProfile,
                  let (key, value) = INIDocument.keyValue(ofLine: trimmed), key == "sso_session"
            else { continue }
            used.insert(value)
        }
        return used
    }

    private static func sectionValue(_ section: String, prefix: String) -> String? {
        guard section.hasPrefix(prefix) else { return nil }
        return String(section.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Profile name for a section header. The default profile is spelled `[default]`,
    /// not `[profile default]`; missing it leaves it pointing at a deleted session, and
    /// the CLI validates the default profile even when another one is requested.
    private static func profileName(from header: String) -> String? {
        header == "default" ? "default" : sectionValue(header, prefix: "profile ")
    }

    private static func removingProfileSections(from text: String, originalName: String?) -> String {
        guard let originalName, !originalName.isEmpty else {
            return text
        }

        var removed: Set<String> = ["profile \(originalName)"]
        // Drop the matching sso-session only when no sibling profile still points at it,
        // otherwise editing one profile tears the session out from under the others.
        if !ssoSessionsInUse(in: text, excludingProfile: originalName).contains(originalName) {
            removed.insert("sso-session \(originalName)")
        }
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
        expiration: String? = nil,
        to url: URL = AWSConfigPaths.credentialsURL
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        
        let text = removingCredentialsSection(from: existing, profileName: profileName)
        var stanza = """

        [\(profileName)]
        aws_access_key_id = \(accessKeyId)
        aws_secret_access_key = \(secretAccessKey)
        aws_session_token = \(sessionToken)
        """
        if let expiration {
            stanza += "\n        aws_session_expiration = \(expiration)"
        }
        
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

    public static func deleteSection(
        _ sectionName: String,
        from url: URL,
        createsBackup: Bool = true
    ) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let sectionHeader = "[\(sectionName)]"
        
        var output: [String] = []
        var skipping = false
        var found = false
        
        for line in existing.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                skipping = (trimmed == sectionHeader)
                if skipping {
                    found = true
                }
            }
            if !skipping {
                output.append(String(line))
            }
        }
        
        if found {
            if createsBackup {
                try ConfigBackup.snapshot(url)
            }
            let text = output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

}
