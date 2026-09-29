import CTXCore
import SwiftUI

/// The map's own controls: lineage search, what is drawn, the two filters, the
/// legend and zoom.
///
/// Narrowing the window drops *labels*, never controls. Hiding a filter behind
/// an overflow menu at small widths costs the user the one thing the toolbar is
/// for — seeing at a glance whether a filter is on — so each tier below shows
/// the same seven affordances and only spends less width saying what they are.
struct TopologyToolbarView: View {
    @Binding var searchText: String
    @Binding var needsAttentionOnly: Bool
    @Binding var showsInactive: Bool
    let scale: CGFloat
    let counts: TopologyCountSummary
    @Binding var command: TopologyMapCommand?
    @State private var showsLegend = false
    @State private var showsCounts = false

    /// Widest first. `ViewThatFits` compares each candidate's *ideal* width, so
    /// every cluster that must not shrink is `fixedSize`d: a Label allowed to
    /// truncate reports a tiny ideal width, the wide bar then claims to fit at
    /// any size, and the controls clip instead of stepping down to the icons.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            labelledToolbar
            iconToolbar
            stackedToolbar
        }
        .popover(isPresented: $showsLegend, arrowEdge: .bottom) {
            TopologyLegendView()
        }
        .popover(isPresented: $showsCounts, arrowEdge: .bottom) {
            Text(counts.full)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: 320, alignment: .leading)
        }
    }

    private var labelledToolbar: some View {
        HStack(spacing: 10) {
            searchField("Find object; use +name+ for lineage")
                .frame(minWidth: 220, idealWidth: 300, maxWidth: 360)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                countLabel
                filterButton(
                    title: "Needs attention",
                    systemImage: "exclamationmark.triangle",
                    isOn: $needsAttentionOnly,
                    tint: .orange
                )
                filterButton(
                    title: "Show inactive",
                    systemImage: "moon.zzz",
                    isOn: $showsInactive,
                    tint: .secondary
                )
                legendButton
                labelledZoomControls
            }
            .fixedSize()
        }
    }

    private var iconToolbar: some View {
        HStack(spacing: 8) {
            // A shorter prompt, because a placeholder cut off mid-word teaches
            // the syntax less well than a brief one that fits. The full
            // explanation stays in the field's tooltip either way.
            searchField("Find object · +name+")
                .frame(minWidth: 150, maxWidth: 360)
                .layoutPriority(1)
            Spacer(minLength: 8)
            iconControls
        }
    }

    /// The last resort, so the field asks for no minimum width of its own and
    /// the icon row — which cannot shrink further without losing a control —
    /// gets a line to itself.
    private var stackedToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField("Find object · +name+")
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                iconControls
                Spacer(minLength: 0)
            }
        }
    }

    private var iconControls: some View {
        HStack(spacing: 6) {
            countBadge
            iconButton(
                title: "Needs attention",
                systemImage: "exclamationmark.triangle",
                isOn: $needsAttentionOnly,
                tint: .orange
            )
            iconButton(
                title: "Show inactive",
                systemImage: "moon.zzz",
                isOn: $showsInactive,
                tint: .secondary
            )
            CTXIconActionButton(title: "Map legend", systemImage: "info.circle") {
                showsLegend.toggle()
            }
            zoomIconControls
        }
        .fixedSize()
    }

    private func searchField(_ placeholder: String) -> some View {
        CTXSearchField(placeholder: placeholder, text: $searchText)
        .help("""
        Type part of a name to show matching objects.
        name+ includes downstream dependents.
        +name includes upstream dependencies.
        +name+ includes both directed paths.
        """)
    }

    private var countLabel: some View {
        Button {
            showsCounts.toggle()
        } label: {
            Text(counts.medium)
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(counts.full)
        .accessibilityLabel("Map counts")
        .accessibilityValue(counts.full)
    }

    /// Numbers rather than a glyph. There is no icon for "42 of 350 drawn", and
    /// a symbol standing in for one reads as a button whose purpose has to be
    /// guessed; the ratio itself is both the label and the information.
    private var countBadge: some View {
        Button {
            showsCounts.toggle()
        } label: {
            Text(counts.short)
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minWidth: 34, minHeight: 28)
                .background(Color.secondary.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.secondary.opacity(0.24), lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(counts.full)
        .accessibilityLabel("Map counts")
        .accessibilityValue(counts.full)
    }

    private var legendButton: some View {
        Button {
            showsLegend.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(CTXSecondaryButton())
        .help("Map legend")
        .accessibilityLabel("Map legend")
    }

    private func filterButton(
        title: String,
        systemImage: String,
        isOn: Binding<Bool>,
        tint: Color
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Label(title, systemImage: isOn.wrappedValue ? "\(systemImage).fill" : systemImage)
                .foregroundStyle(isOn.wrappedValue ? tint : .primary)
        }
        .buttonStyle(CTXSecondaryButton())
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    private func iconButton(
        title: String,
        systemImage: String,
        isOn: Binding<Bool>,
        tint: Color
    ) -> some View {
        CTXIconActionButton(
            title: title,
            systemImage: isOn.wrappedValue ? "\(systemImage).fill" : systemImage,
            tint: isOn.wrappedValue ? tint : .primary,
            isOn: isOn.wrappedValue
        ) {
            isOn.wrappedValue.toggle()
        }
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    /// The shortcuts these buttons name are mounted by the pane, not here: one
    /// attached to a tier that is off screen would leave ⌘0 unbound, and one
    /// attached to a tier `ViewThatFits` merely measures would bind it twice.
    private var labelledZoomControls: some View {
        HStack(spacing: 4) {
            Button { command = .zoomOut } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(CTXSecondaryButton())
            .help("Zoom out (⌘−)")
            .accessibilityLabel("Zoom out")

            Text("\(Int(scale * 100))%")
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .frame(width: 40)
                .contentTransition(.numericText())

            Button { command = .zoomIn } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(CTXSecondaryButton())
            .help("Zoom in (⌘+)")
            .accessibilityLabel("Zoom in")

            Button { command = .fit } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(CTXSecondaryButton())
            .help("Fit map (⌘0)")
            .accessibilityLabel("Fit map")
        }
    }

    private var zoomIconControls: some View {
        HStack(spacing: 6) {
            CTXIconActionButton(title: "Zoom out (⌘−)", systemImage: "minus.magnifyingglass") {
                command = .zoomOut
            }
            .accessibilityLabel("Zoom out")
            .accessibilityValue("\(Int(scale * 100)) percent")

            CTXIconActionButton(title: "Zoom in (⌘+)", systemImage: "plus.magnifyingglass") {
                command = .zoomIn
            }
            .accessibilityLabel("Zoom in")
            .accessibilityValue("\(Int(scale * 100)) percent")

            CTXIconActionButton(title: "Fit map (⌘0)", systemImage: "arrow.up.left.and.arrow.down.right") {
                command = .fit
            }
            .accessibilityLabel("Fit map")
        }
    }
}

private struct TopologyLegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Map legend")
                .font(.headline)

            ForEach(TopologyGraphNodeKind.allCases, id: \.self) { kind in
                HStack(spacing: 8) {
                    Text(kind.code)
                        .font(.system(.caption2, design: .rounded, weight: .heavy))
                        .foregroundStyle(kind.topologyTint)
                        .frame(width: 34, height: 16)
                        .background(kind.topologyTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    Label(kind.title, systemImage: kind.systemImage)
                        .font(.caption2)
                }
            }

            Divider()

            Text("Select an object to highlight its upstream dependencies and downstream dependents. Drag to pan and scroll or pinch to zoom.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }
}
