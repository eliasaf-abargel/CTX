import CTXCore
import SwiftUI

extension ProfileDetailView {
    var headerSection: some View {
        HStack(alignment: .center, spacing: 16) {
            ProviderIcon(
                provider: profile.provider,
                size: 34,
                fallbackTint: (store.isActive(profile) && currentProfile.status == .connected)
                    ? Color.accentColor
                    : currentProfile.status.color
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
                        .font(.system(.headline, weight: .bold))
                        .lineLimit(1)

                    if store.isActive(profile) && profile.status == .connected {
                        Text("ACTIVE")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                }

                let environment = CloudEnvironment.infer(from: profile).rawValue
                let typeSuffix = profile.provider == .aws
                    ? "SSO"
                    : (profile.provider == .gcp
                        ? "Config"
                        : (profile.provider == .kubernetes ? "Context" : "Subscription"))
                Text("\(profile.provider.rawValue) · \(environment) · \(typeSuffix)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            headerActions
        }
        .padding(.bottom, 8)
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if canOpenWorkspace, let context = kubernetesContext {
                Button {
                    openWindow(id: "cluster-workspace", value: context.id)
                } label: {
                    Label("Workspace", systemImage: "rectangle.3.group")
                        .font(.system(.footnote, weight: .medium))
                        .lineLimit(1)
                        .frame(height: 34)
                        .padding(.horizontal, 13)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .ctxHeaderButton(tint: .indigo, isProminent: true)
                .help("Open Cluster Workspace")
            }

            Button {
                store.presentProfileEditor(
                    .edit(profile: profile, targetFolder: store.folder(for: profile)),
                    from: .mainWindow
                )
            } label: {
                Label("Edit", systemImage: "pencil")
                    .font(.system(.footnote, weight: .medium))
                    .lineLimit(1)
                    .frame(height: 34)
                    .padding(.horizontal, 13)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .ctxHeaderButton()

            connectionButton
            actionsMenu
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var connectionButton: some View {
        if currentProfile.status.isBusy {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(currentProfile.status.rawValue + "...")
            }
            .font(.system(.footnote, weight: .medium))
            .lineLimit(1)
            .frame(height: 34)
            .padding(.horizontal, 14)
            .foregroundStyle(.secondary)
            .background(
                Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        } else if canDisconnect {
            Button(role: .destructive) {
                store.logout(profile, from: .mainWindow)
            } label: {
                Text(store.needsDisconnectRetry(profile) ? "Retry Disconnect" : "Disconnect")
                    .font(.system(.footnote, weight: .medium))
                    .lineLimit(1)
                    .frame(height: 34)
                    .padding(.horizontal, 14)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .ctxHeaderButton(tint: .red, isProminent: false)
            .help(
                store.isActive(profile)
                    ? "Disconnect \(profile.name) from CTX"
                    : "Mark \(profile.name) disconnected in CTX without changing the active profile"
            )
        } else {
            Button {
                store.login(profile, from: .mainWindow)
            } label: {
                Text("Connect")
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .frame(height: 34)
                    .padding(.horizontal, 18)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .ctxHeaderButton(tint: .blue, isProminent: true)
        }
    }

    private var actionsMenu: some View {
        Menu {
            if !store.isActive(profile) {
                Button {
                    store.setActive(profile, from: .mainWindow)
                } label: {
                    Label("Set Active", systemImage: "checkmark.circle")
                }
            }

            Button {
                Task {
                    await store.verify(profile, isManualAttempt: true, from: .mainWindow)
                }
            } label: {
                Label("Verify Status", systemImage: "checkmark.shield")
            }

            if profile.provider == .aws {
                Button {
                    store.exportAWSCredentials(profile, from: .mainWindow)
                } label: {
                    Label("Export Credentials", systemImage: "square.and.arrow.down")
                }
                .disabled(!store.canExportAWSCredentials(profile))
            }

            if profile.provider != .kubernetes {
                Button(role: .destructive) {
                    store.requestProviderSignOut(profile, from: .mainWindow)
                } label: {
                    Label("Sign Out from Provider…", systemImage: "rectangle.portrait.and.arrow.right")
                }
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
                    store.presentProfileEditor(
                        .duplicate(profile: profile, targetFolder: store.folder(for: profile)),
                        from: .mainWindow
                    )
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
                .font(.system(.footnote, weight: .semibold))
                .frame(width: 42, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .ctxHeaderButton()
        .accessibilityLabel("More actions")
    }
}
