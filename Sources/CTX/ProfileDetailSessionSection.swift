import CTXCore
import SwiftUI

extension ProfileDetailView {
    var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SESSION")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(sectionHeaderStyle)
                .tracking(1.1)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                HStack {
                    Text("Connection")
                        .foregroundStyle(fieldLabelStyle)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionIsActive ? Color.green : currentProfile.status.color)
                            .frame(width: 6, height: 6)
                        Text(statusText)
                            .fontWeight(.medium)
                    }
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 38)

                // The access token behind an SSO sign-in carries a refresh token and
                // renews silently, so its hourly expiry is not a deadline anyone acts
                // on. What governs CLI access from this machine is the credentials
                // already exported for this profile, and each profile has its own -
                // one connected an hour ago has an hour less than one connected now.
                if profile.provider == .aws,
                   let expiresAt = store.sessionExpiry(for: currentProfile),
                   expiresAt > Date() {
                    Divider()
                        .padding(.leading, 16)
                    HStack {
                        Text("Access expires in")
                            .foregroundStyle(fieldLabelStyle)
                        Spacer()
                        SessionCountdownView(expiresAt: expiresAt)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 38)
                }

                Divider()
                    .padding(.leading, 16)
                HStack {
                    Text("Identity")
                        .foregroundStyle(fieldLabelStyle)
                    Spacer()
                    if connectionIsActive {
                        HStack(spacing: 6) {
                            let identityText = !profile.accountID.isEmpty
                                ? profile.accountID
                                : (!profile.roleName.isEmpty ? profile.roleName : profile.name)
                            let initials = identityText.prefix(2).uppercased()
                            Text(store.isActive(profile) ? store.activeIdentityInitials : initials)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color.accentColor)
                                .frame(width: 18, height: 18)
                                .background(Color.accentColor.opacity(0.15), in: Circle())

                            Text(store.isActive(profile) ? store.activeIdentityLabel : identityText)
                                .fontWeight(.medium)
                        }
                    } else {
                        Text("Not Active")
                            .foregroundStyle(fieldLabelStyle)
                            .fontWeight(.medium)
                    }
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 38)
            }
            .ctxGlassCard()
        }
    }
}
