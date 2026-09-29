import CTXCore
import SwiftUI

/// Shown instead of a failed connect when a provider CLI isn't on this Mac.
///
/// The install is visible and user-initiated on purpose. These CLIs need admin
/// rights, many teams pin their versions, and CTX runs on managed machines where
/// a silent background installer would be both unwelcome and blocked by policy.
struct MissingCLIToolSheet: View {
    @ObservedObject var store: ProfileStore
    let request: MissingCLIToolRequest
    let origin: ProfilePresentationSurface

    @State private var phase: Phase = .idle
    @State private var progressLine = ""
    @State private var copied = false
    @State private var installTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case idle, installing, installed
        case failed(String)
    }

    private var tool: CLITool { request.tool }
    private var canBrewInstall: Bool { tool.installCommand != nil && CLITool.isHomebrewInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: phase == .installed ? "checkmark.circle.fill" : "shippingbox")
                    .font(.system(.headline, weight: .medium))
                    .foregroundStyle(phase == .installed ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase == .installed ? "\(tool.displayName) installed" : "\(tool.displayName) is required")
                        .font(.system(.subheadline, weight: .semibold))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let command = tool.installCommand {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button(copied ? "Copied" : "Copy") { copy(command) }
                        .buttonStyle(CTXInlineActionButton())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            if phase == .installing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progressLine.isEmpty ? "Installing…" : progressLine)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if case .failed(let message) = phase {
                Text(message)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(phase == .installed ? "Close" : "Not Now") {
                    installTask?.cancel()
                    store.dismissPresentation(from: origin)
                }
                    .buttonStyle(CTXSecondaryButton())
                    .keyboardShortcut(.cancelAction)

                if phase == .installed {
                    Button("Connect") {
                        store.retryMissingCLI(request, from: origin)
                    }
                    .buttonStyle(CTXPrimaryButton())
                } else if canBrewInstall {
                    Button("Download Page") {
                        NSWorkspace.shared.open(tool.downloadPage)
                    }
                    .buttonStyle(CTXSecondaryButton())

                    Button("Install with Homebrew") { install() }
                        .buttonStyle(CTXPrimaryButton())
                        .disabled(phase == .installing)
                } else {
                    Button("Open Download Page") { NSWorkspace.shared.open(tool.downloadPage) }
                        .buttonStyle(CTXPrimaryButton())
                }
            }
        }
        .padding(18)
        .frame(width: 420)
        .onDisappear {
            installTask?.cancel()
        }
    }

    private var subtitle: String {
        switch phase {
        case .installed:
            return "Ready to connect \"\(request.profile.name)\"."
        case .failed:
            return "The install did not finish. Run the command yourself, or use the download page."
        default:
            return canBrewInstall
                ? "CTX runs `\(tool.binary)` to connect \"\(request.profile.name)\". It isn't installed on this Mac."
                : "CTX runs `\(tool.binary)` to connect \"\(request.profile.name)\". Homebrew isn't available, so install it from the vendor's page."
        }
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func install() {
        guard let command = tool.installCommand else { return }
        phase = .installing
        progressLine = ""
        installTask?.cancel()
        installTask = Task { @MainActor in
            // Homebrew builds can take minutes; the runner's default bound would
            // kill a perfectly healthy install. The SSO browser suppression is off
            // because a cask install legitimately runs `open` on the package it
            // downloaded, and the no-op stand-in would make that step do nothing.
            let result = await CloudCommandRunner(suppressesBrowserLaunch: false).run(
                command.split(separator: " ").map(String.init),
                timeout: 900,
                onOutput: { chunk in
                    Task { @MainActor in
                        if let line = chunk.split(whereSeparator: \.isNewline).last {
                            progressLine = String(line)
                        }
                    }
                }
            )
            guard !Task.isCancelled else { return }
            phase = result.exitCode == 0
                ? .installed
                : .failed(result.output.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n"))
            installTask = nil
        }
    }
}
