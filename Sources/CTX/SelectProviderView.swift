import AppKit
import CTXCore
import SwiftUI

struct SelectProviderView: View {
    @Binding var sheet: SidebarSheet?

    var body: some View {
        VStack(spacing: 16) {
            // Header
            VStack(spacing: 4) {
                Text("New Profile")
                    .font(.title3.weight(.bold))
                Text("Select a cloud provider to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            // List of Providers
            VStack(spacing: 8) {
                providerButton(
                    name: "Amazon Web Services (AWS)",
                    provider: .aws,
                    target: .addAWSProfile
                )

                providerButton(
                    name: "Google Cloud Platform (GCP)",
                    provider: .gcp,
                    target: .addGCPProfile
                )

                providerButton(
                    name: "Microsoft Azure",
                    provider: .azure,
                    target: .addAzureProfile
                )

                providerButton(
                    name: "Kubernetes (K8s)",
                    provider: .kubernetes,
                    target: .addKubeContext
                )
            }
            .padding(.top, 4)

            Divider()
                .padding(.top, 4)

            HStack {
                Spacer()
                Button("Cancel") {
                    sheet = nil
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func providerButton(
        name: String,
        provider: CloudProvider,
        target: SidebarSheet
    ) -> some View {
        Button {
            sheet = nil
            // Prevent sheet collision by presenting on next runloop cycle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                sheet = target
            }
        } label: {
            HStack(spacing: 12) {
                ProviderIcon(
                    provider: provider,
                    size: 16,
                    fallbackTint: provider.tint
                )
                .frame(width: 26, height: 26)
                .background(provider.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.12), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .focusable(false) // Prevents the blue focus ring glitch!
    }
}
