import Foundation

public enum GCPConfigWriterError: LocalizedError {
    case invalid(String)
    case configExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let field):
            "Invalid \(field)"
        case .configExists(let name):
            "GCP configuration \(name) already exists"
        }
    }
}

public enum GCPConfigWriter {
    public static func writeConfig(
        _ draft: GCPProfileDraft,
        originalName: String?,
        dir: URL = GCPConfigPaths.configurationsDirURL
    ) throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = draft.project.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = draft.account.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = draft.region.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, name.rangeOfCharacter(from: .newlines) == nil else {
            throw GCPConfigWriterError.invalid("configuration name")
        }
        guard !project.isEmpty, project.rangeOfCharacter(from: .newlines) == nil else {
            throw GCPConfigWriterError.invalid("project ID")
        }
        guard !account.isEmpty, account.rangeOfCharacter(from: .newlines) == nil else {
            throw GCPConfigWriterError.invalid("account email")
        }

        let manager = FileManager.default
        try manager.createDirectory(at: dir, withIntermediateDirectories: true)

        let targetURL = dir.appendingPathComponent("config_\(name)")

        // Check if new config name already exists (if creating or renaming)
        let isRename = originalName != nil && originalName != name
        if originalName == nil || isRename {
            if manager.fileExists(atPath: targetURL.path) {
                throw GCPConfigWriterError.configExists(name)
            }
        }

        // If it's a rename, delete the old file
        if let originalName, isRename {
            let oldURL = dir.appendingPathComponent("config_\(originalName)")
            try? manager.removeItem(at: oldURL)
        }

        // Build INI content
        var content = """
        [core]
        project = \(project)
        account = \(account)
        """

        if !region.isEmpty {
            content += """
            
            
            [compute]
            region = \(region)
            """
        }

        try (content + "\n").write(to: targetURL, atomically: true, encoding: .utf8)
    }

    public static func deleteConfig(_ name: String, dir: URL = GCPConfigPaths.configurationsDirURL) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = dir.appendingPathComponent("config_\(name)")
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            try manager.removeItem(at: fileURL)
        }
    }
}
