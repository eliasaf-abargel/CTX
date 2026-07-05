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
        var expiries: [String: Date] = [:]
        for profile in profiles where profile.provider == .aws {
            guard !profile.ssoStartURL.isEmpty else { continue }
            if let expiry = sessionExpiry(for: profile, cacheExpiries: cache.expiryByStartURL) {
                expiries[profile.name] = expiry
            }
        }

        return AWSSessionExpirationSnapshot(
            expiryByProfileName: expiries,
            newestCacheModificationDate: cache.newestModificationDate
        )
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

    private static func parseDate(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
