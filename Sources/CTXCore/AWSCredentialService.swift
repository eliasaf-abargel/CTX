import Foundation

public struct AWSStoredCredentialsResult: Sendable {
    public var expiresAt: Date?

    public init(expiresAt: Date?) {
        self.expiresAt = expiresAt
    }
}

public final class AWSCredentialService: Sendable {
    private let configURL: URL
    private let credentialsURL: URL

    public init(
        configURL: URL = AWSConfigPaths.configURL,
        credentialsURL: URL = AWSConfigPaths.credentialsURL
    ) {
        self.configURL = configURL
        self.credentialsURL = credentialsURL
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

    public func syncDefaultProfile(from profileName: String) throws {
        try AWSConfigWriter.copyConfig(from: profileName, to: "default", fileURL: configURL)
        try AWSConfigWriter.copyCredentials(from: profileName, to: "default", fileURL: credentialsURL)
    }

    public func clearDefaultProfile() throws {
        try AWSConfigWriter.deleteSection("default", from: configURL)
        try AWSConfigWriter.deleteSection("default", from: credentialsURL)
    }

    public func storeExportedCredentials(_ output: String, profileName: String, isActiveProfile: Bool) throws -> AWSStoredCredentialsResult {
        let exported = try Self.parseExportedCredentials(output)

        try AWSConfigWriter.updateCredentials(
            profileName: profileName,
            accessKeyId: exported.accessKeyId,
            secretAccessKey: exported.secretAccessKey,
            sessionToken: exported.sessionToken,
            expiration: exported.expiration,
            to: credentialsURL
        )

        if isActiveProfile {
            try AWSConfigWriter.copyConfig(from: profileName, to: "default", fileURL: configURL)
            try AWSConfigWriter.updateCredentials(
                profileName: "default",
                accessKeyId: exported.accessKeyId,
                secretAccessKey: exported.secretAccessKey,
                sessionToken: exported.sessionToken,
                expiration: exported.expiration,
                to: credentialsURL
            )
        }

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
}
