import CTXCore
import SwiftUI

struct ClusterTelemetryView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    @State private var telemetry = KubernetesTelemetryService.fetchTelemetry()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CTXSectionHeader(title: "Cluster Telemetry")

            HStack(spacing: 12) {
                Button {
                    viewModel.selectedSection = .nodes
                } label: {
                    gaugeCard(title: "Node CPU Pressure", value: telemetry.cpuUtilizedPercent, icon: "cpu", color: .blue)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.selectedSection = .nodes
                } label: {
                    gaugeCard(title: "Memory Utilization", value: telemetry.memoryUtilizedPercent, icon: "memorychip", color: .purple)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.selectedSection = .pods
                } label: {
                    gaugeCard(title: "Pod Capacity Headroom", value: telemetry.podDensityPercent, icon: "shippingbox.fill", color: .green)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.selectedSection = .workloads
                } label: {
                    gaugeCard(title: "PVC Disk Pressure", value: telemetry.pvcDiskUtilizedPercent, icon: "internaldrive.fill", color: .orange)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.selectedSection = .pods
                } label: {
                    CTXGlassPanel(padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                                Text("OOMKilled Risk Alerts").font(.system(size: 13, weight: .bold))
                                Spacer()
                                Text("\(telemetry.oomKilledRiskCount) Pods")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.12), in: Capsule())
                            }
                            Text("Pods operating at >90% of memory limit. Risk of kernel OOM killer termination.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.selectedSection = .pods
                } label: {
                    CTXGlassPanel(padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "gauge.with.dots.needle.bottom.14percent").foregroundStyle(.blue)
                                Text("CPU Throttling").font(.system(size: 13, weight: .bold))
                                Spacer()
                                Text("\(telemetry.oomKilledRiskCount) Pods")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.12), in: Capsule())
                            }
                            Text("Pods experiencing CFS quota throttling. Consider raising CPU limit.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func gaugeCard(title: String, value: Double, icon: String, color: Color) -> some View {
        CTXGlassPanel(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                Text(String(format: "%.1f%%", value))
                    .font(.system(size: 20, weight: .bold, design: .rounded))

                ProgressView(value: value, total: 100.0)
                    .tint(color)
            }
        }
    }
}
