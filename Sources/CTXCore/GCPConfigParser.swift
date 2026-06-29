import Foundation

public enum GCPConfigPaths {
    private static var baseDirURL: URL {
        if let path = UserDefaults.standard.string(forKey: "customGCPConfigDirPath"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("gcloud")
    }

    public static var activeConfigURL: URL {
        baseDirURL.appendingPathComponent("active_config")
    }

    public static var configurationsDirURL: URL {
        baseDirURL.appendingPathComponent("configurations")
    }
}

public enum GCPConfigParser {
    public static func parse(contentsOf url: URL, name: String) -> CloudProfile? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var sections: [String: [String: String]] = [:]
        var currentSection = ""

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                sections[currentSection, default: [:]] = [:]
                continue
            }

            guard !currentSection.isEmpty, let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            sections[currentSection, default: [:]][key] = value
        }

        let coreSection = sections["core"] ?? [:]
        let computeSection = sections["compute"] ?? [:]

        let project = coreSection["project"] ?? ""
        let account = coreSection["account"] ?? ""
        let region = computeSection["region"] ?? ""

        return CloudProfile(
            provider: .gcp,
            name: name,
            accountID: project,
            roleName: account,
            region: region
        )
    }

    public static func parseActiveConfig() -> String {
        let url = GCPConfigPaths.activeConfigURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
