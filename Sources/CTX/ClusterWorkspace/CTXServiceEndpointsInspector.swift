import CTXCore
import SwiftUI

public struct CTXServiceEndpointsInspector: View {
    let targets: [EndpointTarget]

    public init(targets: [EndpointTarget]) {
        self.targets = targets
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("SERVICE TARGET ENDPOINTS (\(targets.count))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !targets.isEmpty {
                    let healthyCount = targets.filter(\.isHealthy).count
                    HStack(spacing: 5) {
                        Circle()
                            .fill(healthyCount == targets.count ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text("\(healthyCount)/\(targets.count) Healthy")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(healthyCount == targets.count ? Color.green : Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((healthyCount == targets.count ? Color.green : Color.orange).opacity(0.12), in: Capsule())
                }
            }

            if targets.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("No active backend endpoints")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("Ensure backend pods match the service selector and pass readiness probes, or verify if this is an external/headless service.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    ForEach(targets) { target in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(target.isHealthy ? Color.green : Color.red)
                                .frame(width: 7, height: 7)

                            Text(target.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)

                            if !target.address.isEmpty {
                                Text(target.address)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if !target.isHealthy {
                                Text("not ready")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.12), in: Capsule())
                            }

                            Text("→ :\(target.targetPort)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
    }
}
