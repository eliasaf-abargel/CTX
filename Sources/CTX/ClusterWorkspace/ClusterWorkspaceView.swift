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
            ClusterWorkspaceView(store: store, context: context, onStatusCheckFailed: { contextName, reason in
                store.markKubernetesContextNeedsLogin(contextName: contextName, reason: reason)
            })
            .onChange(of: profile == nil) { _, isDeleted in
                if isDeleted {
                    dismissWindow()
                }
            }
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
    let store: ProfileStore
    @StateObject private var viewModel: ClusterWorkspaceViewModel
    @State private var isSearchPresented: Bool = false

    init(store: ProfileStore, context: KubernetesContextProfile, onStatusCheckFailed: ((String, String) -> Void)? = nil) {
        self.store = store
        let vm = ClusterWorkspaceViewModel(context: context)
        vm.onStatusCheckFailed = onStatusCheckFailed
        _viewModel = StateObject(wrappedValue: vm)
    }

    @AppStorage(AppAppearance.storageKey) private var appAppearanceRaw: String = AppAppearance.dark.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

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
            // Measured here, once. The detail pane has a definite size, so a
            // `GeometryReader` is safe at this level — unlike inside the page's
            // scroll view, where a table measuring its own frame never resolved and
            // silently kept its 900pt default. That default is why tables stopped
            // short of the panel edge on a wide window *and* shed their
            // lowest-priority columns as though space were tight.
            GeometryReader { proxy in
            VStack(spacing: 0) {
                ClusterWorkspaceHeader(viewModel: viewModel, store: store)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                Divider()
                    .opacity(0.5)

                ClusterWorkspaceContent(viewModel: viewModel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(colorScheme == .light ? Color(NSColor.windowBackgroundColor) : Color(white: 0.12).opacity(0.65))
            // The safe-area inset under `hiddenTitleBar` stays. Ignoring it removed
            // the empty band in a normal window but clipped the header off the top
            // edge in full screen, where there is no title bar to inset against.
            .navigationTitle(viewModel.title)
            .environment(\.workspaceContentWidth, proxy.size.width)
            }
        }
        .toolbar {
            // `.navigation` placement is the same slot Mail and Notes put their own
            // back/forward controls in — it sits right beside the traffic lights
            // this window already reserves space for via `NavigationSplitView`, so
            // this needs no manual positioning to avoid overlapping them.
            ToolbarItem(placement: .navigation) {
                Button(action: backToCTX) {
                    Label("Back to CTX", systemImage: "chevron.backward")
                }
                .help("Back to CTX")
                .accessibilityLabel("Back to CTX")
            }
        }
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
        .ctxChromelessWindow()
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
            ClusterCommandPaletteModal(viewModel: viewModel)
        }
        .overlay {
            if viewModel.isQuickLookActive, let row = viewModel.quickLookResource, let section = viewModel.quickLookSection {
                CTXQuickLookOverlay(viewModel: viewModel, row: row, section: section)
            }
        }
        .background {
            HStack {
                // Command Palette (Spotlight-style ⌘K)
                Button("") { isSearchPresented = true }
                    .keyboardShortcut("k", modifiers: .command)

                // Spacebar Quick Look — disabled while the YAML editor is open so a
                // literal space typed into a manifest is never eaten by this instead.
                Button("") { viewModel.toggleQuickLook() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(viewModel.isEditingYAML)

                // Bypass Cache & Reload (⌘R)
                Button("") { viewModel.loadSelectedSection(bypassCache: true) }
                    .keyboardShortcut("r", modifiers: .command)

                // Section Navigation (⌘1 to ⌘8)
                Button("") { viewModel.selectedSection = .overview }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { viewModel.selectedSection = .topology }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { viewModel.selectedSection = .workloads }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { viewModel.selectedSection = .pods }
                    .keyboardShortcut("4", modifiers: .command)
                Button("") { viewModel.selectedSection = .services }
                    .keyboardShortcut("5", modifiers: .command)
                Button("") { viewModel.selectedSection = .logs }
                    .keyboardShortcut("6", modifiers: .command)
                Button("") { viewModel.selectedSection = .portForward }
                    .keyboardShortcut("7", modifiers: .command)
                Button("") { viewModel.selectedSection = .issues }
                    .keyboardShortcut("8", modifiers: .command)

                // Direct Resource Shortcuts (⌘L for Logs, ⌘Y for YAML)
                Button("") {
                    if let row = viewModel.activeSelectedResource {
                        viewModel.openInspector(for: row, in: viewModel.selectedSection, tab: .logs)
                    }
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("") {
                    if let row = viewModel.activeSelectedResource {
                        viewModel.openInspector(for: row, in: viewModel.selectedSection, tab: .yaml)
                    }
                }
                .keyboardShortcut("y", modifiers: .command)

                Button("") {
                    if let row = viewModel.activeSelectedResource, row.cells["Ports"] != nil || row.cells["Port(s)"] != nil {
                        viewModel.selectedSection = .portForward
                    }
                }
                .keyboardShortcut("p", modifiers: .command)

                // Dismiss QuickLook / Inspector
                Button("") {
                    if viewModel.isQuickLookActive {
                        viewModel.dismissQuickLook()
                    } else if viewModel.presentation != nil {
                        viewModel.dismissPresentation()
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    /// Raises the main window rather than opening a second instance of it —
    /// `Window` (unlike `WindowGroup`) is a singleton scene, so `openWindow`
    /// already does the right thing if it's still open; this only has to
    /// handle the case the main window was closed while this one stayed open.
    private func backToCTX() {
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "CTX" }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ClusterWorkspaceHeader: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let store: ProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            horizontalHeader
        }
    }

    private var clusterIcon: some View {
        Image(systemName: "shippingbox.circle.fill")
            .font(.system(.title, weight: .semibold))
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
                    .font(.system(.title2, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.title)
                    .layoutPriority(1)
                CTXEnvironmentBadge(environment: viewModel.context.environmentType)
                    .fixedSize()
            }

            Text(viewModel.clusterName)
                .font(.system(.footnote, design: .monospaced, weight: .medium))
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
        if store.activeKubeContext == viewModel.context.contextName {
            CTXStatusBadge(title: "CLI Default", systemImage: "terminal.fill", tint: .blue)
                .help("This cluster is currently active in ~/.kube/config for terminal commands")
        }
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
                if store.activeKubeContext != viewModel.context.contextName,
                   let prof = store.profiles.first(where: { $0.provider == .kubernetes && $0.name == viewModel.context.contextName }) {
                    Button {
                        store.setActive(prof, from: .mainWindow)
                    } label: {
                        Label("Set as CLI Default", systemImage: "terminal")
                            .font(.system(.caption, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Set this cluster as current-context in ~/.kube/config for external terminals")
                }
                ClusterWorkspaceHealthMenu(viewModel: viewModel, store: store)
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
                    .font(.system(.caption, weight: .semibold))
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
        ClusterWorkspaceView(store: ProfileStore(startsBackgroundServices: false), context: .previewProduction)
    }
}
