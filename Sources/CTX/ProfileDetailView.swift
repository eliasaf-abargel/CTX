import CTXCore
import SwiftUI

struct ProfileDetailView: View {
    let profile: CloudProfile
    @ObservedObject var store: ProfileStore
    @Binding var sheet: SidebarSheet?
    @Environment(\.openWindow) private var openWindow
    @State private var copiedField: String? = nil
    @State private var deleteCandidate: CloudProfile? = nil


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if CloudEnvironment.infer(from: profile) == .production {
                    CTXProductionWarningBanner(contextName: profile.name)
                }

                HStack(alignment: .center, spacing: 16) {
                        ProviderIcon(
                            provider: profile.provider,
                            size: 34,
                            fallbackTint: store.isActive(profile) ? Color.accentColor : profile.status.color
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
                                
                                if store.isActive(profile) {
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
                                .buttonStyle(.plain)
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
                            .buttonStyle(.plain)
                            .ctxHeaderButton()
                            
                            if profile.status.isBusy {
                                Text(profile.status.rawValue)
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
                                .buttonStyle(.plain)
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
                                .buttonStyle(.plain)
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
                                    Task { await store.verify(profile) }
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
                            .buttonStyle(.plain)
                            .ctxHeaderButton()
                            .accessibilityLabel("More actions")
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.bottom, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("SESSION")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .tracking(1.1)
                            .padding(.leading, 4)
                        
                        VStack(spacing: 0) {
                            // Row 1: Connection Status
                            HStack {
                                Text("Connection")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(connectionIsActive ? Color.green : profile.status.color)
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
                                        .foregroundStyle(.secondary)
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
                                    .foregroundStyle(.secondary)
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
                                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                            .tracking(1.1)
                            .padding(.leading, 4)
                        
                        VStack(spacing: 0) {
                            // Row 1: Account ID
                            HStack {
                                Text(profile.accountLabel)
                                    .foregroundStyle(.secondary)
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
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(profile.region)
                                        .font(.system(.body, design: .monospaced))
                                        .fontWeight(.medium)
                                }
                                .padding(.horizontal, 18)
                                .frame(minHeight: 38)
                            }
                            
                            // Row 3: Role (if not empty)
                            if !profile.roleName.isEmpty {
                                Divider()
                                    .padding(.leading, 16)
                                HStack {
                                    Text(profile.roleLabel)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    HStack(spacing: 6) {
                                        Text(profile.roleName)
                                            .font(.system(.body, design: .monospaced))
                                            .fontWeight(.medium)
                                            .textSelection(.enabled)
                                        copyButton(for: profile.roleName, fieldName: "role")
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
                                        .foregroundStyle(.secondary)
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
                                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                            .tracking(1.1)
                            .padding(.leading, 4)
                        
                        VStack(spacing: 0) {
                            HStack {
                                Text("Last Login")
                                    .foregroundStyle(.secondary)
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
                                    .foregroundStyle(.secondary)
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
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(duration(store.lastCommandDuration))
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
    }
}

    private var statusText: String {
        if profile.provider == .kubernetes {
            return store.isActive(profile) ? "Connected" : "Inactive"
        }
        switch profile.status {
        case .unknown:
            return "Not Checked"
        default:
            return profile.status.rawValue
        }
    }

    private var connectionIsActive: Bool {
        profile.provider == .kubernetes ? store.isActive(profile) : profile.status == .connected
    }

    private var canDisconnect: Bool {
        profile.provider == .kubernetes ? store.isActive(profile) : profile.status == .connected
    }

    private var canOpenWorkspace: Bool {
        profile.provider == .kubernetes && store.isActive(profile)
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
        .buttonStyle(.plain)
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
}

private extension View {
    func ctxGlassCard() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.separator.opacity(0.30), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
    }

    func ctxHeaderButton(tint: Color = .primary, isProminent: Bool = false) -> some View {
        foregroundStyle(isProminent ? Color.white : tint)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isProminent ? tint : Color.secondary.opacity(0.12))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isProminent ? Color.white.opacity(0.20) : Color.white.opacity(0.16), lineWidth: 0.75)
            }
            .shadow(color: isProminent ? .clear : .black.opacity(0.10), radius: isProminent ? 0 : 8, y: isProminent ? 0 : 4)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
