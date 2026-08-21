import Foundation

public struct AWSStoredCredentialsResult: Sendable {
    public var expiresAt: Date?

    public init(expiresAt: Date?) {
        self.expiresAt = expiresAt
    }
}

public final class AWSCredentialService: Sendable {
    private let configURLProvider: @Sendable () -> URL
    private let credentialsURLProvider: @Sendable () -> URL

    public init(
        configURL: URL = AWSConfigPaths.configURL,
        credentialsURL: URL = AWSConfigPaths.credentialsURL
    ) {
        self.configURLProvider = { configURL }
        self.credentialsURLProvider = { credentialsURL }
    }

    public init(
        configURLProvider: @escaping @Sendable () -> URL,
        credentialsURLProvider: @escaping @Sendable () -> URL
    ) {
        self.configURLProvider = configURLProvider
        self.credentialsURLProvider = credentialsURLProvider
    }

    public func identity(fromCallerIdentityOutput output: String) -> String? {
        guard
            let data = output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let arn = json["Arn"] as? String,
           let identity = Self.identity(fromArn: arn),
           !identity.isEmpty {
            return identity
        }
        return json["Account"] as? String
    }

    public func clearDefaultProfile() throws {
        try AWSConfigWriter.deleteSection("default", from: configURLProvider())
        try AWSConfigWriter.deleteSection(
            "default",
            from: credentialsURLProvider(),
            createsBackup: false
        )
    }

    public func clearExportedTemporaryCredentials() throws {
        let credentialsURL = credentialsURLProvider()
        let trackedProfiles = exportedProfileNames(from: metadataURL(for: credentialsURL))
        let credentialKeys = Self.sectionKeys(
            in: (try? String(contentsOf: credentialsURL, encoding: .utf8)) ?? ""
        )
        let configKeys = Self.sectionKeys(
            in: (try? String(contentsOf: configURLProvider(), encoding: .utf8)) ?? ""
        )
        let legacyProfiles = credentialKeys.compactMap { section, keys -> String? in
            guard keys.contains("aws_session_token"),
                  keys.contains("aws_session_expiration") else {
                return nil
            }
            let configSection = section == "default" ? "default" : "profile \(section)"
            let profileKeys = configKeys[configSection] ?? []
            guard !profileKeys.isDisjoint(with: ["sso_session", "sso_start_url", "sso_account_id"]) else {
                return nil
            }
            return section
        }

        let confirmedTrackedProfiles = trackedProfiles.filter { profileName in
            guard let keys = credentialKeys[profileName] else { return false }
            return keys.isSuperset(of: [
                "aws_access_key_id",
                "aws_secret_access_key",
                "aws_session_token"
            ])
        }
        for profileName in confirmedTrackedProfiles.union(legacyProfiles) {
            try AWSConfigWriter.deleteSection(
                profileName,
                from: credentialsURL,
                createsBackup: false
            )
        }
        try? FileManager.default.removeItem(at: metadataURL(for: credentialsURL))
    }

    public func storeExportedCredentials(_ output: String, profileName: String, isActiveProfile: Bool) throws -> AWSStoredCredentialsResult {
        let exported = try Self.parseExportedCredentials(output)

        try AWSConfigWriter.updateCredentials(
            profileName: profileName,
            accessKeyId: exported.accessKeyId,
            secretAccessKey: exported.secretAccessKey,
            sessionToken: exported.sessionToken,
            expiration: exported.expiration,
            to: credentialsURLProvider()
        )

        if isActiveProfile {
            try AWSConfigWriter.copyConfig(from: profileName, to: "default", fileURL: configURLProvider())
            try AWSConfigWriter.updateCredentials(
                profileName: "default",
                accessKeyId: exported.accessKeyId,
                secretAccessKey: exported.secretAccessKey,
                sessionToken: exported.sessionToken,
                expiration: exported.expiration,
                to: credentialsURLProvider()
            )
        }
        try recordExportedProfiles(
            [profileName] + (isActiveProfile ? ["default"] : []),
            credentialsURL: credentialsURLProvider()
        )

        return AWSStoredCredentialsResult(expiresAt: Self.parseDate(exported.expiration))
    }

    public static func parseExportedCredentials(_ output: String) throws -> (accessKeyId: String, secretAccessKey: String, sessionToken: String, expiration: String?) {
        guard
            let data = output.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessKeyId = json["AccessKeyId"] as? String,
            let secretAccessKey = json["SecretAccessKey"] as? String,
            let sessionToken = json["SessionToken"] as? String
        else {
            throw AWSConfigWriterError.invalid("STS credentials JSON")
        }

        return (
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            expiration: json["Expiration"] as? String
        )
    }

    private static func identity(fromArn arn: String) -> String? {
        guard let last = arn.split(separator: "/").last else { return nil }
        let value = String(last).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func metadataURL(for credentialsURL: URL) -> URL {
        credentialsURL.appendingPathExtension("ctx-exported-profiles.json")
    }

    private func exportedProfileNames(from url: URL) -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(names)
    }

    private func recordExportedProfiles(_ profileNames: [String], credentialsURL: URL) throws {
        let url = metadataURL(for: credentialsURL)
        var names = exportedProfileNames(from: url)
        names.formUnion(profileNames)
        let data = try JSONEncoder().encode(names.sorted())
        try data.write(to: url, options: .atomic)
    }

    private static func sectionKeys(in text: String) -> [String: Set<String>] {
        var sections: [String: Set<String>] = [:]
        var currentSection: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                continue
            }
            guard let currentSection,
                  let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            sections[currentSection, default: []].insert(key)
        }
        return sections
    }
}
