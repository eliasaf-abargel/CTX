import CTXCore
import SwiftUI


public struct CTXEnvironmentVariablesInspector: View {
    let items: [EnvVarItem]

    public init(items: [EnvVarItem]) {
        self.items = items
    }

    private var displayedItems: [EnvVarItem] {
        Array(items.prefix(12))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ENVIRONMENT VARIABLES (\(items.count))")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.secondary)
            if items.count > displayedItems.count {
                Text("Showing the first \(displayedItems.count) of \(items.count).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if items.contains(where: \.isSecret) {
                Text("Secret-backed variables show their source only. CTX never reads Secret values.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                Text("No explicit environment variables defined.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(displayedItems) { (item: EnvVarItem) in
                        HStack {
                            Text(item.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(displayValue(for: item))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(item.isSecret ? Color.orange : (item.value.isEmpty ? Color.secondary : Color.blue))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(displayValue(for: item))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
    }

    /// A Secret-sourced variable shows *where* it comes from and never its value —
    /// CTX does not read the Secret at all, so there is no value here to leak. A
    /// literal value in the pod spec is plaintext to anyone who can read the pod, so
    /// it is shown as declared.
    private func displayValue(for item: EnvVarItem) -> String {
        if !item.source.isEmpty { return item.source }
        return item.value.isEmpty ? KubernetesGitOpsService.unknownValue : item.value
    }
}
