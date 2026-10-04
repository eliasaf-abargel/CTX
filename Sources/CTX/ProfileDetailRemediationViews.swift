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
            || profile.kubernetesLinkedProfile != nil
            || (errorMessage?.lowercased().contains("sso") ?? false)
    }

    private var awsProfileName: String {
        if let linked = profile.kubernetesLinkedProfile, !linked.isEmpty {
            return linked
        }
        return profile.name
    }

    private var isAWSRBACDenied: Bool {
        guard let error = errorMessage?.lowercased() else { return false }
        return error.contains("unauthorized") || error.contains("must be logged in")
    }

    private var isSDMAppInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return FileManager.default.fileExists(atPath: "/Applications/SDM.app")
            || FileManager.default.fileExists(atPath: "\(home)/Applications/SDM.app")
    }

    private var authTitle: String {
        if isSDM { return "StrongDM Authentication Required" }
        if isTeleport { return "Teleport (tsh) Login Required" }
        if isAWSSSO { return "AWS SSO Authentication Required" }
        return "Kubernetes Identity Authentication Required"
    }

    private var authExplanation: String {
        if isSDM {
            return "This cluster connects via StrongDM on localhost. Open the StrongDM desktop app to activate your cluster tunnel, or click Connect."
        }
        if isTeleport {
            return "This cluster is managed via Teleport. Run tsh login to renew your access certificate."
        }
        if isAWSSSO {
            if isAWSRBACDenied {
                return "AWS IAM credentials were authenticated, but this EKS cluster's Access Entries or aws-auth ConfigMap did not recognize the identity. Verify cluster RBAC permissions or check if this cluster requires StrongDM access."
            }
            return "EKS cluster access requires an active AWS SSO session for '\(awsProfileName)'. Re-authenticate to access cluster resources."
        }
        return "Kubernetes credential plugin requires Single Sign-On (Okta / SAML) authentication to generate an access token."
    }

    private var commandSnippet: String {
        if isSDM { return "sdm connect \(profile.name)" }
        if isTeleport { return "tsh kube login \(profile.name)" }
        if isAWSSSO { return "aws sso login --profile \(awsProfileName)" }
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
                .font(.callout)
                Text(authTitle)
                    .font(.system(.footnote, weight: .bold))
                    .foregroundStyle(.primary)
            }

            Text(authExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(commandSnippet)
                    .font(.system(.caption2, design: .monospaced))
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

                if isSDM {
                    if isSDMAppInstalled {
                        Button {
                            let home = FileManager.default.homeDirectoryForCurrentUser.path
                            let path = FileManager.default.fileExists(atPath: "/Applications/SDM.app")
                                ? "/Applications/SDM.app"
                                : "\(home)/Applications/SDM.app"
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        } label: {
                            Label("Open StrongDM App", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(CTXSecondaryButton())
                    } else {
                        Button {
                            NSWorkspace.shared.open(CLITool.sdm.downloadPage)
                        } label: {
                            Label("Install StrongDM", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(CTXSecondaryButton())
                    }
                } else if isTeleport && CLIToolPaths.resolve("tsh") == nil {
                    Button {
                        NSWorkspace.shared.open(CLITool.tsh.downloadPage)
                    } label: {
                        Label("Install Teleport (tsh)", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(CTXSecondaryButton())
                }

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
                    .font(.system(.footnote, weight: .bold))
                    .foregroundStyle(.primary)
            }
            Text("Your AWS SSO token for profile '\(profileName)' has expired or is missing. Run SSO login to authenticate.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(loginCmd)
                    .font(.system(.caption2, design: .monospaced))
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
