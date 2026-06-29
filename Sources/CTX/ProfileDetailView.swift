import CTXCore
import SwiftUI

struct ProfileDetailView: View {
    let profile: CloudProfile
    @ObservedObject var store: ProfileStore
    @Binding var sheet: SidebarSheet?
    @State private var copiedField: String? = nil
    @State private var deleteCandidate: CloudProfile? = nil

    var body: some View {
        ScrollView {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 28) {
                    // Header Hero Section
                    HStack(alignment: .center, spacing: 16) {
                        ProviderIcon(
                            provider: profile.provider,
                            size: 32,
                            fallbackTint: store.isActive(profile) ? Color.accentColor : (profile.status == .connected ? Color.green : Color.secondary)
                        )
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.separator.opacity(0.3), lineWidth: 1)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(profile.name)
                                    .font(.title2.weight(.semibold))
                                
                                if store.isActive(profile) {
                                    Text("ACTIVE")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor, in: Capsule())
                                }
                            }
                            
                            Text("\(profile.provider.rawValue) · \(profile.typeDescription)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        // Top-Right Action Buttons
                        HStack(spacing: 8) {
                            Button {
                                sheet = .editProfile(profile)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            
                            if profile.status == .connected {
                                Button(role: .destructive) {
                                    store.logout(profile)
                                } label: {
                                    Text("Disconnect")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                            } else {
                                Button {
                                    store.login(profile)
                                } label: {
                                    Text("Connect")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                            }
                            
                            // More Actions Dropdown Menu (...)
                            Menu {
                                if !store.isActive(profile) {
                                    Button("Set Active") {
                                        store.setActive(profile)
                                    }
                                }
                                
                                Button("Verify Status") {
                                    Task { await store.verify(profile) }
                                }
                                
                                if profile.provider != .kubernetes {
                                    Button("Duplicate...") {
                                        sheet = .duplicateProfile(profile)
                                    }
                                }
                                
                                Menu("Move profile to...") {
                                    ForEach(store.allFolders) { folder in
                                        if folder.provider == profile.provider {
                                            Button(folder.name) {
                                                store.move(profile, to: folder)
                                            }
                                        }
                                    }
                                }
                                
                                Divider()
                                
                                Button("Delete Profile", role: .destructive) {
                                    deleteCandidate = profile
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 12, height: 16)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                    }
                    .padding(.bottom, 8)

                    // SESSION CARD (Only when connected or has session data)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SESSION")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        
                        VStack(spacing: 0) {
                            // Row 1: Connection Status
                            HStack {
                                Text("Connection")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(profile.status == .connected ? Color.green : Color.orange)
                                        .frame(width: 6, height: 6)
                                    Text(statusText)
                                        .fontWeight(.medium)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            
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
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                            
                            // Row 3: Connected Identity initials and label
                            Divider()
                                .padding(.leading, 16)
                            HStack {
                                Text("Identity")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                HStack(spacing: 6) {
                                    Text(store.activeIdentityInitials)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(Color.accentColor)
                                        .frame(width: 18, height: 18)
                                        .background(Color.accentColor.opacity(0.15), in: Circle())
                                    
                                    Text(store.activeIdentityLabel)
                                        .fontWeight(.medium)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.separator.opacity(0.3), lineWidth: 1)
                        }
                    }

                    // ACCOUNT / CONFIGURATION DETAILS CARD
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ACCOUNT")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
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
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            
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
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
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
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
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
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
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
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.separator.opacity(0.3), lineWidth: 1)
                        }
                    }

                    // DIAGNOSTICS CARD
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DIAGNOSTICS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        
                        VStack(spacing: 0) {
                            HStack {
                                Text("Last Login")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(formatted(store.lastLoginAt))
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            
                            Divider()
                                .padding(.leading, 16)
                            
                            HStack {
                                Text("Last Verification")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(formatted(store.lastVerifiedAt))
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            
                            Divider()
                                .padding(.leading, 16)
                            
                            HStack {
                                Text("Last Call Duration")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(duration(store.lastCommandDuration))
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.separator.opacity(0.3), lineWidth: 1)
                        }
                    }
                }
                .frame(maxWidth: 680)
                Spacer()
            }
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
        switch profile.status {
        case .unknown:
            return profile.provider == .kubernetes ? "Inactive" : "Not Checked"
        default:
            return profile.status.rawValue
        }
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
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }

    private func copyToClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(value, forType: .string)
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

extension ProfileStatus {
    var color: Color {
        switch self {
        case .connected: return .green
        case .needsLogin: return .orange
        case .missingCli: return .red
        case .unknown: return .gray
        }
    }

    var systemImage: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .needsLogin: return "exclamationmark.triangle.fill"
        case .missingCli: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}
