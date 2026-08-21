import CTXCore
import SwiftUI

typealias AWSProfileEditorMode = ProfileEditorMode

extension ProfileEditorMode {
    /// The draft this editor starts from: empty for a new profile, a copy of the
    /// existing one for an edit, and a renamed copy for a duplicate.
    var aWSProfileDraft: AWSProfileDraft {
        switch self {
        case .create: AWSProfileDraft()
        case .edit(let profile): AWSProfileDraft(profile: profile)
        case .duplicate(let profile): AWSProfileDraft(profile: profile, duplicate: true)
        }
    }
}

struct AddAWSProfileView: View {
    @ObservedObject var store: ProfileStore
    let origin: ProfilePresentationSurface
    @Environment(\.dismiss) private var dismiss
    let mode: AWSProfileEditorMode
    let targetFolder: CloudFolder?
    @State private var selectedFolder: CloudFolder?
    @State private var draft: AWSProfileDraft
    @State private var errorMessage = ""
    @State private var ssoRegionSelection = ""
    @State private var customSSORegion = ""
    @State private var defaultRegionSelection = ""
    @State private var customDefaultRegion = ""

    init(
        store: ProfileStore,
        mode: AWSProfileEditorMode = .create,
        targetFolder: CloudFolder? = nil,
        origin: ProfilePresentationSurface = .mainWindow
    ) {
        self.store = store
        self.origin = origin
        self.mode = mode
        self.targetFolder = targetFolder
        self._draft = State(initialValue: mode.aWSProfileDraft)
        let awsFolders = store.folders(for: .aws)
        self._selectedFolder = State(initialValue: targetFolder ?? awsFolders.first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title(noun: "AWS Profile"))
                    .font(.title2.weight(.semibold))
                Text("Configure an AWS SSO profile in ~/.aws/config.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Divider()

            Form {
                Section("Organization & Folder") {
                    Picker("Folder / Environment:", selection: $selectedFolder) {
                        ForEach(store.folders(for: .aws)) { folder in
                            Label(folder.name, systemImage: folder.icon.systemImage)
                                .tag(Optional(folder))
                        }
                    }
                }

                Section("Profile Identity") {
                    TextField("Profile Name:", text: $draft.name, prompt: Text("e.g. dev-sso"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Account ID:", text: $draft.accountID, prompt: Text("12-digit account number"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Role Name:", text: $draft.roleName, prompt: Text("e.g. AWSAdministratorAccess"))
                        .textFieldStyle(.roundedBorder)
                }
                
                Section("SSO Credentials & Region") {
                    TextField("SSO Start URL:", text: $draft.ssoStartURL, prompt: Text("https://my-sso.awsapps.com/start"))
                        .textFieldStyle(.roundedBorder)
                    
                    LabeledContent("SSO Region:") {
                        Menu {
                            ForEach(AWSRegionGroup.allCases) { group in
                                Menu(group.rawValue) {
                                    ForEach(group.regions) { region in
                                        Button(region.displayName) {
                                            ssoRegionSelection = region.id
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Other (Custom Region)...") {
                                ssoRegionSelection = "custom"
                            }
                        } label: {
                            HStack {
                                Text(ssoRegionSelection.isEmpty ? "Select Region..." : (AWSRegion.allCases.first(where: { $0.id == ssoRegionSelection })?.displayName ?? ssoRegionSelection))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                    
                    if ssoRegionSelection == "custom" {
                        TextField("Custom SSO Region:", text: $customSSORegion, prompt: Text("e.g. us-east-1"))
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    LabeledContent("Default Region:") {
                        Menu {
                            ForEach(AWSRegionGroup.allCases) { group in
                                Menu(group.rawValue) {
                                    ForEach(group.regions) { region in
                                        Button(region.displayName) {
                                            defaultRegionSelection = region.id
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Other (Custom Region)...") {
                                defaultRegionSelection = "custom"
                            }
                        } label: {
                            HStack {
                                Text(defaultRegionSelection.isEmpty ? "Select Region..." : (AWSRegion.allCases.first(where: { $0.id == defaultRegionSelection })?.displayName ?? defaultRegionSelection))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                    
                    if defaultRegionSelection == "custom" {
                        TextField("Custom Default Region:", text: $customDefaultRegion, prompt: Text("e.g. us-west-2"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 380)

            ProfileEditorErrorBanner(message: errorMessage)

            ProfileEditorFooter(
                actionTitle: mode.actionTitle,
                cancel: { dismiss() },
                confirm: { save() }
            )
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            if draft.ssoRegion.isEmpty {
                ssoRegionSelection = ""
            } else if AWSRegion.allCases.contains(where: { $0.id == draft.ssoRegion }) {
                ssoRegionSelection = draft.ssoRegion
            } else {
                ssoRegionSelection = "custom"
                customSSORegion = draft.ssoRegion
            }
            
            if draft.defaultRegion.isEmpty {
                defaultRegionSelection = ""
            } else if AWSRegion.allCases.contains(where: { $0.id == draft.defaultRegion }) {
                defaultRegionSelection = draft.defaultRegion
            } else {
                defaultRegionSelection = "custom"
                customDefaultRegion = draft.defaultRegion
            }
        }
        .onChange(of: ssoRegionSelection) { oldValue, newValue in
            if newValue == "custom" {
                draft.ssoRegion = customSSORegion
            } else {
                draft.ssoRegion = newValue
            }
        }
        .onChange(of: customSSORegion) { oldValue, newValue in
            if ssoRegionSelection == "custom" {
                draft.ssoRegion = newValue
            }
        }
        .onChange(of: defaultRegionSelection) { oldValue, newValue in
            if newValue == "custom" {
                draft.defaultRegion = customDefaultRegion
            } else {
                draft.defaultRegion = newValue
            }
        }
        .onChange(of: customDefaultRegion) { oldValue, newValue in
            if defaultRegionSelection == "custom" {
                draft.defaultRegion = newValue
            }
        }
    }

    private func save() {
        do {
            switch mode {
            case .create, .duplicate:
                try store.addAWSProfile(draft, targetFolder: selectedFolder, from: origin)
            case .edit(let profile):
                try store.updateAWSProfile(profile, draft: draft, targetFolder: selectedFolder, from: origin)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
