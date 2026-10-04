import CTXCore
import SwiftUI

extension ProfileDetailView {
    @ViewBuilder
    var connectionIssueSection: some View {
        if store.isManuallyDisconnected(profile) {
            if let message = store.verificationErrors[profile.id] {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if profile.provider == .kubernetes
            && (currentProfile.status == .needsLogin || store.verificationErrors[profile.id] != nil) {
            let errorMessage = store.verificationErrors[profile.id]
            KubeAuthRemediationCardView(
                profile: currentProfile,
                errorMessage: errorMessage,
                onConnect: {
                    store.login(currentProfile, from: .mainWindow)
                },
                onRunTerminal: { command in
                    triggerTerminalCommand(command)
                }
            )
        } else if let errorMessage = store.verificationErrors[profile.id] {
            if errorMessage.lowercased().contains("sso")
                || errorMessage.lowercased().contains("exec code 255") {
                let awsProfileName = extractAWSProfileName(from: errorMessage, profile: profile)
                let loginCommand = "aws sso login --profile \(awsProfileName)"

                AWSSSOLoginCardView(
                    profileName: awsProfileName,
                    loginCmd: loginCommand
                ) {
                    triggerTerminalCommand(loginCommand)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Connection Issue")
                            .font(.system(.footnote, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                }
            }
        }
    }
}
