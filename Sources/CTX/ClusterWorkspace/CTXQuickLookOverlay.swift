import CTXCore
import SwiftUI

/// Apple-Native Spacebar Quick Look Overlay for Kubernetes Resources.
/// Mimics macOS Finder Spacebar Quick Look with instant spec preview,
/// health indicators, and action triggers without leaving the current view.
struct CTXQuickLookOverlay: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let row: KubernetesResourceRow
    let section: ClusterWorkspaceSection

    @Environment(\.colorScheme) private var colorScheme
    @State private var copiedName = false

    private var kind: KubernetesResourceKind {
        section.resourceKind ?? .workloads
    }

    private var statusText: String {
        row.cells["Status"] ?? row.cells["Phase"] ?? (row.warning ? "Warning" : "Ready")
    }

    private var isHealthy: Bool {
        !row.warning && (statusText.lowercased().contains("running") || statusText.lowercased().contains("ready") || statusText.lowercased().contains("active") || statusText.isEmpty)
    }

    private var ageText: String? {
        row.cells["Age"]
    }

    private var nodeText: String? {
        row.cells["Node"]
    }

    private var ipText: String? {
        row.cells["IP"] ?? row.cells["Cluster-IP"] ?? row.cells["External-IP"]
    }

    private var readyText: String? {
        row.cells["Ready"] ?? row.cells["Replicas"]
    }

    private var imageText: String? {
        row.cells["Images"] ?? row.cells["Image"]
    }

    private var portsText: String? {
        row.cells["Ports"] ?? row.cells["Port(s)"]
    }

    var body: some View {
        ZStack {
            // Dimmed background that dismisses Quick Look on tap
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.dismissQuickLook()
                }

            // Floating Quick Look Card
            VStack(spacing: 0) {
                // Header
                HStack(alignment: .center, spacing: 12) {
                    TechBrandIconView(name: row.name)
                        .frame(width: 32, height: 32)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(row.name)
                                .font(.system(.title3, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(row.name, forType: .string)
                                copiedName = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    copiedName = false
                                }
                            } label: {
                                Image(systemName: copiedName ? "checkmark" : "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(copiedName ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy resource name")
                        }

                        HStack(spacing: 6) {
                            Text(kind.rawValue.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .foregroundStyle(.blue)

                            if let ns = row.namespace {
                                Text(ns)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    // Health Badge
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isHealthy ? Color.green : (row.warning ? Color.red : Color.orange))
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(isHealthy ? .green : (row.warning ? .red : .orange))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background((isHealthy ? Color.green : (row.warning ? Color.red : Color.orange)).opacity(0.12), in: Capsule())

                    // Close Button
                    Button {
                        viewModel.dismissQuickLook()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Close Quick Look (Esc)")
                }
                .padding(18)
                .background(VisualEffectBackground(material: .headerView, blendingMode: .behindWindow))

                Divider()

                // Content Body
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Diagnostic Issue Callout if warning is present
                        if row.warning {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .font(.body)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Resource Issue Detected")
                                        .font(.system(.subheadline, weight: .semibold))
                                        .foregroundStyle(.red)
                                    Text(row.cells["Message"] ?? row.cells["Reason"] ?? "This resource reported issues or non-ready status.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
                            )
                        }

                        // Core Metrics & Specs Grid
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SPECIFICATIONS")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                if let ready = readyText {
                                    QuickLookMetricItem(label: "Ready / Replicas", value: ready, icon: "checkmark.seal")
                                }
                                if let age = ageText {
                                    QuickLookMetricItem(label: "Age", value: age, icon: "clock")
                                }
                                if let node = nodeText {
                                    QuickLookMetricItem(label: "Assigned Node", value: node, icon: "server.rack")
                                }
                                if let ip = ipText {
                                    QuickLookMetricItem(label: "IP Address", value: ip, icon: "network")
                                }
                                if let ports = portsText {
                                    QuickLookMetricItem(label: "Ports", value: ports, icon: "point.3.connected.trianglepath.dotted")
                                }
                            }
                        }

                        // Containers & Images Section
                        if let image = imageText, !image.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("CONTAINER IMAGES")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 8) {
                                    Image(systemName: "shippingbox")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                    Text(image)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }

                        // Extra Metadata Cells
                        let extraCells = row.cells.filter {
                            !["Name", "Namespace", "Status", "Phase", "Age", "Node", "IP", "Cluster-IP", "External-IP", "Ready", "Replicas", "Images", "Image", "Ports", "Port(s)", "Message", "Reason"].contains($0.key)
                        }

                        if !extraCells.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("METADATA & LABELS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)

                                ForEach(Array(extraCells.keys.sorted().prefix(6)), id: \.self) { key in
                                    HStack {
                                        Text(key)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(extraCells[key] ?? "")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                    .padding(18)
                }

                Divider()

                // Footer Actions
                HStack(spacing: 12) {
                    // Inspect (Primary Action)
                    Button {
                        viewModel.dismissQuickLook()
                        viewModel.openInspector(for: row, in: section, tab: .overview)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sidebar.right")
                            Text("Inspect")
                        }
                        .font(.system(.subheadline, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)

                    // Logs Action
                    if kind == .pods || kind == .workloads {
                        Button {
                            viewModel.dismissQuickLook()
                            viewModel.openInspector(for: row, in: section, tab: .logs)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "text.alignleft")
                                Text("Logs")
                            }
                            .font(.system(.subheadline, weight: .medium))
                            .frame(height: 32)
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("l", modifiers: .command)
                    }

                    // YAML Action
                    Button {
                        viewModel.dismissQuickLook()
                        viewModel.openInspector(for: row, in: section, tab: .yaml)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text")
                            Text("YAML")
                        }
                        .font(.system(.subheadline, weight: .medium))
                        .frame(height: 32)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("y", modifiers: .command)

                    // Port Forward Action
                    if kind == .services || kind == .pods {
                        Button {
                            viewModel.dismissQuickLook()
                            viewModel.selectedSection = .portForward
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrowshape.turn.up.right")
                                Text("Port Forward")
                            }
                            .font(.system(.subheadline, weight: .medium))
                            .frame(height: 32)
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("p", modifiers: .command)
                    }

                    Spacer()

                    // Quick Look Keyboard Hint
                    Text("[Space] Close")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(VisualEffectBackground(material: .headerView, blendingMode: .behindWindow))
            }
            .frame(width: 560, height: 440)
            .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: viewModel.isQuickLookActive)
    }
}

private struct QuickLookMetricItem: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.caption, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
