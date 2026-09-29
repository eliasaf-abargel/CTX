import CTXCore
import SwiftUI

struct MCPSettingsView: View {
    @AppStorage(CTXDefaultsKey.mcpApplyEnabled) private var mcpApplyEnabled = false
    @State private var installedState: [MCPClientKind: Bool] = [:]
    @State private var pendingInstallClient: MCPClientKind?
    @State private var justInstalledClient: MCPClientKind?
    @State private var installErrorMessage: String?
    @State private var copiedClient: MCPClientKind?

    private var binaryPath: String {
        Bundle.main.executablePath ?? "/Applications/CTX.app/Contents/MacOS/CTX"
    }

    private func configJSON(for client: MCPClientKind) -> String {
        """
        {
          "mcpServers": {
            "ctx": {
              "command": "\(binaryPath)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                // Header & Status
                HStack(spacing: 12) {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Model Context Protocol (MCP)")
                                .font(.headline)
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                                Text("Ready")
                                    .font(.system(.caption2, weight: .semibold))
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12), in: Capsule())
                        }
                        Text("Connect AI assistants directly to CTX for live cluster queries and safe validation.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Capabilities & Tools Card
                VStack(alignment: .leading, spacing: 10) {
                    Text("Exposed Tools")
                        .font(.subheadline.weight(.semibold))

                    VStack(alignment: .leading, spacing: 6) {
                        toolRow(name: "ctx_list_contexts", desc: "List discovered cluster contexts and active state")
                        toolRow(name: "ctx_get_resources", desc: "Query live pods, nodes, workloads, services, and ingress")
                        toolRow(name: "ctx_validate_diagnostics", desc: "Run cross-resource validation rules and security audits")
                        toolRow(name: "ctx_dry_run_yaml", desc: "Validate YAML changes using server dry-run without apply")
                        toolRow(name: "ctx_apply_yaml", desc: "Apply validated manifests with rollback baselining", disabled: !mcpApplyEnabled)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                Divider()

                // Mutation Gate
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $mcpApplyEnabled) {
                        Text("Allow AI apply (ctx_apply_yaml)")
                            .font(.subheadline.weight(.semibold))
                    }
                    .toggleStyle(.switch)

                    Text("Off by default. Every dry-run and apply is logged locally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Configuration Snippets
                VStack(alignment: .leading, spacing: 12) {
                    Text("Client Configuration")
                        .font(.subheadline.weight(.semibold))

                    ForEach(MCPClientKind.allCases, id: \.self) { client in
                        clientRow(client)
                    }
                }
            }
            .padding(20)
        }
        .onAppear { refreshInstalledState() }
        .alert(
            "Add CTX to \(pendingInstallClient?.displayName ?? "")?",
            isPresented: Binding(
                get: { pendingInstallClient != nil },
                set: { if !$0 { pendingInstallClient = nil } }
            ),
            presenting: pendingInstallClient
        ) { client in
            Button("Install") { performInstall(client) }
            Button("Cancel", role: .cancel) { pendingInstallClient = nil }
        } message: { client in
            Text("Adds a \"ctx\" entry to \(client.configURL.path). Existing servers there are kept, and the current file is backed up first.")
        }
        .alert(
            "Couldn't install",
            isPresented: Binding(
                get: { installErrorMessage != nil },
                set: { if !$0 { installErrorMessage = nil } }
            ),
            presenting: installErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { installErrorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func clientRow(_ client: MCPClientKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(client.displayName)
                    .font(.caption.weight(.semibold))
                Spacer()
                if installedState[client] == true {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Button("Install") { pendingInstallClient = client }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button {
                    copyToClipboard(configJSON(for: client))
                    copiedClient = client
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if copiedClient == client { copiedClient = nil }
                    }
                } label: {
                    Image(systemName: copiedClient == client ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Copy config JSON")
            }

            if justInstalledClient == client {
                Text("Installed. Restart \(client.displayName) to connect.")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }

            Text(configJSON(for: client))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func performInstall(_ client: MCPClientKind) {
        pendingInstallClient = nil
        do {
            try MCPClientInstaller.install(for: client, binaryPath: binaryPath)
            installedState[client] = true
            justInstalledClient = client
        } catch {
            installErrorMessage = error.localizedDescription
        }
    }

    private func refreshInstalledState() {
        for client in MCPClientKind.allCases {
            installedState[client] = MCPClientInstaller.isInstalled(for: client)
        }
    }

    private func toolRow(name: String, desc: String, disabled: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
            Text("—")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if disabled {
                Text("Disabled")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
