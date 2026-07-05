import CTXCore
import SwiftUI

/// Shared, kind-agnostic resource table. Column set, widths, alignment, and which
/// field gets a copy icon all come from `CTXResourceColumns` — no per-screen
/// hand-rolled table code.
struct CTXResourceTable: View {
    let kind: KubernetesResourceKind
    let rows: [KubernetesResourceRow]
    let selectedRowID: String?
    /// Whether the workspace is currently scoped to "All namespaces." When false
    /// (a single namespace is selected), every visible row shares the same
    /// namespace, so the Namespace column is dropped — it wouldn't say anything a
    /// row doesn't already imply, just take up space and add a column to scan.
    let showsNamespaceColumn: Bool
    let onSelect: (KubernetesResourceRow) -> Void

    @State private var availableWidth: CGFloat = 900
    @State private var hoveredRowID: String?

    /// Derived from the table's own measured width rather than passed in from the
    /// caller — one less piece of width-tracking state duplicated across views.
    /// Uses the same breakpoint as the rest of the workspace (`ClusterWorkspaceLayoutMode`).
    private var isCompact: Bool {
        ClusterWorkspaceLayoutMode(width: availableWidth) == .compact
    }

    private var allColumns: [CTXTableColumn] {
        let columns = CTXResourceColumns.columns(for: kind)
        return showsNamespaceColumn ? columns : columns.filter { $0.key != "Namespace" }
    }

    var body: some View {
        let resolved = Self.resolve(allColumns, availableWidth: availableWidth, isCompact: isCompact)
        let contentWidth = resolved.reduce(rowHorizontalPadding * 2) { $0 + $1.1 } + CGFloat(max(0, resolved.count - 1)) * columnSpacing

        return VStack(alignment: .leading, spacing: 0) {
            CTXGlassPanel(padding: 0) {
                ScrollView(.horizontal) {
                    // `LazyVStack`, not `VStack` — a busy cluster's "all namespaces"
                    // Pods/Events view can easily be hundreds to thousands of rows;
                    // deferring construction of off-screen rows (SwiftUI defers based
                    // on the enclosing vertical ScrollView's viewport, one level up in
                    // `ClusterWorkspaceContent`) is what keeps that screen responsive
                    // instead of eagerly building every row on every load/refresh.
                    LazyVStack(spacing: 0) {
                        headerRow(resolved)
                        Divider()
                        ForEach(rows) { row in
                            resourceRow(row, resolved)
                            Divider().opacity(0.45)
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(width: contentWidth, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TableWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(TableWidthPreferenceKey.self) { availableWidth = $0 }
    }

    private let rowHorizontalPadding: CGFloat = 14
    private let columnSpacing: CGFloat = 12

    private func headerRow(_ resolved: [(CTXTableColumn, CGFloat)]) -> some View {
        HStack(spacing: columnSpacing) {
            ForEach(resolved, id: \.0.id) { column, width in
                Text(column.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: width, alignment: column.alignment == .trailing ? .trailing : .leading)
            }
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, 9)
    }

    private func resourceRow(_ row: KubernetesResourceRow, _ resolved: [(CTXTableColumn, CGFloat)]) -> some View {
        let isHovered = hoveredRowID == row.id
        return HStack(spacing: columnSpacing) {
            ForEach(resolved, id: \.0.id) { column, width in
                cell(row, column: column, width: width, isRowHovered: isHovered)
            }
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .background(rowBackground(row), in: Rectangle())
        .onTapGesture { onSelect(row) }
        .onHover { hovering in
            hoveredRowID = hovering ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
        }
    }

    @ViewBuilder
    private func cell(_ row: KubernetesResourceRow, column: CTXTableColumn, width: CGFloat, isRowHovered: Bool) -> some View {
        let value = row.cells[column.key] ?? "-"
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 12, design: column.monospaced ? .monospaced : .default))
                .foregroundStyle(row.warning && column.key == "Status" ? .orange : .primary)
                .lineLimit(column.key == "Message" ? 2 : 1)
                .truncationMode(.middle)
                .help(value)
                .multilineTextAlignment(column.alignment == .trailing ? .trailing : .leading)
            if column.copyable && value != "-" {
                // Reserved in layout at all times (so the row never reflows when the
                // pointer enters/leaves) but only visible/hit-testable on hover — a
                // copy icon on every copyable field, all the time, on every row,
                // would be exactly the "visually noisy" table this is meant to avoid.
                CTXCopyIconButton(value: value)
                    .opacity(isRowHovered ? 1 : 0)
                    .allowsHitTesting(isRowHovered)
            }
        }
        .frame(width: width, alignment: column.alignment == .trailing ? .trailing : .leading)
    }

    private func rowBackground(_ row: KubernetesResourceRow) -> Color {
        if row.id == selectedRowID {
            return Color.accentColor.opacity(0.14)
        }
        if row.warning {
            return Color.orange.opacity(0.035)
        }
        return .clear
    }

    /// Column set + width resolution for one available width:
    /// 1. Drop `hideOnCompact` columns when compact.
    /// 2. If even minimum widths don't fit, drop lowest-priority columns one at a
    ///    time (their data is still reachable — the inspector shows everything).
    /// 3. Give every remaining column its ideal width, then hand any leftover space
    ///    entirely to the one `isFlexible` column so the table fills the workspace
    ///    instead of floating as a narrow island on wide windows.
    static func resolve(_ columns: [CTXTableColumn], availableWidth: CGFloat, isCompact: Bool) -> [(CTXTableColumn, CGFloat)] {
        var candidates = isCompact ? columns.filter { !$0.hideOnCompact } : columns
        if candidates.isEmpty { candidates = columns }

        let spacingAndPadding: (Int) -> CGFloat = { count in
            CGFloat(max(0, count - 1)) * 12 + 28
        }

        var byPriorityAscending = candidates.enumerated().sorted { lhs, rhs in
            lhs.element.priority == rhs.element.priority ? lhs.offset > rhs.offset : lhs.element.priority < rhs.element.priority
        }.map(\.element)

        while candidates.count > 1 {
            let minSum = candidates.reduce(0, { $0 + $1.minWidth }) + spacingAndPadding(candidates.count)
            guard minSum > availableWidth, let dropped = byPriorityAscending.first(where: { candidate in candidates.contains(where: { $0.id == candidate.id }) }) else { break }
            candidates.removeAll { $0.id == dropped.id }
            byPriorityAscending.removeAll { $0.id == dropped.id }
        }

        // Keep the kind's declared left-to-right order for whatever survived.
        let kept = Set(candidates.map(\.id))
        let ordered = columns.filter { kept.contains($0.id) }

        let idealSum = ordered.reduce(0, { $0 + $1.idealWidth }) + spacingAndPadding(ordered.count)
        let extra = availableWidth - idealSum

        guard extra > 0, let flexibleIndex = ordered.firstIndex(where: { $0.isFlexible }) else {
            return ordered.map { ($0, $0.idealWidth) }
        }

        var widths = ordered.map { $0.idealWidth }
        widths[flexibleIndex] += extra
        return zip(ordered, widths).map { ($0, $1) }
    }
}

private struct TableWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 900

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
