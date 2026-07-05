import CTXCore
import SwiftUI

struct ClusterWorkspaceScene: View {
    @ObservedObject var store: ProfileStore
    let contextID: String

    private var context: KubernetesContextProfile? {
        store.kubernetesContexts.first { $0.id == contextID }
            ?? store.kubernetesContexts.first { $0.contextName == contextID }
    }

    var body: some View {
        if let context {
            ClusterWorkspaceView(context: context)
        } else {
            CTXGlassPanel {
                CTXErrorStateView(
                    title: "Context unavailable",
                    message: "Reload CTX and open the workspace from a discovered Kubernetes context."
                )
            }
            .padding(28)
            .frame(minWidth: 760, minHeight: 520)
        }
    }
}

struct ClusterWorkspaceView: View {
    @StateObject private var viewModel: ClusterWorkspaceViewModel

    init(context: KubernetesContextProfile) {
        _viewModel = StateObject(wrappedValue: ClusterWorkspaceViewModel(context: context))
    }

    var body: some View {
        NavigationSplitView {
            ClusterWorkspaceSidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 310)
        } detail: {
            VStack(spacing: 0) {
                ClusterWorkspaceHeader(viewModel: viewModel)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                Divider()
                    .opacity(0.5)

                ClusterWorkspaceContent(viewModel: viewModel)
            }
            .background(.background)
        }
        .frame(minWidth: 980, minHeight: 660)
        .task {
            await viewModel.refreshOverviewIfNeeded()
            viewModel.prefetchWorkspaceResources()
        }
        .onChange(of: viewModel.selectedSection) { _, newValue in
            if newValue == .overview {
                Task { await viewModel.refreshOverviewIfNeeded() }
            } else {
                viewModel.loadSelectedSection(bypassCache: false)
            }
        }
        .onDisappear {
            viewModel.cancelRefresh()
        }
    }
}

struct ClusterWorkspaceHeader: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.isProduction {
                CTXProductionWarningBanner(contextName: viewModel.context.contextName)
            }

            ViewThatFits(in: .horizontal) {
                horizontalHeader
                compactHeader
            }
        }
    }

    private var clusterIcon: some View {
        Image(systemName: "shippingbox.circle.fill")
            .font(.system(size: 32, weight: .semibold))
            .foregroundStyle(.indigo)
            .frame(width: 46, height: 46)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .fixedSize()
    }

    private var horizontalHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            clusterIcon
            titleBlock
                .layoutPriority(1)
            Spacer(minLength: 18)
            statusBlock
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                clusterIcon
                titleBlock
                    .layoutPriority(1)
            }
            statusRow
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text(viewModel.title)
                    .font(.system(size: 21, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.title)
                    .layoutPriority(1)
                CTXEnvironmentBadge(environment: viewModel.context.environmentType)
                    .fixedSize()
            }

            Text(viewModel.clusterName)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(viewModel.clusterName)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { metadataBadges }
                VStack(alignment: .leading, spacing: 6) { metadataBadges }
            }
        }
    }

    @ViewBuilder
    private var metadataBadges: some View {
        CTXStatusBadge(title: viewModel.context.providerType.label, systemImage: "cloud", tint: viewModel.context.providerType.tint)
        ClusterNamespaceSelector(viewModel: viewModel)
        CTXStatusBadge(title: viewModel.userName, systemImage: "person.crop.circle", tint: .secondary)
    }

    private var statusBlock: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 8) {
                ClusterWorkspaceHealthMenu(viewModel: viewModel)
                refreshButton
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            ClusterWorkspaceHealthMenu(viewModel: viewModel)
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button {
            viewModel.refreshCurrentScreen()
        } label: {
            if viewModel.isRefreshingCurrentScreen {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(viewModel.isRefreshingCurrentScreen)
        .frame(width: 24, height: 22)
        .help("Refresh current inspection view")
    }
}

struct ClusterWorkspaceView_Previews: PreviewProvider {
    static var previews: some View {
        ClusterWorkspaceView(context: .previewProduction)
    }
}
