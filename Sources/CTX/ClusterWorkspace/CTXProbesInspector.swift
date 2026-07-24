import CTXCore
import SwiftUI

public struct ProbeInfo: Equatable, Sendable {
    public let type: String // Readiness, Liveness, Startup
    public let path: String
    public let port: String
    public let delaySeconds: Int
    public let periodSeconds: Int
    public let isConfigured: Bool

    public init(type: String, path: String = "/healthz", port: String = "8080", delaySeconds: Int = 5, periodSeconds: Int = 10, isConfigured: Bool = true) {
        self.type = type
        self.path = path
        self.port = port
        self.delaySeconds = delaySeconds
        self.periodSeconds = periodSeconds
        self.isConfigured = isConfigured
    }
}

public struct CTXProbesInspector: View {
    let probes: [ProbeInfo]

    public init(probes: [ProbeInfo]) {
        self.probes = probes
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HEALTH CHECKS & PROBES")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(probes, id: \.type) { probe in
                    HStack(spacing: 8) {
                        Image(systemName: probe.isConfigured ? "heart.fill" : "exclamationmark.heart")
                            .font(.system(size: 11))
                            .foregroundStyle(probe.isConfigured ? Color.green : Color.orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(probe.type) Probe")
                                .font(.system(size: 10, weight: .semibold))
                            if probe.isConfigured {
                                Text("HTTP \(probe.path) :\(probe.port) · delay \(probe.delaySeconds)s, period \(probe.periodSeconds)s")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not configured for this container")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }
}
