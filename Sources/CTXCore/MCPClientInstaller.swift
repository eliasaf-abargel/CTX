import Foundation

/// An AI client CTX knows how to wire itself into, and where that client
/// keeps its own MCP server config.
public enum MCPClientKind: String, CaseIterable, Sendable {
    case claudeDesktop
    case cursor

    public var displayName: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .cursor: "Cursor"
        }
    }

    public var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeDesktop:
            return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor:
            return home.appendingPathComponent(".cursor/mcp.json")
        }
    }
}

public enum MCPClientInstallError: LocalizedError, Equatable {
    case corruptExistingConfig(path: String)

    public var errorDescription: String? {
        switch self {
        case .corruptExistingConfig(let path):
            "\(path) doesn't parse as JSON. Fix or remove it, then try again — CTX won't overwrite a config file it can't safely merge into."
        }
    }
}

/// Wires CTX into an MCP client's own config file — the same `"ctx"` entry
/// the Settings screen already shows as copyable JSON, written directly so
/// connecting a client doesn't require opening a second app and pasting by
/// hand.
public enum MCPClientInstaller {
    public static func serverEntry(binaryPath: String) -> [String: Any] {
        ["command": binaryPath, "args": ["--mcp"]]
    }

    /// Whether this client's config already has a `"ctx"` entry — regardless
    /// of whether its path matches the current binary, so a stale entry from
    /// an earlier install still reads as "installed" rather than prompting a
    /// second, redundant install.
    public static func isInstalled(for client: MCPClientKind) -> Bool {
        isInstalled(at: client.configURL)
    }

    public static func isInstalled(at url: URL) -> Bool {
        guard let existing = readExisting(url) else { return false }
        let servers = existing["mcpServers"] as? [String: Any]
        return servers?["ctx"] != nil
    }

    /// Merges CTX's entry into whatever the client's config already has —
    /// other MCP servers configured there are left untouched — and backs up
    /// the original file first, the same way CTX's shell-integration
    /// installer backs up `.zshrc`/`.bashrc` before touching them.
    public static func install(for client: MCPClientKind, binaryPath: String) throws {
        try install(at: client.configURL, binaryPath: binaryPath)
    }

    /// Takes an explicit URL rather than always resolving `client.configURL`
    /// so tests can point this at a temp file instead of the real
    /// `~/Library/Application Support/Claude/...` on the machine running them.
    public static func install(at url: URL, binaryPath: String) throws {
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        var root: [String: Any] = [:]
        if fileExists {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw MCPClientInstallError.corruptExistingConfig(path: url.path)
                }
                root = parsed
            }
        }

        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["ctx"] = serverEntry(binaryPath: binaryPath)
        root["mcpServers"] = servers

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileExists {
            let backupURL = url.appendingPathExtension("ctx-backup")
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.copyItem(at: url, to: backupURL)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func readExisting(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parsed
    }
}
