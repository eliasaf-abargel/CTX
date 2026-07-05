import Foundation

public final class CloudProfilePersistenceService: Sendable {
    private let awsConfigURL: URL

    public init(awsConfigURL: URL = AWSConfigPaths.configURL) {
        self.awsConfigURL = awsConfigURL
    }

    public func addAWSProfile(_ draft: AWSProfileDraft) throws {
        try AWSConfigWriter.appendProfile(draft, to: awsConfigURL)
    }

    public func updateAWSProfile(originalName: String, draft: AWSProfileDraft) throws {
        try AWSConfigWriter.updateProfile(originalName: originalName, draft: draft, to: awsConfigURL)
    }

    public func deleteAWSProfile(_ name: String) throws {
        try AWSConfigWriter.deleteProfile(name, from: awsConfigURL)
    }

    public func addGCPProfile(_ draft: GCPProfileDraft) throws {
        try GCPConfigWriter.writeConfig(draft, originalName: nil)
    }

    public func updateGCPProfile(originalName: String, draft: GCPProfileDraft) throws {
        try GCPConfigWriter.writeConfig(draft, originalName: originalName)
    }

    public func deleteGCPProfile(_ name: String) throws {
        try GCPConfigWriter.deleteConfig(name)
    }

    public func addAzureProfile(_ draft: AzureProfileDraft) throws {
        try AzureConfigWriter.writeConfig(draft, originalName: nil)
    }

    public func updateAzureProfile(originalName: String, draft: AzureProfileDraft) throws {
        try AzureConfigWriter.writeConfig(draft, originalName: originalName)
    }

    public func deleteAzureProfile(_ name: String) throws {
        try AzureConfigWriter.deleteConfig(name)
    }
}
