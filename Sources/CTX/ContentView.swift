import AppKit
import CTXCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: ProfileStore
    @AppStorage(AppAppearance.storageKey) private var appAppearanceRaw: String = AppAppearance.dark.rawValue
    @AppStorage(CTXDefaultsKey.hasCompletedOnboardingTourV1) private var hasCompletedOnboardingTour = false
    @Environment(\.colorScheme) private var colorScheme

    private var currentAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .dark
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
            .background(colorScheme == .light ? Color(NSColor.controlBackgroundColor).opacity(0.5) : Color.black.opacity(0.25))
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
        } detail: {
            DetailPane(store: store)
                .background(colorScheme == .light ? Color(NSColor.windowBackgroundColor) : Color(white: 0.12).opacity(0.65))
        }
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
        .ctxChromelessWindow()
        .preferredColorScheme(currentAppearance.colorScheme)
        .profileLifecyclePresentationHost(store: store, surface: .mainWindow)
        // Unlike a system sheet, a plain `.overlay` doesn't remove what's
        // underneath from the accessibility tree, so VoiceOver could still
        // reach the sidebar/detail pane through the dimmed scrim.
        .accessibilityHidden(!hasCompletedOnboardingTour)
        .overlay {
            if !hasCompletedOnboardingTour {
                OnboardingTourView {
                    withAnimation(.easeOut(duration: 0.25)) {
                        hasCompletedOnboardingTour = true
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

struct DetailPane: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.openSettings) private var openSettings: OpenSettingsAction

    private var activeToolbarProfiles: [CloudProfile] {
        store.connectedProfiles
    }

    var body: some View {
        VStack(spacing: 0) {
            // Inline notification bars — part of the layout so they NEVER cover content
            if store.showExpirationWarning || store.updateAvailable {
                VStack(spacing: 8) {
                    if store.showExpirationWarning {
                        HStack(spacing: 8) {
                            Image(systemName: "timer")
                                .font(.system(.footnote, weight: .bold))
                                .foregroundStyle(.white)
                            Text(store.expirationWarningMessage)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if store.updateAvailable {
                        Button {
                            store.selectedSettingsTab = 2
                            openSettings()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(.footnote, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("Update Available: \(store.latestVersionString). Click to open settings.")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            // Active profiles list (stacked vertically, row by row / line by line)
            if !activeToolbarProfiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ACTIVE CONNECTIONS")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)

                    ForEach(activeToolbarProfiles) { profile in
                        ActiveConnectionRow(
                            profile: profile,
                            expiresAt: store.sessionExpiry(for: profile),
                            store: store
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }

            // Main content flows BELOW the banners — never covered
            if let profile = store.selectedProfile {
                ProfileDetailView(profile: profile, store: store)
                    .navigationTitle(profile.name)
            } else if let folder = store.selectedFolder {
                FolderDetailView(folder: folder, store: store)
                    .navigationTitle(folder.name)
            } else {
                WelcomeView()
                    .navigationTitle("CTX")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: store.showExpirationWarning)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: store.updateAvailable)

    }
}

/// A live mm:ss countdown to an AWS SSO session's expiry, shown in the toolbar.
struct SessionCountdownView: View {
    let expiresAt: Date
    var tintColor: Color? = nil
    var fontSize: CGFloat = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            let seconds = Int(remaining) % 60
            HStack(spacing: 3) {
                Image(systemName: "timer")
                    .font(.system(size: fontSize - 2, weight: .bold))
                if hours > 0 {
                    Text(String(format: "%d:%02d:%02d", hours, minutes, seconds))
                        .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                } else {
                    Text(String(format: "%02d:%02d", minutes, seconds))
                        .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(tintColor ?? (remaining <= 120 ? Color.orange : Color.secondary))
            .help(hours > 0 ? "Active AWS session expires in \(hours)h \(minutes)m" : "Active AWS session expires in \(minutes)m \(seconds)s")
        }
    }
}

private struct ActiveConnectionRow: View {
    let profile: CloudProfile
    let expiresAt: Date?
    @ObservedObject var store: ProfileStore
    @State private var isHovering = false

    /// One meaning for all four providers: this is the active profile for its provider.
    /// What that propagates to differs, which the help text says rather than the icon.
    private var isPrimary: Bool { store.isActive(profile) }

    private var primaryHelp: String {
        guard !isPrimary else {
            switch profile.provider {
            case .aws:  return "New terminals opened outside CTX start in this profile"
            case .gcp:  return "New terminals start here, and gcloud uses it everywhere"
            case .azure, .kubernetes:
                return "The active \(profile.provider.rawValue) selection, used everywhere"
            }
        }
        switch profile.provider {
        case .aws:
            return "Make new terminals start in this profile. Nothing disconnects."
        case .gcp:
            return "Make this active. New terminals start here and gcloud switches machine-wide. Nothing disconnects."
        case .azure, .kubernetes:
            return "Make this active. \(profile.provider.rawValue) has no per-shell switch, so every open terminal follows. Nothing disconnects."
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.selectedSelection = .profile(profile.id)
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(profile.status.color)
                        .frame(width: 6, height: 6)
                        .shadow(color: profile.status.color.opacity(0.45), radius: 3)

                    Text(profile.provider.compactName)
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(profile.provider.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(profile.provider.tint.opacity(0.12), in: Capsule())

                    Text(profile.name)
                        .font(.system(.caption, weight: .semibold))
                        .lineLimit(1)


                    if !profile.contextSubtitle.isEmpty {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(profile.contextSubtitle)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let expiresAt, expiresAt > Date() {
                        Spacer(minLength: 8)
                        SessionCountdownView(expiresAt: expiresAt, tintColor: profile.provider.tint, fontSize: 11)
                    }
                    
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Navigate to profile details")

            // Which connected profile a shell opened outside CTX comes up in. Radio
            // semantics, because exactly one of several can hold it - and choosing does
            // not disconnect the others: it only moves the recorded selection, leaving
            // every session exactly as it was.
            Button {
                store.setActive(profile, from: .mainWindow)
            } label: {
                Image(systemName: isPrimary ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(isPrimary ? profile.provider.tint : .secondary.opacity(isHovering ? 0.7 : 0.25))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(primaryHelp)
            .accessibilityLabel(isPrimary
                                ? "New terminals start in \(profile.name)"
                                : "Make new terminals start in \(profile.name)")

            Button {
                store.logout(profile, from: .mainWindow)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Disconnect active profile")
            .accessibilityLabel("Disconnect \(profile.name) from CTX")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(isHovering ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.15), lineWidth: 0.5)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}
