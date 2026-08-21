import CTXCore
import SwiftUI

/// Confirmation for deleting a profile, with the per-provider explanation of what
/// is actually removed from disk.
///
/// Attached by both the sidebar and the profile detail screen, which each carried a
/// verbatim copy — the provider switch, the four messages, and the async Kubernetes
/// branch. Two copies of a destructive confirmation is exactly the wrong thing to
/// duplicate: they can drift, and the one that drifts is telling the user something
/// untrue about what is about to be deleted.
struct DeleteProfileAlert: ViewModifier {
    @ObservedObject var store: ProfileStore
    @Binding var candidate: CloudProfile?

    func body(content: Content) -> some View {
        content.alert(
            "Delete \(candidate?.name ?? "profile")?",
            isPresented: Binding(
                get: { candidate != nil },
                set: { if !$0 { candidate = nil } }
            ),
            presenting: candidate
        ) { profile in
            Button("Delete", role: .destructive) {
                delete(profile)
                candidate = nil
            }
            Button("Cancel", role: .cancel) { candidate = nil }
        } message: { profile in
            Text(Self.explanation(for: profile))
        }
    }

    private func delete(_ profile: CloudProfile) {
        do {
            switch profile.provider {
            case .aws:
                try store.deleteAWSProfile(profile)
            case .gcp:
                try store.deleteGCPProfile(profile)
            case .azure:
                try store.deleteAzureProfile(profile)
            case .kubernetes:
                Task {
                    do {
                        try await store.deleteKubeContext(profile)
                    } catch {
                        store.report(error.localizedDescription, from: .mainWindow)
                    }
                }
            }
        } catch {
            store.report(error.localizedDescription, from: .mainWindow)
        }
    }

    static func explanation(for profile: CloudProfile) -> String {
        switch profile.provider {
        case .aws:
            "CTX will remove this AWS profile and its matching SSO session from ~/.aws/config after creating a backup."
        case .gcp:
            "CTX will permanently delete the gcloud configuration file config_\(profile.name) from ~/.config/gcloud/configurations/."
        case .azure:
            "CTX will permanently delete the Azure profile JSON file config_\(profile.name).json from ~/.config/ctx/azure/."
        case .kubernetes:
            "CTX will delete the context \(profile.name) from your ~/.kube/config configuration file."
        }
    }
}

extension View {
    func deleteProfileAlert(store: ProfileStore, candidate: Binding<CloudProfile?>) -> some View {
        modifier(DeleteProfileAlert(store: store, candidate: candidate))
    }
}
