import CTXCore
import SwiftUI

struct KubeAuthRemediationCardView: View {
    let profile: CloudProfile
    let errorMessage: String?
    let onConnect: () -> Void
    let onRunTerminal: (String) -> Void

    private var isVerifying: Bool { profile.status.isBusy }

    private var isSDM: Bool { profile.usesStrongDM }
    private var isTeleport: Bool { profile.usesTeleport }
    private var isAWSSSO: Bool {
        profile.name.lowercased().contains("aws")
            || profile.roleName.lowercased().contains("aws")
            || (errorMessage?.lowercased().contains("sso") ?? false)
    }

    private var authTitle: String {
        if isSDM { return "StrongDM Authentication Required" }
        if isTeleport { return "Teleport (tsh) Login Required" }
        if isAWSSSO { return "AWS SSO Authentication Required" }
        return "Kubernetes Identity Authentication Required"
    }

    private var authExplanation: String {
        if isSDM {
            return "Connect uses your existing StrongDM client, completes sign-in, and verifies access to this cluster."
        }
        if isTeleport {
            return "This cluster is managed via Teleport. Run tsh login to renew your access certificate."
        }
        if isAWSSSO {
            return "EKS cluster access requires an active AWS SSO session. Re-authenticate to access cluster resources."
        }
        return "Kubernetes credential plugin requires Single Sign-On (Okta / SAML) authentication to generate an access token."
    }

    private var commandSnippet: String {
        if isSDM { return "sdm connect \(profile.name)" }
        if isTeleport { return "tsh kube login \(profile.name)" }
        if isAWSSSO { return "aws sso login --profile \(profile.name)" }
        return "kubectl get --raw=/version --context \(profile.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(
                    systemName: isSDM
                        ? "network.badge.shield.half.filled"
                        : (isTeleport ? "lock.shield.fill" : "key.fill")
                )
                .foregroundStyle(.orange)
                .font(.system(size: 15))
                Text(authTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
            }

            Text(authExplanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(commandSnippet)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                CTXCopyIconButton(value: commandSnippet)
            }
            .padding(8)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 10) {
                Button(action: onConnect) {
                    Label(isVerifying ? "Connecting..." : "Connect with Provider", systemImage: "arrow.clockwise")
                }
                .buttonStyle(CTXPrimaryButton())
                .disabled(isVerifying)

                Button {
                    onRunTerminal(commandSnippet)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal.fill")
                }
                .buttonStyle(CTXSecondaryButton())
                .disabled(isVerifying)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        }
    }
}

struct AWSSSOLoginCardView: View {
    let profileName: String
    let loginCmd: String
    let onRunTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.orange)
                Text("AWS SSO Authentication Required")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
            }
            Text("Your AWS SSO token for profile '\(profileName)' has expired or is missing. Run SSO login to authenticate.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                Text(loginCmd)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                CTXCopyIconButton(value: loginCmd)
            }
            .padding(8)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

            Button {
                onRunTerminal()
            } label: {
                Label("Run AWS SSO Login in Terminal", systemImage: "terminal.fill")
            }
            .buttonStyle(CTXPrimaryButton())
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        }
    }
}
