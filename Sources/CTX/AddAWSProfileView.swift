import CTXCore
import SwiftUI

enum AWSProfileEditorMode {
    case create
    case edit(CloudProfile)
    case duplicate(CloudProfile)

    var title: String {
        switch self {
        case .create:
            "Add AWS SSO Profile"
        case .edit:
            "Edit AWS SSO Profile"
        case .duplicate:
            "Duplicate AWS SSO Profile"
        }
    }

    var actionTitle: String {
        switch self {
        case .create:
            "Create"
        case .edit:
            "Save"
        case .duplicate:
            "Duplicate"
        }
    }

    var draft: AWSProfileDraft {
        switch self {
        case .create:
            AWSProfileDraft()
        case .edit(let profile):
            AWSProfileDraft(profile: profile)
        case .duplicate(let profile):
            AWSProfileDraft(profile: profile, duplicate: true)
        }
    }
}

struct AddAWSProfileView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let mode: AWSProfileEditorMode
    @State private var draft: AWSProfileDraft
    @State private var errorMessage = ""
    @State private var ssoRegionSelection = ""
    @State private var customSSORegion = ""
    @State private var defaultRegionSelection = ""
    @State private var customDefaultRegion = ""

    init(store: ProfileStore, mode: AWSProfileEditorMode = .create) {
        self.store = store
        self.mode = mode
        self._draft = State(initialValue: mode.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title)
                    .font(.title2.weight(.semibold))
                Text("Configure AWS SSO settings saved to your local ~/.aws/config configuration.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Divider()

            Form {
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
            .frame(height: 380)

            // Error banner
            if !errorMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            // Footer Actions
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button(mode.actionTitle) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            // SSO Region Initialization
            if draft.ssoRegion.isEmpty {
                ssoRegionSelection = ""
            } else if AWSRegion.allCases.contains(where: { $0.id == draft.ssoRegion }) {
                ssoRegionSelection = draft.ssoRegion
            } else {
                ssoRegionSelection = "custom"
                customSSORegion = draft.ssoRegion
            }
            
            // Default Region Initialization
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
                try store.addAWSProfile(draft)
            case .edit(let profile):
                try store.updateAWSProfile(profile, draft: draft)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }}
