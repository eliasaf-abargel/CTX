import Foundation

public enum AzureConfigPaths {
    /// CTX-managed directory holding one JSON file per Azure subscription profile.
    public static var profilesDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("ctx")
            .appendingPathComponent("azure")
    }

    /// The Azure CLI's own configuration directory (used for diagnostics in Settings).
    public static var azureCLIDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".azure")
    }
}

/// On-disk representation of a CTX Azure subscription profile.
struct AzureProfileFile: Codable {
    var name: String
    var subscriptionID: String
    var tenantID: String
    var location: String
}

public enum AzureConfigParser {
    public static func parse(contentsOf url: URL) -> CloudProfile? {
        guard
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(AzureProfileFile.self, from: data),
            !file.name.isEmpty
        else {
            return nil
        }

        return CloudProfile(
            provider: .azure,
            name: file.name,
            accountID: file.subscriptionID,
            roleName: file.tenantID,
            region: file.location
        )
    }
}
