import CTXCore
import SwiftUI

/// Shown right after a profile/context is created without a folder selected
/// (e.g. via the sidebar's global "+" button), so it doesn't just land silently
/// in the generic default folder.
struct ChooseFolderPromptView: View {
    @ObservedObject var store: ProfileStore
    let profile: CloudProfile
    let onDone: () -> Void

    private var folders: [CloudFolder] {
        store.allFolders
            .filter { $0.provider == profile.provider }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a Folder")
                    .font(.title2.weight(.semibold))
                Text("\"\(profile.name)\" was created but isn't in a folder yet. Pick one, or skip for now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if folders.isEmpty {
                Text("No folders available for \(profile.provider.rawValue) — hidden or none created yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(folders) { folder in
                            Button {
                                store.move(profile, to: folder)
                                onDone()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: folder.icon.systemImage)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 18)
                                    Text(folder.name)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 240)
            }

            HStack {
                Spacer()
                Button("Skip") {
                    onDone()
                }
                .buttonStyle(CTXSecondaryButton())
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
