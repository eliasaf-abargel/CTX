import Foundation

public enum AzureConfigWriterError: LocalizedError {
    case invalid(String)
    case configExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let field):
            "Invalid \(field)"
        case .configExists(let name):
            "Azure subscription \(name) already exists"
        }
    }
}

public enum AzureConfigWriter {
    public static func writeConfig(
        _ draft: AzureProfileDraft,
        originalName: String?,
        dir: URL = AzureConfigPaths.profilesDirURL
    ) throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let subscriptionID = draft.subscriptionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let tenantID = draft.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)

        let forbidden = CharacterSet(charactersIn: "\n\r/")
        guard !name.isEmpty, name.rangeOfCharacter(from: forbidden) == nil else {
            throw AzureConfigWriterError.invalid("subscription name")
        }
        guard !subscriptionID.isEmpty, subscriptionID.rangeOfCharacter(from: .newlines) == nil else {
            throw AzureConfigWriterError.invalid("subscription ID")
        }

        let manager = FileManager.default
        try manager.createDirectory(at: dir, withIntermediateDirectories: true)

        let targetURL = dir.appendingPathComponent("\(name).json")
        let isRename = originalName != nil && originalName != name
        if originalName == nil || isRename {
            if manager.fileExists(atPath: targetURL.path) {
                throw AzureConfigWriterError.configExists(name)
            }
        }

        if let originalName, isRename {
            let oldURL = dir.appendingPathComponent("\(originalName).json")
            try? manager.removeItem(at: oldURL)
        }

        let file = AzureProfileFile(
            name: name,
            subscriptionID: subscriptionID,
            tenantID: tenantID,
            location: location
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: targetURL, options: .atomic)
    }

    public static func deleteConfig(_ name: String, dir: URL = AzureConfigPaths.profilesDirURL) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = dir.appendingPathComponent("\(name).json")
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            try manager.removeItem(at: fileURL)
        }
    }
}
