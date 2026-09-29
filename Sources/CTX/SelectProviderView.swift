import AppKit
import CTXCore
import SwiftUI

struct SelectProviderView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let targetFolder: CloudFolder?
    let origin: ProfilePresentationSurface

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("New Profile")
                    .font(.title3.weight(.bold))
                Text("Select a cloud provider to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            VStack(spacing: 8) {
                providerButton(
                    name: "Amazon Web Services (AWS)",
                    provider: .aws
                )

                providerButton(
                    name: "Google Cloud Platform (GCP)",
                    provider: .gcp
                )

                providerButton(
                    name: "Microsoft Azure",
                    provider: .azure
                )

                providerButton(
                    name: "Kubernetes (K8s)",
                    provider: .kubernetes
                )
            }
            .padding(.top, 4)

            Divider()
                .padding(.top, 4)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
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
        provider: CloudProvider
    ) -> some View {
        Button {
            store.presentProfileEditor(
                .add(
                    provider: provider,
                    targetFolder: targetFolder?.provider == provider ? targetFolder : nil
                ),
                from: origin
            )
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
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(.caption2, weight: .bold))
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
        .focusable(false)
    }
}
