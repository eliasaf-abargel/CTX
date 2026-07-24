import CTXCore
import SwiftUI

public struct EndpointTarget: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let namespace: String
    public let targetPort: String
    public let isHealthy: Bool

    public init(name: String, namespace: String, targetPort: String = "8080", isHealthy: Bool = true) {
        self.name = name
        self.namespace = namespace
        self.targetPort = targetPort
        self.isHealthy = isHealthy
    }
}

public struct CTXServiceEndpointsInspector: View {
    let targets: [EndpointTarget]

    public init(targets: [EndpointTarget]) {
        self.targets = targets
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SERVICE TARGET ENDPOINTS (\(targets.count))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                let healthyCount = targets.filter(\.isHealthy).count
                Text("\(healthyCount)/\(targets.count) Healthy")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(healthyCount == targets.count ? Color.green : Color.orange)
            }

            if targets.isEmpty {
                Text("No active target endpoints attached to this Service selector.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(targets) { target in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(target.isHealthy ? Color.green : Color.red)
                                .frame(width: 6, height: 6)

                            Text(target.name)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)

                            Spacer()

                            Text("→ :\(target.targetPort)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
        }
    }
}
