import CTXCore
import SwiftUI

/// What a YAML apply and a workload lifecycle action have in common: did it
/// work, a short message either way, and whatever detail explains a failure
/// or confirms a success. One banner rendering for both instead of two
/// near-identical `HStack`s that could drift.
protocol CTXOutcomeBannerDisplayable {
    var success: Bool { get }
    var message: String { get }
    var errorDetails: String? { get }
    var stdout: String { get }
}

extension KubernetesApplyResult: CTXOutcomeBannerDisplayable {}
extension KubernetesLifecycleActionResult: CTXOutcomeBannerDisplayable {}

struct CTXOutcomeBanner: View {
    let result: CTXOutcomeBannerDisplayable
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        let isSuccess = result.success
        let bgTint: Color = isSuccess ? .green : .red
        let icon: String = isSuccess ? "checkmark.circle.fill" : "exclamationmark.octagon.fill"

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(bgTint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                if let err = result.errorDetails, !err.isEmpty {
                    Text(err)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if !result.stdout.isEmpty {
                    Text(result.stdout)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(bgTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(bgTint.opacity(0.25), lineWidth: 1)
        )
    }
}
