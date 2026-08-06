import CTXCore
import SwiftUI

struct ClusterWorkspaceScene: View {
    @ObservedObject var store: ProfileStore
    let contextID: String
    @Environment(\.dismiss) private var dismiss

    private var context: KubernetesContextProfile? {
        store.kubernetesContexts.first { $0.id == contextID }
            ?? store.kubernetesContexts.first { $0.contextName == contextID }
    }

    private var profile: CloudProfile? {
        guard let context else { return nil }
        return store.profiles.first { $0.provider == .kubernetes && $0.name == context.contextName }
    }

    var body: some View {
        if let context {
            ClusterWorkspaceView(context: context, onStatusCheckFailed: { contextName, reason in
                store.markKubernetesContextNeedsLogin(contextName: contextName, reason: reason)
            })
            .onChange(of: profile?.status) { _, newStatus in
                if newStatus == .needsLogin || newStatus == .disconnecting || newStatus == .unknown {
                    dismissWindow()
                }
            }
            .onChange(of: store.activeKubeContext) { _, activeContext in
                if activeContext != context.contextName {
                    dismissWindow()
                }
            }
        } else {
            CTXGlassPanel {
                CTXErrorStateView(
                    title: "Context unavailable",
                    message: "Reload CTX and open the workspace from a discovered Kubernetes context."
                )
            }
            .padding(28)
            .frame(minWidth: 600, minHeight: 440)
        }
    }

    private func dismissWindow() {
        dismiss()
        DispatchQueue.main.async {
            for window in NSApp.windows {
                if window.title == contextID || window.title.contains(contextID) {
                    window.close()
                }
            }
        }
    }
}

struct ClusterWorkspaceView: View {
    @StateObject private var viewModel: ClusterWorkspaceViewModel
    @State private var isSearchPresented: Bool = false

    init(context: KubernetesContextProfile, onStatusCheckFailed: ((String, String) -> Void)? = nil) {
        let vm = ClusterWorkspaceViewModel(context: context)
        vm.onStatusCheckFailed = onStatusCheckFailed
        _viewModel = StateObject(wrappedValue: vm)
    }

    @AppStorage("ctxAppAppearance") private var appAppearanceRaw: String = AppAppearance.dark.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var currentAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .dark
    }

    var body: some View {
        NavigationSplitView {
            ClusterWorkspaceSidebar(viewModel: viewModel)
                .background(colorScheme == .light ? Color(NSColor.controlBackgroundColor).opacity(0.5) : Color.black.opacity(0.25))
                .navigationTitle("Cluster")
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
            .background(colorScheme == .light ? Color(NSColor.windowBackgroundColor) : Color(white: 0.12).opacity(0.65))
            .navigationTitle(viewModel.title)
        }
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
        .preferredColorScheme(currentAppearance.colorScheme)
        .frame(minWidth: 680, minHeight: 480)
        .task {
            await viewModel.refreshOverviewIfNeeded()
            viewModel.prefetchWorkspaceResources()
        }
        .onChange(of: viewModel.selectedSection) { _, newValue in
            if newValue == .overview {
                Task { await viewModel.refreshOverviewIfNeeded() }
            }
        }
        .onDisappear {
            viewModel.cancelRefresh()
        }
        .sheet(isPresented: $isSearchPresented) {
            ClusterQuickSearchModal(viewModel: viewModel)
        }
        .background {
            HStack {
                Button("") { isSearchPresented = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("") { viewModel.loadSelectedSection(bypassCache: true) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("") { viewModel.selectedSection = .overview }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { viewModel.selectedSection = .pods }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { viewModel.selectedSection = .cronjobs }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { viewModel.selectedSection = .events }
                    .keyboardShortcut("4", modifiers: .command)
                Button("") { viewModel.selectedSection = .topology }
                    .keyboardShortcut("5", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }
}

struct ClusterWorkspaceHeader: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            horizontalHeader
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
        CTXStatusBadge(title: viewModel.displayUserName, systemImage: "person.crop.circle", tint: .secondary)
            .help(viewModel.userName)
        if let expiry = AWSSessionExpirationService().sessionExpiry(for: KubernetesProfileAdapter.cloudProfile(from: viewModel.context)) {
            let remaining = expiry.timeIntervalSinceNow
            if remaining > 0 {
                let hours = Int(remaining) / 3600
                let mins = (Int(remaining) % 3600) / 60
                CTXStatusBadge(title: "Session: \(hours)h \(mins)m", systemImage: "clock.badge.checkmark", tint: remaining < 1800 ? .orange : .green)
                    .help("Cloud STS Session valid until \(expiry.formatted(.dateTime.hour().minute()))")
            }
        }
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
