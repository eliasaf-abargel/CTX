import AppKit
import CTXCore
import SwiftUI

struct ClusterPortForwardView: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    private var services: [KubernetesResourceRow] {
        viewModel.resourceList(for: .services)?.rows ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CTXSectionHeader(title: "Port Forward", subtitle: "Local tunnel to a selected Service")

            CTXGlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    servicePicker
                    portFields
                    actionRow
                }
            }

            if let issue = viewModel.portForwardIssue {
                CTXDiagnosticCard(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red,
                    title: "Port forward failed",
                    message: issue.stderrSummary,
                    diagnosticSummary: issue.safeSummary,
                    retry: { viewModel.startPortForward() }
                )
            }

            activeSessions
        }
        .onAppear {
            viewModel.loadServicesForPortForward()
        }
    }

    private var servicePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Service")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(services) { row in
                    Button {
                        viewModel.selectPortForwardService(row)
                    } label: {
                        Text(serviceTitle(row))
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.blue)
                    Text(viewModel.selectedPortForwardServiceRow.map(serviceTitle) ?? "Select service")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(services.isEmpty)
            .help("Choose a loaded Service")
        }
    }

    private var portFields: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                portField(title: "Local", text: $viewModel.portForwardLocalPort)
                portField(title: "Remote", text: $viewModel.portForwardRemotePort)
            }
            VStack(alignment: .leading, spacing: 10) {
                portField(title: "Local", text: $viewModel.portForwardLocalPort)
                portField(title: "Remote", text: $viewModel.portForwardRemotePort)
            }
        }
    }

    private func portField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(width: 120)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.startPortForward()
            } label: {
                Label(viewModel.isStartingPortForward ? "Starting" : "Start", systemImage: "arrowshape.turn.up.right")
            }
            .buttonStyle(CTXPrimaryButton())
            .disabled(viewModel.isStartingPortForward || viewModel.selectedPortForwardServiceRow == nil)

            if viewModel.isLoading(section: .services) {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var activeSessions: some View {
        if viewModel.portForwardSessions.isEmpty {
            CTXGlassPanel {
                CTXEmptyStateView(title: "No active forwards", message: "Start a local tunnel from a loaded Service.", systemImage: "arrowshape.turn.up.right")
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                CTXSectionHeader(title: "Active", subtitle: "\(viewModel.portForwardSessions.count) local tunnel\(viewModel.portForwardSessions.count == 1 ? "" : "s")")
                ForEach(viewModel.portForwardSessions) { session in
                    PortForwardSessionRow(session: session) {
                        open(session.localURL)
                    } stop: {
                        viewModel.stopPortForward(session)
                    }
                }
            }
        }
    }

    private func serviceTitle(_ row: KubernetesResourceRow) -> String {
        [row.namespace, row.name, row.cells["Ports"]].compactMap { value in
            guard let value, !value.isEmpty, value != "-" else { return nil }
            return value
        }.joined(separator: " · ")
    }

    private func open(_ url: String) {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PortForwardSessionRow: View {
    let session: KubernetesPortForwardSession
    let open: () -> Void
    let stop: () -> Void

    var body: some View {
        CTXGlassPanel(padding: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    content
                    Spacer(minLength: 12)
                    controls
                }
                VStack(alignment: .leading, spacing: 12) {
                    content
                    controls
                }
            }
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 28, height: 28)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("service/\(session.targetName)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(session.namespace) · \(session.localPort) -> \(session.remotePort) · \(session.localURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                open()
            } label: {
                Label("Open", systemImage: "safari")
            }
            .buttonStyle(CTXSecondaryButton())

            Button {
                stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(CTXSecondaryButton())
        }
    }
}
