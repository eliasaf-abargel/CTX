import AppKit
import CTXCore
import SwiftUI

extension ProfileDetailView {
    var sectionHeaderStyle: AnyShapeStyle {
        colorScheme == .light
            ? AnyShapeStyle(Color.primary.opacity(0.75))
            : AnyShapeStyle(Color.secondary)
    }

    var fieldLabelStyle: AnyShapeStyle {
        colorScheme == .light
            ? AnyShapeStyle(Color.primary.opacity(0.8))
            : AnyShapeStyle(Color.secondary)
    }

    var currentProfile: CloudProfile {
        store.profiles.first(where: { $0.id == profile.id }) ?? profile
    }

    var statusText: String {
        if profile.provider == .kubernetes {
            if store.isActive(profile) {
                return currentProfile.status == .connected
                    ? "Connected"
                    : currentProfile.status.rawValue
            }
            return "Inactive"
        }
        return currentProfile.status == .unknown
            ? "Not Checked"
            : currentProfile.status.rawValue
    }

    var connectionIsActive: Bool {
        profile.provider == .kubernetes
            ? store.isActive(profile) && currentProfile.status == .connected
            : currentProfile.status == .connected
    }

    var canDisconnect: Bool {
        currentProfile.status == .connected
    }

    var canOpenWorkspace: Bool {
        profile.provider == .kubernetes
            && store.isActive(profile)
            && currentProfile.status == .connected
    }

    var kubernetesContext: KubernetesContextProfile? {
        guard profile.provider == .kubernetes else { return nil }
        return store.kubernetesContexts.first { $0.contextName == profile.name }
    }

    func copyButton(for value: String, fieldName: String) -> some View {
        Button {
            copyToClipboard(value)
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                copiedField = fieldName
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation {
                    if copiedField == fieldName {
                        copiedField = nil
                    }
                }
            }
        } label: {
            Image(systemName: copiedField == fieldName ? "checkmark.circle.fill" : "doc.on.doc")
                .foregroundStyle(copiedField == fieldName ? .green : .secondary)
                .font(.system(size: 12))
                .frame(width: 28, height: 28)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(CTXCopyButtonStyle())
        .help("Copy to clipboard")
        .accessibilityLabel("Copy \(fieldName)")
    }

    func formatted(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    func duration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "-" }
        return String(format: "%.2fs", duration)
    }

    func extractAWSProfileName(from _: String, profile: CloudProfile) -> String {
        profile.name
    }

    /// Runs only strict, validated remediation commands. Unsafe values are copied
    /// instead, and the AppleScript string is escaped before reaching Terminal.
    func triggerTerminalCommand(_ script: String) {
        guard ShellCommandSafety.isSafeForTerminal(script) else {
            copyToClipboard(script)
            store.reportStatus("Command copied to clipboard — it contains characters CTX will not run for you.")
            return
        }
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        if let scriptObject = NSAppleScript(source: appleScript) {
            var errorDictionary: NSDictionary?
            scriptObject.executeAndReturnError(&errorDictionary)
        }
    }
}

struct CTXCopyButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .padding(4)
            .background(
                isHovered ? Color.secondary.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

struct AWSRoleMenu: View {
    let roles: [String]
    let currentRole: String
    let onSelectRole: (String) -> Void

    var body: some View {
        Menu {
            ForEach(roles, id: \.self) { role in
                Button {
                    onSelectRole(role)
                } label: {
                    HStack {
                        Text(role)
                        if role == currentRole {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentRole.isEmpty ? "Select Role" : currentRole)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

extension ProfileStatus {
    var isBusy: Bool {
        self == .connecting || self == .disconnecting
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .connecting, .disconnecting: .blue
        case .needsLogin: .orange
        case .missingCli: .red
        case .unknown: .gray
        }
    }

    var systemImage: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .connecting, .disconnecting: "arrow.triangle.2.circlepath"
        case .needsLogin: "exclamationmark.triangle.fill"
        case .missingCli: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}
