import CTXCore
import SwiftUI

struct ProfileDetailView: View {
    let profile: CloudProfile
    @ObservedObject var store: ProfileStore
    @Binding var sheet: SidebarSheet?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var copiedField: String? = nil
    @State private var deleteCandidate: CloudProfile? = nil

    /// Discovering roles reads and parses the whole of `~/.aws/config`. As a
    /// computed property it sat inside `body`, so that disk read ran on every
    /// single render of this screen — including each tick of the session countdown
    /// and every status change. Loaded once per profile instead, off the main
    /// thread, and only for AWS.
    @State private var availableRoles: [String] = []

    private func loadAvailableRoles() async {
        guard profile.provider == .aws else {
            availableRoles = []
            return
        }
        let accountID = profile.accountID
        let ssoStartURL = profile.ssoStartURL
        availableRoles = await Task.detached {
            AWSConfigParser.discoverAvailableRoles(accountID: accountID, ssoStartURL: ssoStartURL)
        }.value
    }

    private var sectionHeaderStyle: AnyShapeStyle {
        colorScheme == .light ? AnyShapeStyle(Color.primary.opacity(0.75)) : AnyShapeStyle(Color.secondary)
    }

    private var fieldLabelStyle: AnyShapeStyle {
        colorScheme == .light ? AnyShapeStyle(Color.primary.opacity(0.8)) : AnyShapeStyle(Color.secondary)
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center, spacing: 16) {
                        ProviderIcon(
                            provider: profile.provider,
                            size: 34,
                            fallbackTint: (store.isActive(profile) && currentProfile.status == .connected) ? Color.accentColor : currentProfile.status.color
                        )
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.white.opacity(0.22), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(profile.name)
                                    .font(.system(size: 18, weight: .bold))
                                    .lineLimit(1)
                                
                                if store.isActive(profile) && profile.status == .connected {
                                    Text("ACTIVE")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor, in: Capsule())
                                }
                            }
                            
                            let env = CloudEnvironment.infer(from: profile).rawValue
                            let typeSuffix = profile.provider == .aws ? "SSO" : (profile.provider == .gcp ? "Config" : (profile.provider == .kubernetes ? "Context" : "Subscription"))
                            Text("\(profile.provider.rawValue) · \(env) · \(typeSuffix)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 8) {
                            if canOpenWorkspace, let context = kubernetesContext {
                                Button {
                                    openWindow(id: "cluster-workspace", value: context.id)
                                } label: {
                                    Label("Workspace", systemImage: "rectangle.3.group")
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                        .frame(height: 34)
                                        .padding(.horizontal, 13)
                                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .ctxHeaderButton(tint: .indigo, isProminent: true)
                                .help("Open Cluster Workspace")
                            }

                            Button {
                                sheet = .editProfile(profile)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .frame(height: 34)
                                    .padding(.horizontal, 13)
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .ctxHeaderButton()
                            
                            if currentProfile.status.isBusy {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(currentProfile.status.rawValue + "...")
                                }
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .frame(height: 34)
                                .padding(.horizontal, 14)
                                .foregroundStyle(.secondary)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else if canDisconnect {
                                Button(role: .destructive) {
                                    store.logout(profile)
                                } label: {
                                    Text("Disconnect")
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                        .frame(height: 34)
                                        .padding(.horizontal, 14)
                                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .ctxHeaderButton(tint: .red, isProminent: false)
                            } else {
                                Button {
                                    store.login(profile)
                                } label: {
                                    Text("Connect")
                                        .font(.system(size: 14, weight: .semibold))
                                        .lineLimit(1)
                                        .frame(height: 34)
                                        .padding(.horizontal, 18)
                                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .ctxHeaderButton(tint: .blue, isProminent: true)
                            }
                            
                            Menu {
                                if !store.isActive(profile) {
                                    Button {
                                        store.setActive(profile)
                                    } label: {
                                        Label("Set Active", systemImage: "checkmark.circle")
                                    }
                                }

                                Button {
                                    Task { await store.verify(profile, isManualAttempt: true) }
                                } label: {
                                    Label("Verify Status", systemImage: "checkmark.shield")
                                }

                                if canOpenWorkspace, let context = kubernetesContext {
                                    Button {
                                        openWindow(id: "cluster-workspace", value: context.id)
                                    } label: {
                                        Label("Open Cluster Workspace", systemImage: "rectangle.3.group")
                                    }
                                }

                                if profile.provider != .kubernetes {
                                    Button {
                                        sheet = .duplicateProfile(profile)
                                    } label: {
                                        Label("Duplicate", systemImage: "plus.square.on.square")
                                    }
                                }

                                Menu {
                                    ForEach(store.allFolders.filter { $0.provider == profile.provider }) { folder in
                                        Button {
                                            store.move(profile, to: folder)
                                        } label: {
                                            Label(folder.name, systemImage: folder.icon.systemImage)
                                        }
                                    }
                                } label: {
                                    Label("Move to Folder", systemImage: "folder")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    deleteCandidate = profile
                                } label: {
                                    Label("Delete Profile", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 42, height: 34)
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .menuStyle(.button)
                            .menuIndicator(.hidden)
                            .ctxHeaderButton()
                            .accessibilityLabel("More actions")
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.bottom, 8)

                    if profile.provider == .kubernetes && (currentProfile.status == .needsLogin || store.verificationErrors[profile.id] != nil) {
                        let errorMessage = store.verificationErrors[profile.id]
                        KubeAuthRemediationCardView(
                            profile: profile,
                            errorMessage: errorMessage,
                            onConnect: {
                                store.login(profile)
                            },
                            onRunTerminal: { cmd in
                                triggerTerminalCommand(cmd)
                            }
                        )
                    } else if let errorMessage = store.verificationErrors[profile.id] {
                        if errorMessage.lowercased().contains("sso") || errorMessage.lowercased().contains("exec code 255") {
                            let awsProfileName = extractAWSProfileName(from: errorMessage, profile: profile)
                            let loginCmd = "aws sso login --profile \(awsProfileName)"

                            AWSSSOLoginCardView(profileName: awsProfileName, loginCmd: loginCmd) {
                                triggerTerminalCommand(loginCmd)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("Connection Issue")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.primary)
                                }
                                Text(errorMessage)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(6)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("SESSION")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(sectionHeaderStyle)
                            .tracking(1.1)
                            .padding(.leading, 4)
                        
                        VStack(spacing: 0) {
                            // Row 1: Connection Status
                            HStack {
                                Text("Connection")
                                    .foregroundStyle(fieldLabelStyle)
                                Spacer()
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(connectionIsActive ? Color.green : currentProfile.status.color)
                                        .frame(width: 6, height: 6)
                                    Text(statusText)
                                        .fontWeight(.medium)
                                }
                            }
                            .padding(.horizontal, 18)
                            .frame(minHeight: 38)
                            
                            // Row 2: AWS Expires Countdown (if active AWS SSO session)
                            if profile.provider == .aws, store.isActive(profile), let expiresAt = store.activeAWSExpiresAt, expiresAt > Date() {
                                Divider()
                                    .padding(.leading, 16)
                                HStack {
                                    Text("Expires in")
                                        .foregroundStyle(fieldLabelStyle)
                                    Spacer()
                                    SessionCountdownView(expiresAt: expiresAt)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.orange)
                                }
                                .padding(.horizontal, 18)
                                .frame(minHeight: 38)
                            }
                            
                            // Row 3: Connected Identity initials and label
                            Divider()
                                .padding(.leading, 16)
                            HStack {
                                Text("Identity")
                                    .foregroundStyle(fieldLabelStyle)
                                Spacer()
                                if connectionIsActive && store.isActive(profile) {
                                    HStack(spacing: 6) {
                                        Text(store.activeIdentityInitials)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(Color.accentColor)
                                            .frame(width: 18, height: 18)
                                            .background(Color.accentColor.opacity(0.15), in: Circle())
                                        
                                        Text(store.activeIdentityLabel)
                                            .fontWeight(.medium)
                                    }
                                } else {
                                    Text("Not Active")
                                        .foregroundStyle(fieldLabelStyle)
                                        .fontWeight(.medium)
                                }
                            }
                            .padding(.horizontal, 18)
                            .frame(minHeight: 38)
                        }
                        .ctxGlassCard()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ACCOUNT")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(sectionHeaderStyle)
                            .tracking(1.1)
                            .padding(.leading, 4)
                        
                        VStack(spacing: 0) {
                            // Row 1: Account ID
                            HStack {
                                Text(profile.accountLabel)
                                    .foregroundStyle(fieldLabelStyle)
                                Spacer()
                                HStack(spacing: 6) {
                                    Text(profile.accountID.isEmpty ? "-" : profile.accountID)
                                        .font(.system(.body, design: .monospaced))
                                        .fontWeight(.medium)
                                        .textSelection(.enabled)
                                    if !profile.accountID.isEmpty {
                                        copyButton(for: profile.accountID, fieldName: "account")
                                    }
                                }
                            }
                            .padding(.horizontal, 18)
                            .frame(minHeight: 38)
                            
                            // Row 2: Region (if not empty)
                            if !profile.region.isEmpty {
                                Divider()
                                    .padding(.leading, 16)
                                HStack {
                                    Text(profile.regionLabel)
                                        .foregroundStyle(fieldLabelStyle)
                                    Spacer()
                                    Text(profile.region)
                                        .font(.system(.body, design: .monospaced))
                                        .fontWeight(.medium)
                                }
                                .padding(.horizontal, 18)
                                .frame(minHeight: 38)
                            }
                            
                            // Row 3: Role (with interactive Role Selector for AWS)
                            if !profile.roleName.isEmpty || profile.provider == .aws {
                                Divider()
                                    .padding(.leading, 16)
                                HStack {
                                    Text(profile.roleLabel)
                                        .foregroundStyle(fieldLabelStyle)
                                    Spacer()
                                    
                                    if availableRoles.count > 1 {
                                        AWSRoleMenu(roles: availableRoles, currentRole: profile.roleName) { newRole in
                                            var draft = AWSProfileDraft(profile: profile)
                                            draft.roleName = newRole
                                            try? store.updateAWSProfile(profile, draft: draft)
                                        }
                                    } else {
                                        HStack(spacing: 6) {
                                            Text(profile.roleName.isEmpty ? "-" : profile.roleName)
                                                .font(.system(.body, design: .monospaced))
                                                .fontWeight(.medium)
                                                .textSelection(.enabled)
                                            if !profile.roleName.isEmpty {
                                                copyButton(for: profile.roleName, fieldName: "role")
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 18)
                                .frame(minHeight: 38)
                            }
                            
                            // Row 4: AWS SSO Start URL (if AWS)
                            if profile.provider == .aws && !profile.ssoStartURL.isEmpty {
                                Divider()
                                    .padding(.leading, 16)
                                HStack {
                                    Text("SSO Start URL")
                                        .foregroundStyle(fieldLabelStyle)
                                    Spacer()
                                    Text(profile.ssoStartURL)
                                        .lineLimit(1)
                                        .fontWeight(.medium)
                                        .textSelection(.enabled)
                                }
                                .padding(.horizontal, 18)
                                .frame(minHeight: 38)
                            }
                            
                            // Row 5: AWS SSO Region (if AWS)
                            if profile.provider == .aws && !profile.ssoRegion.isEmpty {
                                Divider()
                                    .padding(.leading, 16)
                                HStack {
                                    Text("SSO Region")
                                        .foregroundStyle(fieldLabelStyle)
                                    Spacer()
                                    Text(profile.ssoRegion)
                                        .font(.system(.body, design: .monospaced))
                                        .fontWeight(.medium)
                                }
                                .padding(.horizontal, 18)
                                .frame(minHeight: 38)
                            }
                        }
                        .ctxGlassCard()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("DIAGNOSTICS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(sectionHeaderStyle)
                            .tracking(1.1)
                            .padding(.leading, 4)
                        
                        VStack(spacing: 0) {
                            HStack {
                                Text("Last Login")
                                    .foregroundStyle(fieldLabelStyle)
                                Spacer()
                                Text(formatted(store.lastLoginAt))
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 18)
                            .frame(minHeight: 38)
                            
                            Divider()
                                .padding(.leading, 16)
                            
                            HStack {
                                Text("Last Verification")
                                    .foregroundStyle(fieldLabelStyle)
                                Spacer()
                                Text(formatted(store.lastVerifiedAt))
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 18)
                            .frame(minHeight: 38)
                            
                            Divider()
                                .padding(.leading, 16)
                            
                            HStack {
                                Text("Last Call Duration")
                                    .foregroundStyle(fieldLabelStyle)
                                Spacer()
                                Text(duration(store.lastCommandDuration))
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 18)
                            .frame(minHeight: 38)
                        }
                        .ctxGlassCard()
                    }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(32)
        .alert(
            "Delete \(deleteCandidate?.name ?? "profile")?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let profile = deleteCandidate {
                    do {
                        switch profile.provider {
                        case .aws:
                            try store.deleteAWSProfile(profile)
                        case .gcp:
                            try store.deleteGCPProfile(profile)
                        case .azure:
                            try store.deleteAzureProfile(profile)
                        case .kubernetes:
                            Task {
                                do {
                                    try await store.deleteKubeContext(profile)
                                } catch {
                                    store.report(error.localizedDescription)
                                }
                            }
                        }
                    } catch {
                        store.report(error.localizedDescription)
                    }
                }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            if let profile = deleteCandidate {
                switch profile.provider {
                case .aws:
                    Text("CTX will remove this AWS profile and its matching SSO session from ~/.aws/config after creating a backup.")
                case .gcp:
                    Text("CTX will permanently delete the gcloud configuration file config_\(profile.name) from ~/.config/gcloud/configurations/.")
                case .azure:
                    Text("CTX will permanently delete the Azure profile JSON file config_\(profile.name).json from ~/.config/ctx/azure/.")
                case .kubernetes:
                    Text("CTX will delete the context \(profile.name) from your ~/.kube/config configuration file.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .task(id: profile.id) {
            await loadAvailableRoles()
        }
    }
}

    private var currentProfile: CloudProfile {
        store.profiles.first(where: { $0.id == profile.id }) ?? profile
    }

    private var statusText: String {
        if profile.provider == .kubernetes {
            if store.isActive(profile) {
                return currentProfile.status == .connected ? "Connected" : currentProfile.status.rawValue
            } else {
                return "Inactive"
            }
        }
        switch currentProfile.status {
        case .unknown:
            return "Not Checked"
        default:
            return currentProfile.status.rawValue
        }
    }

    private var connectionIsActive: Bool {
        profile.provider == .kubernetes ? (store.isActive(profile) && currentProfile.status == .connected) : currentProfile.status == .connected
    }

    private var canDisconnect: Bool {
        currentProfile.status == .connected
    }

    private var canOpenWorkspace: Bool {
        profile.provider == .kubernetes && store.isActive(profile) && currentProfile.status == .connected
    }

    private var kubernetesContext: KubernetesContextProfile? {
        guard profile.provider == .kubernetes else { return nil }
        return store.kubernetesContexts.first { $0.contextName == profile.name }
    }


    
    private func copyButton(for value: String, fieldName: String) -> some View {
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

    private func formatted(_ date: Date?) -> String {
        guard let date else {
            return "Never"
        }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func duration(_ duration: TimeInterval?) -> String {
        guard let duration else {
            return "-"
        }
        return String(format: "%.2fs", duration)
    }

    private func extractAWSProfileName(from errorMessage: String, profile: CloudProfile) -> String {
        if !profile.roleName.isEmpty {
            return profile.roleName
        }
        let lower = errorMessage.lowercased()
        if let range = lower.range(of: "for ") {
            let substring = errorMessage[range.upperBound...]
            if let spaceIdx = substring.firstIndex(of: " ") {
                let name = String(substring[..<spaceIdx])
                if !name.isEmpty && name != "does" && name != "the" && name != "a" {
                    return name
                }
            }
        }
        return "aws-sso-profile"
    }

    /// Hands a remediation command to Terminal.app.
    ///
    /// The command is built from a profile name that CTX does not control — it comes
    /// from `~/.aws/config` or a kubeconfig, and on the AWS SSO path partly from a
    /// word sliced out of CLI *error output*. Interpolating that straight into
    /// `do script "…"` let a name containing a quote or semicolon run arbitrary
    /// commands in the user's shell. Nothing is sent unless every argument matches
    /// the shape a real profile/context name has, and the literal is escaped on the
    /// way into AppleScript.
    private func triggerTerminalCommand(_ script: String) {
        guard ShellCommandSafety.isSafeForTerminal(script) else {
            copyToClipboard(script)
            store.report("Command copied to clipboard — it contains characters CTX will not run for you.")
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
            var errorDict: NSDictionary?
            scriptObject.executeAndReturnError(&errorDict)
        }
    }
}

struct CTXCopyButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .padding(4)
            .background(isHovered ? Color.secondary.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

private struct AWSRoleMenu: View {
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
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        case .connected: return .green
        case .connecting, .disconnecting: return .blue
        case .needsLogin: return .orange
        case .missingCli: return .red
        case .unknown: return .gray
        }
    }

    var systemImage: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .disconnecting: return "arrow.triangle.2.circlepath"
        case .needsLogin: return "exclamationmark.triangle.fill"
        case .missingCli: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

private struct KubeAuthRemediationCardView: View {
    let profile: CloudProfile
    let errorMessage: String?
    let onConnect: () -> Void
    let onRunTerminal: (String) -> Void

    @State private var isLaunchingTerminal = false
    @State private var isVerifying = false
    @State private var statusNotice: String? = nil

    private var isSDM: Bool { profile.usesStrongDM }

    private var isTeleport: Bool { profile.usesTeleport }

    private var isAWSSSO: Bool {
        profile.name.lowercased().contains("aws") || profile.roleName.lowercased().contains("aws") || (errorMessage?.lowercased().contains("sso") ?? false)
    }

    private var authTitle: String {
        if isSDM { return "StrongDM Authentication Required" }
        if isTeleport { return "Teleport (tsh) Login Required" }
        if isAWSSSO { return "AWS SSO Authentication Required" }
        return "Kubernetes Identity Authentication Required"
    }

    private var authExplanation: String {
        if isSDM {
            return "This cluster is routed via StrongDM. Run sdm connect or authenticate to establish a secure connection."
        }
        if isTeleport {
            return "This cluster is managed via Teleport. Run tsh login to renew your access certificate."
        }
        if isAWSSSO {
            return "EKS cluster access requires an active AWS SSO session. Re-authenticate to access cluster resources."
        }
        return "Kubernetes credential plugin requires Single Sign-On (Okta / SAML) authentication to generate an access token."
    }

    private var commandSnippet: String {
        if isSDM {
            return "sdm connect \(profile.name)"
        }
        if isTeleport {
            return "tsh kube login \(profile.name)"
        }
        if isAWSSSO {
            return "aws sso login --profile \(profile.name)"
        }
        return "kubectl get --raw=/version --context \(profile.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: isSDM ? "network.badge.shield.half.filled" : (isTeleport ? "lock.shield.fill" : "key.fill"))
                    .foregroundStyle(.orange)
                    .font(.system(size: 15))
                Text(authTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
            }

            Text(authExplanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(commandSnippet)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                CTXCopyIconButton(value: commandSnippet)
            }
            .padding(8)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

            if let notice = statusNotice {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(notice)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 2)
                .transition(.opacity)
            }

            HStack(spacing: 10) {
                Button {
                    isLaunchingTerminal = true
                    statusNotice = "Terminal launched. Complete login in the Terminal window."
                    onRunTerminal(commandSnippet)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        isLaunchingTerminal = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isLaunchingTerminal {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "terminal.fill")
                        }
                        Text(isLaunchingTerminal ? "Opening..." : "Run in Terminal")
                    }
                }
                .buttonStyle(CTXPrimaryButton())
                .controlSize(.small)

                Button {
                    isVerifying = true
                    statusNotice = "Connecting to cluster & verifying status..."
                    onConnect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        isVerifying = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isVerifying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isVerifying ? "Verifying..." : "Connect & Verify")
                    }
                }
                .buttonStyle(CTXSecondaryButton())
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        }
    }
}

private struct AWSSSOLoginCardView: View {
    let profileName: String
    let loginCmd: String
    let onRunTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.orange)
                Text("AWS SSO Authentication Required")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
            }
            Text("Your AWS SSO token for profile '\(profileName)' has expired or is missing. Run SSO login to authenticate.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                Text(loginCmd)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                CTXCopyIconButton(value: loginCmd)
            }
            .padding(8)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

            Button {
                onRunTerminal()
            } label: {
                Label("Run AWS SSO Login in Terminal", systemImage: "terminal.fill")
            }
            .buttonStyle(CTXPrimaryButton())
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        }
    }
}
