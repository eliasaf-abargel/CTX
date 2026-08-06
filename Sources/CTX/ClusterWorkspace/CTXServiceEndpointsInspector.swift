import CTXCore
import SwiftUI


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
                Text("This Service has no ready backends. Nothing will answer traffic sent to it.")
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

                            if !target.address.isEmpty {
                                Text(target.address)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if !target.isHealthy {
                                Text("not ready")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.orange)
                            }

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
