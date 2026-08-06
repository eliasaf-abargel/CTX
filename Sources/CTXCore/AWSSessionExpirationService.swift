import Foundation

public struct AWSSessionExpirationSnapshot: Sendable {
    public var expiryByProfileName: [String: Date]
    public var newestCacheModificationDate: Date

    public init(expiryByProfileName: [String: Date], newestCacheModificationDate: Date) {
        self.expiryByProfileName = expiryByProfileName
        self.newestCacheModificationDate = newestCacheModificationDate
    }
}

public final class AWSSessionExpirationService: Sendable {
    private let credentialsURL: URL
    private let ssoCacheURL: URL

    public init(
        credentialsURL: URL = AWSConfigPaths.credentialsURL,
        ssoCacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws")
            .appendingPathComponent("sso")
            .appendingPathComponent("cache")
    ) {
        self.credentialsURL = credentialsURL
        self.ssoCacheURL = ssoCacheURL
    }

    public func snapshot(for profiles: [CloudProfile]) -> AWSSessionExpirationSnapshot? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: ssoCacheURL, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }

        let cache = cacheExpiries(from: files)
        // `~/.aws/credentials` is read and parsed exactly once here. It used to be
        // re-read from disk inside the loop — once per AWS profile — so a machine
        // with ten profiles did ten full reads and ten full parses of the same file
        // on every pass, on the main actor.
        let credentialsText = (try? String(contentsOf: credentialsURL, encoding: .utf8)) ?? ""
        let credentialExpiries = Self.credentialExpiries(credentialsText: credentialsText)

        var expiries: [String: Date] = [:]
        for profile in profiles where profile.provider == .aws {
            if let expiry = credentialExpiries[profile.name] {
                expiries[profile.name] = expiry
                continue
            }
            guard !profile.ssoStartURL.isEmpty else { continue }
            let normalizedStartURL = profile.ssoStartURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let expiry = cache.expiryByStartURL[normalizedStartURL] {
                expiries[profile.name] = expiry
            }
        }

        return AWSSessionExpirationSnapshot(
            expiryByProfileName: expiries,
            newestCacheModificationDate: cache.newestModificationDate
        )
    }

    /// Every `aws_session_expiration` in the credentials file, from one parse.
    public static func credentialExpiries(credentialsText: String) -> [String: Date] {
        var expiries: [String: Date] = [:]
        var section = ""
        for line in credentialsText.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast())
                continue
            }
            guard !section.isEmpty, trimmed.hasPrefix("aws_session_expiration") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let date = parseDate(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            expiries[section] = date
        }
        return expiries
    }

    public func sessionExpiry(for profile: CloudProfile) -> Date? {
        guard profile.provider == .aws else { return nil }
        if let expiry = credentialsExpiry(for: profile.name) {
            return expiry
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: ssoCacheURL, includingPropertiesForKeys: nil) else {
            return nil
        }
        let cache = cacheExpiries(from: files)
        return sessionExpiry(for: profile, cacheExpiries: cache.expiryByStartURL)
    }

    public func credentialsExpiry(for profileName: String) -> Date? {
        guard let text = try? String(contentsOf: credentialsURL, encoding: .utf8) else { return nil }
        return Self.credentialsExpiry(for: profileName, credentialsText: text)
    }

    public static func credentialsExpiry(for profileName: String, credentialsText: String) -> Date? {
        var inSection = false
        for line in credentialsText.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[\(profileName)]" { inSection = true; continue }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { inSection = false; continue }
            guard inSection, trimmed.hasPrefix("aws_session_expiration") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return parseDate(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func sessionExpiry(for profile: CloudProfile, cacheExpiries: [String: Date]) -> Date? {
        if let expiry = credentialsExpiry(for: profile.name) {
            return expiry
        }
        let normalizedStartURL = profile.ssoStartURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cacheExpiries[normalizedStartURL]
    }

    private func cacheExpiries(from files: [URL]) -> (expiryByStartURL: [String: Date], newestModificationDate: Date) {
        var expiryByStartURL: [String: Date] = [:]
        var newestModificationDate = Date.distantPast

        for fileURL in files where fileURL.pathExtension == "json" {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = resourceValues.contentModificationDate,
               modDate > newestModificationDate {
                newestModificationDate = modDate
            }

            guard
                let data = try? Data(contentsOf: fileURL),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let startURL = json["startUrl"] as? String,
                let expiresAtString = json["expiresAt"] as? String,
                let expiresAt = Self.parseDate(expiresAtString)
            else {
                continue
            }

            let normalizedStartURL = startURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if expiresAt > (expiryByStartURL[normalizedStartURL] ?? .distantPast) {
                expiryByStartURL[normalizedStartURL] = expiresAt
            }
        }

        return (expiryByStartURL, newestModificationDate)
    }

    /// Held once rather than constructed per call. `ISO8601DateFormatter` is one of
    /// the more expensive objects in Foundation to create, and this used to build
    /// two of them for every timestamp in the SSO cache and the credentials file.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter = ISO8601DateFormatter()

    private static func parseDate(_ value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }
}
