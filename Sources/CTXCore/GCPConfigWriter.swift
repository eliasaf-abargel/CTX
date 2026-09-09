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

        // A rename carries the old file's contents to the new name, so read from
        // whichever file currently holds them.
        let oldURL = originalName.map { dir.appendingPathComponent("config_\($0)") }
        let sourceURL = isRename ? (oldURL ?? targetURL) : targetURL

        try ConfigBackup.snapshot(sourceURL)
        if let oldURL, isRename {
            try? manager.removeItem(at: oldURL)
        }

        // Edit in place rather than rebuilding from the fields below: a gcloud
        // configuration also carries compute zones, container clusters and run regions
        // that this form never shows, and rebuilding would drop every one of them.
        var document = INIDocument(text: (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? "")
        document.set("project", to: project, in: "core")
        document.set("account", to: account, in: "core")
        // An empty region means "not specified", never "erase the one already there".
        if !region.isEmpty {
            document.set("region", to: region, in: "compute")
        }

        let content = document.rendered()
        try (content.hasSuffix("\n") ? content : content + "\n")
            .write(to: targetURL, atomically: true, encoding: .utf8)
    }

    public static func deleteConfig(_ name: String, dir: URL = GCPConfigPaths.configurationsDirURL) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = dir.appendingPathComponent("config_\(name)")
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            try ConfigBackup.snapshot(fileURL)
            try manager.removeItem(at: fileURL)
        }
    }
}
