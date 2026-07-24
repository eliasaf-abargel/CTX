import CTXCore
import SwiftUI

public struct EnvVarItem: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let value: String
    public let isSecret: Bool

    public init(name: String, value: String, isSecret: Bool = false) {
        self.name = name
        self.value = value
        self.isSecret = isSecret
    }
}

public struct CTXEnvironmentVariablesInspector: View {
    let items: [EnvVarItem]

    public init(items: [EnvVarItem]) {
        self.items = items
    }

    private var displayedItems: [EnvVarItem] {
        Array(items.prefix(8))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ENVIRONMENT VARIABLES (\(items.count))")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)

            if items.isEmpty {
                Text("No explicit environment variables defined.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(displayedItems, id: \.name) { (item: EnvVarItem) in
                        HStack {
                            Text(item.name)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(displayValue(for: item))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(item.isSecret ? Color.secondary : Color.blue)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
        }
    }

    private func displayValue(for item: EnvVarItem) -> String {
        if item.isSecret || isSensitiveKey(item.name) {
            return "••••••••"
        }
        return item.value
    }

    private func isSensitiveKey(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("KEY") || upper.contains("SECRET") || upper.contains("PASSWORD") || upper.contains("TOKEN") || upper.contains("AUTH") || upper.contains("CREDENTIAL")
    }
}
