import CTXCore
import SwiftUI

/// Unified detail inspector for all Kubernetes resource rows. Renders as a single
/// native macOS sheet over the workspace, preserving the previous selection when
/// closed, and offering deep inspectability:
/// - Header: icon, kind, title, namespace, status chip, copy-name button, dismiss.
/// - Tab switcher: Overview (structured key-value metrics), YAML (live get -o yaml),
///   Logs (for Pods, Services, and Workloads), Diagnostics (misconfiguration checks).
/// - Content area: scrollable, styled with the CTX translucent dark glass language.
struct CTXResourceInspector: View {
    @ObservedObject var viewModel: ClusterWorkspaceViewModel
    let selection: ClusterWorkspaceResourceSelection

    private var detail: KubernetesResourceDetail {
        KubernetesResourceDetail(kind: selection.kind, row: selection.row)
    }

    private var activeTab: CTXInspectorTab {
        viewModel.presentation?.tab ?? .overview
    }

    private var visibleTabs: [CTXInspectorTab] {
        CTXInspectorTab.visibleTabs(for: selection.kind)
    }

    private var issuesCount: Int {
        viewModel.diagnostics(for: selection.row.id).count
    }

    private var widthRange: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        switch activeTab {
        case .overview: (640, 720, 840)
        case .yaml: (680, 780, 920)
        case .logs: (740, 860, 1040)
        case .diagnostics: (680, 760, 880)
        }
    }

    private var heightRange: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        switch activeTab {
        case .overview: (480, 560, 680)
        case .yaml: (520, 620, 800)
        case .logs: (520, 620, 820)
        case .diagnostics: (480, 580, 750)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CTXResourceInspectorHeader(detail: detail, issuesCount: issuesCount, dismiss: { viewModel.dismissPresentation() })
                .padding(.horizontal, 16)
                .padding(.top, 16)

            CTXInspectorTabBar(tabs: visibleTabs, activeTab: activeTab, issuesCount: issuesCount) { tab in
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
                case .diagnostics:
                    CTXInspectorDiagnosticsTab(viewModel: viewModel, selection: selection)
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
    var issuesCount: Int = 0
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: detail.warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(detail.warning ? .orange : .blue)
                .frame(width: 28, height: 28)
                .background((detail.warning ? Color.orange : Color.blue).opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(detail.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(detail.title)
                    CTXCopyIconButton(value: detail.title)
                }
                Text(detail.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail.subtitle)
            }
            Spacer(minLength: 8)
            if issuesCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(issuesCount) \(issuesCount == 1 ? "issue" : "issues")")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.12), in: Capsule())
            }
            if detail.status != "-" {
                Text(detail.status)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(detail.warning ? .orange : .secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.10), in: Capsule())
            }
            CTXInspectorDoneButton(action: dismiss)
        }
    }
}

/// Compact inspector tab switcher. The system segmented control reads too much
/// like a form button inside this dark sheet, so this keeps the behavior but uses
/// the same quiet toolbar language as the rest of CTX.
struct CTXInspectorTabBar: View {
    let tabs: [CTXInspectorTab]
    let activeTab: CTXInspectorTab
    var issuesCount: Int = 0
    let onSelect: (CTXInspectorTab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { tab in
                CTXInspectorTabButton(
                    tab: tab,
                    isSelected: tab == activeTab,
                    issuesCount: issuesCount,
                    action: { onSelect(tab) }
                )
            }
        }
        .padding(4)
        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector tab")
    }
}

private struct CTXInspectorDoneButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    Color.secondary.opacity(isHovered ? 0.16 : 0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(isHovered ? 0.26 : 0.16), lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help("Close inspector")
    }
}

private struct CTXInspectorTabButton: View {
    let tab: CTXInspectorTab
    let isSelected: Bool
    var issuesCount: Int = 0
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .font(.system(.caption2, weight: .semibold))
                Text(tab.title)
                    .font(.system(.caption, weight: .semibold))
                    .lineLimit(1)
                if tab == .diagnostics && issuesCount > 0 {
                    Text("\(issuesCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(stroke, lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(tab.title)
    }

    private var foreground: Color {
        if isSelected { return .primary }
        return isHovered ? .primary : .secondary
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.20) }
        return Color.secondary.opacity(isHovered ? 0.11 : 0.0)
    }

    private var stroke: Color {
        if isSelected { return Color.accentColor.opacity(0.38) }
        return Color.secondary.opacity(isHovered ? 0.18 : 0.0)
    }
}
