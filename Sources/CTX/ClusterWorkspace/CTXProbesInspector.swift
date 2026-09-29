import CTXCore
import SwiftUI


public struct CTXProbesInspector: View {
    let probes: [ProbeInfo]

    public init(probes: [ProbeInfo]) {
        self.probes = probes
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HEALTH CHECKS & PROBES")
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(probes) { probe in
                    HStack(spacing: 8) {
                        Image(systemName: probe.isConfigured ? "heart.fill" : "exclamationmark.heart")
                            .font(.caption2)
                            .foregroundStyle(probe.isConfigured ? Color.green : Color.orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(probe.container.isEmpty ? "\(probe.type) Probe" : "\(probe.type) · \(probe.container)")
                                .font(.system(.caption2, weight: .semibold))
                            if probe.isConfigured {
                                Text("\(probe.target) · delay \(probe.delaySeconds)s, period \(probe.periodSeconds)s")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text("Not configured")
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
