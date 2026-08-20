import CTXCore
import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject var store: ProfileStore
    @AppStorage(AppAppearance.storageKey) private var appAppearanceRaw = AppAppearance.dark.rawValue

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    CTXAppLogoView(size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CTX")
                            .font(.headline)
                        Text("Cloud & Kubernetes Context Tool")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Application info") {
                LabeledContent("Name", value: "CTX")
                LabeledContent("Version", value: appVersion)
                LabeledContent("Runtime", value: "Native macOS")
                LabeledContent("Active identity", value: store.activeIdentityLabel)
                LabeledContent("Identity status", value: store.activeIdentityStatusLabel)

                if store.updateAvailable {
                    LabeledContent("New version") {
                        if store.isUpdating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Installing…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Update to \(store.latestVersionString)") {
                                store.installUpdate()
                            }
                            .buttonStyle(CTXPrimaryButton())
                        }
                    }
                } else {
                    LabeledContent("Updates") {
                        HStack(spacing: 8) {
                            if store.isCheckingForUpdates {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking…")
                                    .foregroundStyle(.secondary)
                            } else {
                                if !store.updateCheckMessage.isEmpty {
                                    Text(store.updateCheckMessage)
                                        .foregroundStyle(.secondary)
                                }

                                Button("Check for updates") {
                                    store.checkForUpdates(manual: true)
                                }
                                .buttonStyle(CTXSecondaryButton())
                            }
                        }
                    }
                }
            }

            Section("Creator") {
                LabeledContent("Name", value: Self.creatorName)
                LabeledContent("Email") {
                    if let mailto = URL(string: "mailto:\(Self.creatorEmail)") {
                        Link(Self.creatorEmail, destination: mailto)
                    } else {
                        Text(Self.creatorEmail)
                    }
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $appAppearanceRaw) {
                    ForEach(AppAppearance.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode.rawValue)
                            .help("\(mode.rawValue) theme")
                            .accessibilityLabel("\(mode.rawValue) theme")
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Theme")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            store.checkForUpdates()
        }
    }

    private static let creatorName = "Eliasaf Abargel"
    private static let creatorEmail = "eliasaf@opsbit.io"

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
