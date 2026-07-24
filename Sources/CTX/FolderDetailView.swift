import AppKit
import CTXCore
import SwiftUI

struct FolderDetailView: View {
    let folder: CloudFolder
    @ObservedObject var store: ProfileStore
    @Binding var sheet: SidebarSheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Header Hero
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: folder.icon.systemImage)
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.separator.opacity(0.3), lineWidth: 1)
                        }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("\(folder.provider.rawValue) · \(folder.name)")
                                .font(.title2.weight(.semibold))
                            
                            Button {
                                sheet = .editFolder(folder)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Rename Folder")
                        }
                        Text("Environment folder containing profiles")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button {
                        switch folder.provider {
                        case .aws: sheet = .addAWSProfile
                        case .gcp: sheet = .addGCPProfile
                        case .azure: sheet = .addAzureProfile
                        case .kubernetes: sheet = .addKubeContext
                        }
                    } label: {
                        Label(folder.provider == .kubernetes ? "Add Context" : "Add Profile", systemImage: "plus")
                    }
                    .buttonStyle(CTXPrimaryButton())
                }
                
                Divider()
                
                let profiles = store.profiles.filter {
                    $0.provider == folder.provider && store.folder(for: $0).id == folder.id
                }
                
                if profiles.isEmpty {
                    ContentUnavailableView("No Profiles in Folder", systemImage: "cloud.slash", description: Text("Click the + button in the sidebar to add a profile to this folder."))
                        .padding(.vertical, 40)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Profiles (\(profiles.count))")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        
                        VStack(spacing: 12) {
                            ForEach(profiles) { profile in
                                FolderProfileRow(profile: profile, store: store, sheet: $sheet)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(32)
        }
    }
}

struct FolderProfileRow: View {
    let profile: CloudProfile
    @ObservedObject var store: ProfileStore
    @Binding var sheet: SidebarSheet?

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(profile.status.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.body.weight(.semibold))
                    
                    if store.isActive(profile) {
                        Text("Active")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor, in: Capsule())
                    }
                    
                    if profile.status == .connected {
                        if let expiresAt = store.sessionExpiry(for: profile) {
                            SessionCountdownView(expiresAt: expiresAt, tintColor: .green, fontSize: 9)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.12), in: Capsule())
                                .foregroundColor(.green)
                                .overlay {
                                    Capsule()
                                        .stroke(Color.green.opacity(0.2), lineWidth: 0.5)
                                }
                        } else {
                            HStack(spacing: 3) {
                                Image(systemName: "timer")
                                    .font(.system(size: 7, weight: .bold))
                                Text("Connected")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.12), in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(Color.green.opacity(0.2), lineWidth: 0.5)
                            }
                        }
                    } else if profile.status.isBusy {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.5)
                                .frame(width: 8, height: 8)
                            Text(profile.status.rawValue)
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(profile.status.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(profile.status.color.opacity(0.12), in: Capsule())
                    }
                }

                if profile.provider == .aws {
                    Text("Role: \(profile.roleName)  ·  Account: \(profile.accountID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if profile.provider == .azure {
                    Text("Subscription: \(profile.accountID)  ·  Tenant: \(profile.roleName.isEmpty ? "—" : profile.roleName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if profile.provider == .kubernetes {
                    Text("Kubernetes context")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Account: \(profile.roleName)  ·  Project: \(profile.accountID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if profile.status.isBusy {
                    Button {} label: {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(profile.status.rawValue + "...")
                        }
                    }
                    .buttonStyle(CTXSecondaryButton())
                    .disabled(true)
                } else if profile.status == .connected {
                    Button("Disconnect") {
                        store.logout(profile)
                    }
                    .buttonStyle(CTXSecondaryButton())
                } else {
                    Button("Connect") {
                        store.login(profile)
                    }
                    .buttonStyle(CTXPrimaryButton())
                }

                if !store.isActive(profile) {
                    Button("Activate") {
                        store.setActive(profile)
                    }
                    .buttonStyle(CTXSecondaryButton())
                }

                Button {
                    sheet = .editProfile(profile)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(CTXSecondaryButton())
                .help("Edit Profile")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.opacity(0.2), lineWidth: 1)
        }
    }
}
