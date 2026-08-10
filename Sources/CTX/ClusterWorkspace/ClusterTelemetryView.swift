import CTXCore
import SwiftUI

/// Live cluster utilisation on the Overview screen.
///
/// Every number here previously came from a struct of hardcoded defaults — 34.2% CPU,
/// 61.8% memory, 8 nodes, 114 pods, 2 pods at OOM risk — printed identically for every
/// cluster. Two of the original panels (PVC disk pressure and CFS throttling) had no
/// data path at all short of scraping cAdvisor, so they are gone rather than faked.
struct ClusterTelemetryView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    private var telemetry: ClusterTelemetryMetrics { viewModel.telemetry }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CTXSectionHeader(title: "Cluster Telemetry")

            if let reason = telemetry.availability.explanation {
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                gaugeButton(
                    title: "Cluster CPU",
                    value: telemetry.cpuUtilizedPercent,
                    committed: telemetry.requestedCPUPercent,
                    total: telemetry.allocatableCPUCores.map { String(format: "%.0f cores", $0) },
                    peak: telemetry.busiestNodeByCPU.map { ($0.name, $0.cpuPercent) },
                    icon: "cpu",
                    color: .blue,
                    section: .nodes
                )
                gaugeButton(
                    title: "Cluster Memory",
                    value: telemetry.memoryUtilizedPercent,
                    committed: telemetry.requestedMemoryPercent,
                    total: telemetry.allocatableMemoryBytes.map { String(format: "%.0f GiB", $0 / 1_073_741_824) },
                    peak: telemetry.busiestNodeByMemory.map { ($0.name, $0.memoryPercent) },
                    icon: "memorychip",
                    color: .purple,
                    section: .nodes
                )
                gaugeButton(
                    title: "Pod Capacity Used",
                    value: telemetry.podDensityPercent,
                    committed: nil,
                    total: telemetry.totalPods.map { "\($0) pods" },
                    peak: nil,
                    icon: "shippingbox.fill",
                    color: .green,
                    section: .pods
                )
            }

            if let atRisk = telemetry.podsNearMemoryLimit {
                Button {
                    viewModel.selectedSection = .pods
                } label: {
                    CTXGlassPanel(padding: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: atRisk > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                                .foregroundStyle(atRisk > 0 ? .orange : .green)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Memory Limit Headroom")
                                        .font(.system(size: 13, weight: .bold))
                                    Spacer()
                                    Text(atRisk == 1 ? "1 pod" : "\(atRisk) pods")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(atRisk > 0 ? .orange : .green)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background((atRisk > 0 ? Color.orange : Color.green).opacity(0.12), in: Capsule())
                                }
                                Text(atRisk > 0
                                     ? "Using at least 90% of their own declared memory limit. These are the pods the kernel OOM killer would reach first."
                                     : "No pod is close to its declared memory limit. Pods without a limit are not counted — they have no threshold to cross.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        // The poll runs only while this panel is on screen; `.task` cancels its
        // body on disappear, which stops it.
        .task {
            viewModel.startTelemetryUpdates()
        }
        .onDisappear {
            viewModel.stopTelemetryUpdates()
        }
    }

    private func gaugeButton(
        title: String,
        value: Double?,
        /// What the scheduler has reserved. A cluster at 3% utilisation can still be
        /// 90% committed and unable to place another pod — utilisation alone never
        /// shows that, and it is the number that actually blocks a deploy.
        committed: Double?,
        /// The denominator, so a percentage means something concrete.
        total: String?,
        /// The single busiest node. A cluster averaging 40% with one node at 98% is
        /// about to start evicting, and the average alone never says so.
        peak: (name: String, percent: Double?)?,
        icon: String,
        color: Color,
        section: ClusterWorkspaceSection
    ) -> some View {
        Button {
            viewModel.selectedSection = section
        } label: {
            CTXGlassPanel(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: icon).foregroundStyle(color)
                        Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Spacer()
                        if let total {
                            Text(total)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // An unreported metric shows the unknown marker rather than a
                    // zero, which would read as "idle cluster".
                    Text(value.map { String(format: "%.1f%%", $0) } ?? KubernetesGitOpsService.unknownValue)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(value == nil ? .secondary : .primary)

                    ProgressView(value: value ?? 0, total: 100)
                        .tint(value == nil ? .secondary : color)

                    if let committed {
                        HStack(spacing: 4) {
                            Text("Requested")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f%%", committed))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(committed >= 85 ? Color.orange : Color.secondary)
                            Spacer()
                        }
                    }

                    if let peak, let percent = peak.percent {
                        Text("Busiest: \(peak.name) at \(String(format: "%.0f%%", percent))")
                            .font(.system(size: 10))
                            .foregroundStyle(percent >= 85 ? Color.orange : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("\(peak.name) — \(String(format: "%.1f%%", percent))")
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(value == nil)
    }
}
