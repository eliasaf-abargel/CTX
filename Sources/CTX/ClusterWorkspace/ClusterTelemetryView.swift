import CTXCore
import SwiftUI

/// Live cluster utilisation on the Overview screen.
///
/// Only values with a real data path are shown: PVC disk pressure and CFS throttling
/// would need cAdvisor scraping, so they are absent rather than faked.
///
/// All three cards render the same rows whether or not each value is known, so the
/// row never looks ragged: a card with nothing to report shows the unknown marker in
/// place of a number rather than collapsing and leaving its neighbours taller.
struct ClusterTelemetryView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    @Environment(\.overviewColumnWidth) private var availableWidth

    private var telemetry: ClusterTelemetryMetrics { viewModel.telemetry }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The scope note drops to its own line rather than sharing one it
            // does not fit on: a narrow pane used to leave it printed over the
            // section title.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CTXSectionHeader(title: "Cluster Telemetry")
                    Spacer(minLength: 8)
                    scopeNote
                }
                VStack(alignment: .leading, spacing: 3) {
                    CTXSectionHeader(title: "Cluster Telemetry")
                    scopeNote
                }
            }

            if let reason = telemetry.availability.explanation {
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Same columns as the metric cards below, so the two blocks align.
            LazyVGrid(columns: cardColumns(for: availableWidth), spacing: ClusterOverviewLayout.spacing) {
                card(
                    title: "Cluster CPU",
                    icon: "cpu",
                    color: .blue,
                    total: telemetry.allocatableCPUCores.map { String(format: "%.0f cores", $0) },
                    value: telemetry.cpuUtilizedPercent,
                    committedLabel: "Requested",
                    committed: telemetry.requestedCPUPercent,
                    peak: telemetry.peakNodeCPUPercent,
                    section: .nodes
                )
                card(
                    title: "Cluster Memory",
                    icon: "memorychip",
                    color: .purple,
                    total: telemetry.allocatableMemoryBytes.map { String(format: "%.0f GiB", $0 / 1_073_741_824) },
                    value: telemetry.memoryUtilizedPercent,
                    committedLabel: "Requested",
                    committed: telemetry.requestedMemoryPercent,
                    peak: telemetry.peakNodeMemoryPercent,
                    section: .nodes
                )
                card(
                    title: viewModel.selectedNamespace == .allNamespaces ? "Pod Capacity" : "Pods in \(viewModel.telemetryScopeLabel)",
                    icon: "shippingbox.fill",
                    color: .green,
                    total: telemetry.totalPods.map { "\($0) pods" },
                    value: telemetry.podDensityPercent,
                    committedLabel: "Nodes",
                    committedText: telemetry.totalNodes.map { "\($0)" },
                    peak: telemetry.peakNodePodPercent,
                    section: .pods
                )
            }

            if let atRiskIDs = telemetry.podsNearMemoryLimitIDs {
                memoryHeadroomPanel(atRiskIDs)
            }
        }
        // The poll runs only while this panel is on screen; `.task` cancels its
        // body on disappear, which stops it.
        .task {
            viewModel.startTelemetryUpdates()
        }
        // The pod-based figures are derived from the pod list, so they are recomputed
        // once the newly-scoped list actually lands rather than staying on the
        // previous namespace's numbers.
        .onChange(of: viewModel.selectedNamespace) { _, _ in
            viewModel.loadTelemetry(force: true)
        }
        .onChange(of: viewModel.resourceList(for: .pods)?.loadedAt) { _, _ in
            viewModel.loadTelemetry(force: true)
        }
        .onDisappear {
            viewModel.stopTelemetryUpdates()
        }
    }

    /// Node capacity and utilisation describe the cluster whatever the namespace
    /// picker says; the pod-based figures follow the picker. Stating both removes
    /// the ambiguity of a "3 pods" that could have meant either.
    private var scopeNote: some View {
        Text("Nodes cluster-wide · Pods \(viewModel.telemetryScopeLabel)")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    /// One gauge. Every row is always present so the three cards line up.
    private func card(
        title: String,
        icon: String,
        color: Color,
        /// The denominator, so a percentage means something concrete.
        total: String?,
        value: Double?,
        /// Second metric: what the scheduler has reserved, or the node count. A
        /// cluster at 3% utilisation can still be 90% committed and unable to place
        /// another pod, and utilisation alone never shows that.
        committedLabel: String,
        committed: Double? = nil,
        committedText: String? = nil,
        /// The single most loaded node, as a bare percentage — no hostname. An
        /// average of 40% with one node at 98% is about to start evicting.
        peak: Double?,
        section: ClusterWorkspaceSection
    ) -> some View {
        Button {
            viewModel.selectedSection = section
        } label: {
            CTXGlassPanel(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    // The title names the card, so it is the last thing that may
                    // give up width; the denominator beside it yields first.
                    HStack(spacing: 6) {
                        Image(systemName: icon).foregroundStyle(color)
                        Text(title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 4)
                        Text(total ?? KubernetesGitOpsService.unknownValue)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    // An unreported metric shows the unknown marker rather than a
                    // zero, which would read as "idle cluster".
                    Text(value.map { String(format: "%.1f%%", $0) } ?? KubernetesGitOpsService.unknownValue)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(value == nil ? .secondary : .primary)

                    ProgressView(value: value ?? 0, total: 100)
                        .tint(value == nil ? .secondary : color)

                    HStack(spacing: 12) {
                        metric(committedLabel, committedText ?? committed.map { String(format: "%.0f%%", $0) },
                               warn: (committed ?? 0) >= 85)
                        metric("Peak node", peak.map { String(format: "%.0f%%", $0) },
                               warn: (peak ?? 0) >= 85)
                        Spacer(minLength: 0)
                    }
                }
                // Fills its grid cell in both axes: the grid gives every cell in a
                // row the same height, but a card that hugs its content still leaves
                // a short one floating against the top of a taller neighbour.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// `fixedSize`, because a label this small has nowhere to break: "Requested"
    /// allowed to wrap comes out as "Request" over "ed".
    private func metric(_ label: String, _ value: String?, warn: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value ?? KubernetesGitOpsService.unknownValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(value == nil ? Color.secondary.opacity(0.6) : (warn ? Color.orange : Color.secondary))
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func memoryHeadroomPanel(_ atRiskIDs: [String]) -> some View {
        let atRisk = atRiskIDs.count
        return Button {
            // Opens the Pods list filtered to exactly the pods this panel counted,
            // rather than to all of them and leaving the user to find the three.
            guard atRisk > 0 else {
                viewModel.selectedSection = .pods
                return
            }
            viewModel.focus(
                ResourceFocus(
                    section: .pods,
                    title: "Using ≥90% of their declared memory limit",
                    ids: Set(atRiskIDs)
                )
            )
        } label: {
            CTXGlassPanel(padding: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: atRisk > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                        .foregroundStyle(atRisk > 0 ? .orange : .green)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Memory Limit Headroom")
                                .font(.system(size: 13, weight: .bold))
                            Text(viewModel.telemetryScopeLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(atRisk == 1 ? "1 pod" : "\(atRisk) pods")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(atRisk > 0 ? .orange : .green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((atRisk > 0 ? Color.orange : Color.green).opacity(0.12), in: Capsule())
                        }
                        Text(atRisk > 0
                             ? "Using at least 90% of their own declared memory limit. These are the pods the kernel OOM killer would reach first. Click to see them."
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
