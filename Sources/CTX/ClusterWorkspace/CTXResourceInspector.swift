import CTXCore
import SwiftUI

/// The single resource inspector — one sheet, one presentation, tabs switch what's
/// shown inside it (Overview / YAML / Logs-for-Pods). Replaced an earlier two-sheet
/// design (a detail sheet that handed off to a separate YAML sheet) where presenting
/// the second sheet forced the first to auto-dismiss, and that dismiss incorrectly
/// tore down the very state the second sheet needed — "YAML opens then instantly
/// closes." With everything as tabs inside one sheet, there is nothing to hand off:
/// switching tabs mutates `ClusterWorkspaceViewModel.presentation.tab` in place.
struct CTXResourceInspector: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let selection: ClusterWorkspaceResourceSelection
    let activeTab: CTXInspectorTab

    private var detail: KubernetesResourceDetail {
        KubernetesResourceDetail(kind: selection.kind, row: selection.row)
    }

    private var visibleTabs: [CTXInspectorTab] {
        CTXInspectorTab.visibleTabs(for: selection.kind)
    }

    private var widthRange: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        switch activeTab {
        case .overview:
            return (480, 560, 680)
        case .yaml, .logs:
            return (760, 960, 1400)
        }
    }

    private var heightRange: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        switch activeTab {
        case .overview:
            return (360, 480, 720)
        case .yaml, .logs:
            return (480, 560, 920)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CTXResourceInspectorHeader(detail: detail, dismiss: { viewModel.dismissPresentation() })
                .padding(.horizontal, 16)
                .padding(.top, 16)

            CTXInspectorTabBar(tabs: visibleTabs, activeTab: activeTab) { tab in
                viewModel.selectInspectorTab(tab)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider().padding(.top, 10)

            // Each tab owns its own scroll layer so that wheel events are
            // always delivered to the innermost ScrollView instead of being
            // captured by a wrapping one.
            // .frame(maxHeight: .infinity) ensures the tab content always
            // expands to fill the sheet from the divider downwards, so
            // a small loading state never leaves an empty black void above it.
            Group {
                switch activeTab {
                case .overview:
                    ScrollView(.vertical) {
                        CTXInspectorOverviewTab(viewModel: viewModel, selection: selection, detail: detail)
                            .padding(16)
                    }
                case .yaml:
                    CTXInspectorYAMLTab(viewModel: viewModel, selection: selection)
                        .padding(16)
                case .logs:
                    CTXInspectorLogsTab(viewModel: viewModel, selection: selection)
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(
            minWidth: widthRange.min,
            idealWidth: widthRange.ideal,
            maxWidth: widthRange.max,
            minHeight: heightRange.min,
            idealHeight: heightRange.ideal,
            maxHeight: heightRange.max
        )
        .onExitCommand { viewModel.dismissPresentation() }
    }
}

/// Resource icon/status/title/subtitle — visible above the tab bar regardless of
/// which tab is active, so switching to YAML or Logs never loses sight of which
/// resource is being inspected.
struct CTXResourceInspectorHeader: View {
    let detail: KubernetesResourceDetail
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: detail.warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(detail.warning ? .orange : .blue)
                .frame(width: 28, height: 28)
                .background((detail.warning ? Color.orange : Color.blue).opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail.title)
                Text(detail.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail.subtitle)
            }
            Spacer(minLength: 8)
            if detail.status != "-" {
                Text(detail.status)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(detail.warning ? .orange : .secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.10), in: Capsule())
            }
            Button("Done", action: dismiss)
                .buttonStyle(CTXPrimaryButton())
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Native macOS segmented control for switching inspector tabs — not a custom
/// hand-drawn tab bar. `Picker(.segmented)` is the system's own tabbed-content
/// idiom (System Settings panes, Xcode inspectors) and comes with correct spacing,
/// selection styling, and no extra code to keep it looking right.
struct CTXInspectorTabBar: View {
    let tabs: [CTXInspectorTab]
    let activeTab: CTXInspectorTab
    let onSelect: (CTXInspectorTab) -> Void

    var body: some View {
        Picker("Inspector tab", selection: Binding(
            get: { activeTab },
            set: { onSelect($0) }
        )) {
            ForEach(tabs, id: \.self) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }
}
