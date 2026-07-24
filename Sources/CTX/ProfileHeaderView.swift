import CTXCore
import SwiftUI

struct ProfileHeaderView: View {
    let profile: CloudProfile
    let currentProfile: CloudProfile
    let isActive: Bool
    let canOpenWorkspace: Bool
    let kubernetesContext: KubernetesContextProfile?
    let openWorkspace: (String) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ProviderIcon(
                provider: profile.provider,
                size: 34,
                fallbackTint: isActive ? Color.accentColor : currentProfile.status.color
            )
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)

                    if isActive && profile.status == .connected {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                }

                let env = CloudEnvironment.infer(from: profile).rawValue
                let typeSuffix = profile.provider == .aws ? "SSO" : (profile.provider == .gcp ? "Config" : (profile.provider == .kubernetes ? "Context" : "Subscription"))
                Text("\(profile.provider.rawValue) · \(env) · \(typeSuffix)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if canOpenWorkspace, let context = kubernetesContext {
                Button {
                    openWorkspace(context.id)
                } label: {
                    Label("Open Workspace", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(.accentColor)
                .help("Open native Cluster Workspace for this Kubernetes context")
            }
        }
    }
}
