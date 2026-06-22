import Foundation

public enum AWSConfigPaths {
    public static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws")
            .appendingPathComponent("config")
    }

    public static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws")
            .appendingPathComponent("credentials")
    }
}

public enum AWSConfigParser {
    public static func parse(_ text: String) -> [CloudProfile] {
        var sections: [String: [String: String]] = [:]
        var current = ""

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                sections[current, default: [:]] = [:]
                continue
            }

            guard !current.isEmpty, let equals = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            sections[current, default: [:]][key] = value
        }

        return sections.compactMap { section, values in
            let name: String
            if section == "default" {
                name = "default"
            } else if section.hasPrefix("profile ") {
                name = String(section.dropFirst("profile ".count))
            } else {
                return nil
            }

            let session = values["sso_session"].flatMap { sections["sso-session \($0)"] } ?? [:]

            return CloudProfile(
                provider: .aws,
                name: name,
                accountID: values["sso_account_id"] ?? "",
                roleName: values["sso_role_name"] ?? "",
                region: values["region"] ?? values["sso_region"] ?? session["sso_region"] ?? "",
                ssoStartURL: values["sso_start_url"] ?? session["sso_start_url"] ?? "",
                ssoRegion: values["sso_region"] ?? session["sso_region"] ?? ""
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
