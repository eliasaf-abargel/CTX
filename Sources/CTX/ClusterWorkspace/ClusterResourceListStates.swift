import CTXCore
import SwiftUI

/// A slow read (a real auth-plugin round trip can take longer than a plain list
/// call) shouldn't read as "stuck" — after 3s, the message softens to say so
/// explicitly, without cancelling or restarting anything; the underlying fetch
/// keeps running against its own timeout exactly as before.
struct ResourceSkeletonView: View {
    let title: String
    @State private var stillLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CTXLoadingStateView(
                title: title,
                message: stillLoading ? "Still loading — this can take longer on some clusters." : "Loading inspection data."
            )
            .task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                stillLoading = true
            }
            VStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.secondary.opacity(0.16))
                            .frame(width: 140, height: 12)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.secondary.opacity(0.11))
                            .frame(width: 90, height: 12)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.secondary.opacity(0.09))
                            .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12)
                    }
                }
            }
        }
    }
}

struct ResourceIssuePanel: View {
    let section: ClusterWorkspaceSection
    let list: KubernetesResourceList
    let retry: () -> Void

    private var presentation: (title: String, message: String, systemImage: String) {
        if let diagnostic = list.diagnostic {
            return diagnostic.category.presentation
        }
        return (list.status.cardValue, list.status.cardSubtitle, "exclamationmark.triangle")
    }

    var body: some View {
        CTXDiagnosticCard(
            systemImage: presentation.systemImage,
            tint: list.status.tint,
            title: "\(section.rawValue) \(presentation.title.lowercased())",
            message: presentation.message,
            diagnosticSummary: list.diagnostic?.safeSummary,
            retry: retry
        )
    }
}
