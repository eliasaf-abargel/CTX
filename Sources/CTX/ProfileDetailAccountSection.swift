import CTXCore
import SwiftUI

extension ProfileDetailView {
    var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACCOUNT")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(sectionHeaderStyle)
                .tracking(1.1)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                HStack {
                    Text(profile.accountLabel)
                        .foregroundStyle(fieldLabelStyle)
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

                if !profile.region.isEmpty {
                    Divider()
                        .padding(.leading, 16)
                    HStack {
                        Text(profile.regionLabel)
                            .foregroundStyle(fieldLabelStyle)
                        Spacer()
                        Text(profile.region)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 38)
                }

                if !profile.roleName.isEmpty || profile.provider == .aws {
                    Divider()
                        .padding(.leading, 16)
                    HStack {
                        Text(profile.roleLabel)
                            .foregroundStyle(fieldLabelStyle)
                        Spacer()

                        if availableRoles.count > 1 {
                            AWSRoleMenu(roles: availableRoles, currentRole: profile.roleName) { newRole in
                                roleUpdateError = store.updateAWSRole(
                                    for: profile,
                                    roleName: newRole,
                                    targetFolder: store.folder(for: profile),
                                    from: .mainWindow
                                ) ?? ""
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(profile.roleName.isEmpty ? "-" : profile.roleName)
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.medium)
                                    .textSelection(.enabled)
                                if !profile.roleName.isEmpty {
                                    copyButton(for: profile.roleName, fieldName: "role")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 38)
                }

                if profile.provider == .aws && !profile.ssoStartURL.isEmpty {
                    Divider()
                        .padding(.leading, 16)
                    HStack {
                        Text("SSO Start URL")
                            .foregroundStyle(fieldLabelStyle)
                        Spacer()
                        Text(profile.ssoStartURL)
                            .lineLimit(1)
                            .fontWeight(.medium)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 38)
                }

                if profile.provider == .aws && !profile.ssoRegion.isEmpty {
                    Divider()
                        .padding(.leading, 16)
                    HStack {
                        Text("SSO Region")
                            .foregroundStyle(fieldLabelStyle)
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

            if !roleUpdateError.isEmpty {
                Label(roleUpdateError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Role update failed: \(roleUpdateError)")
            }
        }
    }
}
