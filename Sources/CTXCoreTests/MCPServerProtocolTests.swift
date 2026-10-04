import CTXCore
import Foundation

func testCTXMCPServerProtocol() {
    let server = CTXMCPServer()

    // Test initialize
    let initMsg = """
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
    """
    server.handleMessage(initMsg)

    // Test tools/list
    let listToolsMsg = """
    {"jsonrpc":"2.0","id":2,"method":"tools/list"}
    """
    server.handleMessage(listToolsMsg)
}

@MainActor
func testKubernetesExplicitConnectionGuard() async throws {
    let (store, _, directory, defaults, suiteName) = try makeKubeActivationStore()
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let target = store.profiles.first { $0.name == "new" }!
    assert(target.status != .connected, "Initial profile status should not be connected")

    // Passive / sweep verification should be completely ignored for unconnected Kubernetes clusters
    let passiveResult = await store.verify(target, isManualAttempt: false)
    assert(!passiveResult, "Passive verification of unconnected cluster must be refused")
    assert(store.profiles.first { $0.name == "new" }?.status != .connected)

    // Explicit manual verification should succeed
    let manualResult = await store.verify(target, isManualAttempt: true)
    assert(manualResult, "Manual explicit verification must succeed")
}

func testMCPClientInstaller() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-mcp-install-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("nested/config.json")

    // No file yet: not installed, and installing creates the directory and file.
    assert(!MCPClientInstaller.isInstalled(at: url), "Must not report installed before the file exists")
    try MCPClientInstaller.install(at: url, binaryPath: "/Applications/CTX.app/Contents/MacOS/CTX")
    assert(MCPClientInstaller.isInstalled(at: url), "Must report installed right after install")

    let written = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let servers = written?["mcpServers"] as? [String: Any]
    let ctxEntry = servers?["ctx"] as? [String: Any]
    assert(ctxEntry?["command"] as? String == "/Applications/CTX.app/Contents/MacOS/CTX")
    assert((ctxEntry?["args"] as? [String]) == ["--mcp"])

    // Installing again over a config that already has another server must keep it.
    let withOtherServer: [String: Any] = ["mcpServers": ["other": ["command": "/usr/bin/other"]]]
    try JSONSerialization.data(withJSONObject: withOtherServer).write(to: url)
    try MCPClientInstaller.install(at: url, binaryPath: "/Applications/CTX.app/Contents/MacOS/CTX")
    let merged = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let mergedServers = merged?["mcpServers"] as? [String: Any]
    assert(mergedServers?["other"] != nil, "Installing must not remove an existing, unrelated MCP server entry")
    assert(mergedServers?["ctx"] != nil, "Installing must add the ctx entry alongside it")

    // A backup of the pre-install file must exist.
    let backupURL = url.appendingPathExtension("ctx-backup")
    assert(FileManager.default.fileExists(atPath: backupURL.path), "Install must back up the previous config before overwriting it")

    // A config file that isn't valid JSON must be refused, not silently overwritten.
    let corruptURL = dir.appendingPathComponent("corrupt.json")
    try Data("not json".utf8).write(to: corruptURL)
    do {
        try MCPClientInstaller.install(at: corruptURL, binaryPath: "/Applications/CTX.app/Contents/MacOS/CTX")
        assertionFailure("Must throw rather than overwrite a config file that doesn't parse as JSON")
    } catch is MCPClientInstallError {
        // expected
    }
    let corruptContents = try String(contentsOf: corruptURL, encoding: .utf8)
    assert(corruptContents == "not json", "Corrupt config must be left untouched")
}

func runMCPServerAndSafetyTests() async throws {
    testCTXMCPServerProtocol()
    try await testKubernetesExplicitConnectionGuard()
    try testMCPClientInstaller()
}
