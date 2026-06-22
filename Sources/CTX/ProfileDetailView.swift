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
                    // Header Hero
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center, spacing: 16) {
                            Image(systemName: "cloud.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(store.activeAWSProfile == profile.name ? Color.accentColor : (profile.status == .connected ? Color.green : Color.secondary))
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
                                    
                                    if store.activeAWSProfile == profile.name {
                                        Text("Active Context")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.accentColor, in: Capsule())
                                    }
                                }
                                
                                HStack(spacing: 6) {
                                    Image(systemName: profile.status.systemImage)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(profile.status.color)
                                    Text(statusText)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            
                            Spacer()
                        }
                        
                        // Actions Bar Row (Scrollable horizontally when space is limited)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Button {
                                    store.login(profile)
                                } label: {
                                    Label("Connect", systemImage: "bolt.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                                
                                Button {
                                    store.setActive(profile)
                                } label: {
                                    Text("Set Active")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                
                                Button {
                                    Task { await store.verify(profile) }
                                } label: {
                                    Label("Verify", systemImage: "checkmark.shield")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)

                                Divider()
                                    .frame(height: 16)
                                    .padding(.horizontal, 4)

                                Button {
                                    sheet = .editProfile(profile)
                                } label: {
                                    Image(systemName: "pencil")
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .help("Edit Profile")

                                Button {
                                    sheet = .duplicateProfile(profile)
                                } label: {
                                    Image(systemName: "plus.square.on.square")
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .help("Duplicate Profile")

                                Menu {
                                    ForEach(store.allFolders) { folder in
                                        Button(folder.name) {
                                            store.move(profile, to: folder)
                                        }
                                    }
                                } label: {
                                    Image(systemName: "folder")
                                        .frame(width: 16, height: 16)
                                }
                                .menuStyle(.button)
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .help("Move Profile to Folder")

                                Button(role: .destructive) {
                                    deleteCandidate = profile
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .tint(.red)
                                .help("Delete Profile")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.bottom, 8)

                // Configuration Details Card
                VStack(alignment: .leading, spacing: 12) {
                    Text("Configuration Details")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                        GridRow {
                            Text("AWS Account")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text(profile.accountID.isEmpty ? "-" : profile.accountID)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                if !profile.accountID.isEmpty {
                                    copyButton(for: profile.accountID, fieldName: "account")
                                }
                            }
                        }
                        
                        Divider()
                        
                        GridRow {
                            Text("IAM Role")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text(profile.roleName.isEmpty ? "-" : profile.roleName)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                if !profile.roleName.isEmpty {
                                    copyButton(for: profile.roleName, fieldName: "role")
                                }
                            }
                        }
                        
                        Divider()
                        
                        GridRow {
                            Text("SSO Start URL")
                                .foregroundStyle(.secondary)
                            Text(profile.ssoStartURL.isEmpty ? "-" : profile.ssoStartURL)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        
                        Divider()
                        
                        GridRow {
                            Text("SSO Region")
                                .foregroundStyle(.secondary)
                            Text(profile.ssoRegion.isEmpty ? "-" : profile.ssoRegion)
                                .font(.system(.body, design: .monospaced))
                        }
                        
                        Divider()
                        
                        GridRow {
                            Text("Default Region")
                                .foregroundStyle(.secondary)
                            Text(profile.region.isEmpty ? "-" : profile.region)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.separator.opacity(0.3), lineWidth: 1)
                    }
                }

                // Diagnostics Card
                VStack(alignment: .leading, spacing: 12) {
                    Text("Session Diagnostics")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                        GridRow {
                            Text("Last Login")
                                .foregroundStyle(.secondary)
                            Text(formatted(store.lastLoginAt))
                        }
                        
                        Divider()
                        
                        GridRow {
                            Text("Last Verification")
                                .foregroundStyle(.secondary)
                            Text(formatted(store.lastVerifiedAt))
                        }
                        
                        Divider()
                        
                        GridRow {
                            Text("Last Call Duration")
                                .foregroundStyle(.secondary)
                            Text(duration(store.lastCommandDuration))
                        }
                    }
                    .padding(18)
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
                        try store.deleteAWSProfile(profile)
                    } catch {
                        store.report(error.localizedDescription)
                    }
                }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("CTX will remove this AWS profile and its matching SSO session from ~/.aws/config after creating a backup.")
        }
    }
}

    private var statusText: String {
        switch profile.status {
        case .unknown:
            return "Not Checked"
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

private extension ProfileStatus {
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
