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

        // A rename carries the old file's contents to the new name, so read from
        // whichever file currently holds them.
        let oldURL = originalName.map { dir.appendingPathComponent("\($0).json") }
        let sourceURL = isRename ? (oldURL ?? targetURL) : targetURL

        try ConfigBackup.snapshot(sourceURL)
        if let oldURL, isRename {
            try? manager.removeItem(at: oldURL)
        }

        // Merge into the existing object instead of re-encoding the four fields below:
        // a profile written by the Azure CLI carries keys this form never shows, and
        // re-encoding would drop them.
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: sourceURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        object["name"] = name
        object["subscriptionID"] = subscriptionID
        object["tenantID"] = tenantID
        object["location"] = location

        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: targetURL, options: .atomic)
    }

    public static func deleteConfig(_ name: String, dir: URL = AzureConfigPaths.profilesDirURL) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = dir.appendingPathComponent("\(name).json")
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            try ConfigBackup.snapshot(fileURL)
            try manager.removeItem(at: fileURL)
        }
    }
}
