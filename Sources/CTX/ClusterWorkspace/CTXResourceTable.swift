import AppKit
import CTXCore
import SwiftUI

/// One column with its resolved on-screen width.
///
/// A struct rather than a `(CTXTableColumn, CGFloat)` tuple: tuples cannot conform
/// to `Equatable`, so a row holding an array of them could never be compared, and
/// SwiftUI had to re-evaluate every visible row on any change to the table.
struct ResolvedColumn: Identifiable, Equatable {
    var id: String { column.id }
    let column: CTXTableColumn
    let width: CGFloat
}

/// Shared, kind-agnostic resource table. Column set, widths, alignment, and which
/// field gets a copy icon all come from `CTXResourceColumns` — no per-screen
/// hand-rolled table code.
struct CTXResourceTable: View {
    let targetKind: KubernetesResourceKind?
    let targetSection: ClusterWorkspaceSection?
    let rows: [KubernetesResourceRow]
    let selectedRowID: String?
    /// Whether the workspace is currently scoped to "All namespaces." When false
    /// (a single namespace is selected), every visible row shares the same
    /// namespace, so the Namespace column is dropped — it wouldn't say anything a
    /// row doesn't already imply, just take up space and add a column to scan.
    let showsNamespaceColumn: Bool
    let onSelect: (KubernetesResourceRow) -> Void

    init(
        kind: KubernetesResourceKind? = nil,
        section: ClusterWorkspaceSection? = nil,
        rows: [KubernetesResourceRow],
        selectedRowID: String?,
        showsNamespaceColumn: Bool,
        onSelect: @escaping (KubernetesResourceRow) -> Void
    ) {
        self.targetKind = kind
        self.targetSection = section
        self.rows = rows
        self.selectedRowID = selectedRowID
        self.showsNamespaceColumn = showsNamespaceColumn
        self.onSelect = onSelect
    }

    @State private var availableWidth: CGFloat = 900
    @State private var hoveredRowID: String?
    /// How many rows are currently built.
    ///
    /// The table shares the page's scroll view, so its `LazyVStack` has no vertical
    /// viewport to be lazy against and builds every row it is handed — roughly ten
    /// cell views each. Handing it the whole list means thousands of views
    /// constructed synchronously on the main thread the moment a fetch lands or a
    /// section changes, which is the freeze. A window that grows as the last row
    /// comes into view keeps that bounded without changing the layout.
    @State private var displayLimit = Self.initialWindow

    static let initialWindow = 100
    private static let windowGrowth = 150

    private var visibleRows: [KubernetesResourceRow] {
        rows.count <= displayLimit ? rows : Array(rows.prefix(displayLimit))
    }
    /// Cached result of `resolve()` — only recomputed when `availableWidth` or
    /// `allColumns` changes, not on every hover or selection state update.
    @State private var resolvedColumns: [ResolvedColumn] = []

    /// Derived from the table's own measured width rather than passed in from the
    /// caller — one less piece of width-tracking state duplicated across views.
    /// Uses the same breakpoint as the rest of the workspace (`ClusterWorkspaceLayoutMode`).
    private var isCompact: Bool {
        ClusterWorkspaceLayoutMode(width: availableWidth) == .compact
    }

    private var allColumns: [CTXTableColumn] {
        let columns: [CTXTableColumn]
        if let targetSection {
            columns = CTXResourceColumns.columns(for: targetSection)
        } else if let targetKind {
            columns = CTXResourceColumns.columns(for: targetKind)
        } else {
            columns = CTXResourceColumns.columns(for: KubernetesResourceKind.pods)
        }
        return showsNamespaceColumn ? columns : columns.filter { $0.key != "Namespace" }
    }

    var body: some View {
        let resolved = resolvedColumns.isEmpty ? Self.resolve(allColumns, availableWidth: availableWidth, isCompact: isCompact) : resolvedColumns
        let calculatedWidth = resolved.reduce(rowHorizontalPadding * 2) { $0 + $1.width } + CGFloat(max(0, resolved.count - 1)) * columnSpacing
        let contentWidth = max(availableWidth, calculatedWidth)

        return VStack(alignment: .leading, spacing: 0) {
            CTXGlassPanel(padding: 0) {
                // The page's own scroll view supplies the vertical axis, so this one
                // only handles horizontal overflow — exactly as before. Giving the
                // table a second, vertical scroll view is what would let the
                // `LazyVStack` build only visible rows, but nesting one inside the
                // page scroll view broke the layout of every list screen. The caller
                // bounds the row count instead.
                ScrollView(.horizontal) {
                    LazyVStack(spacing: 0) {
                        headerRow(resolved)
                        Divider()
                        ForEach(visibleRows) { row in
                            ResourceRowView(
                                row: row,
                                resolved: resolved,
                                isSelected: row.id == selectedRowID,
                                isHovered: row.id == hoveredRowID,
                                rowHorizontalPadding: rowHorizontalPadding,
                                columnSpacing: columnSpacing,
                                onSelect: onSelect,
                                onHoverChange: { hovering in
                                    if hovering {
                                        hoveredRowID = row.id
                                    } else if hoveredRowID == row.id {
                                        hoveredRowID = nil
                                    }
                                }
                            )
                            .equatable()
                            .onAppear {
                                guard row.id == visibleRows.last?.id, displayLimit < rows.count else { return }
                                displayLimit = min(displayLimit + Self.windowGrowth, rows.count)
                            }
                            Divider().opacity(0.45)
                        }

                        if rows.count > visibleRows.count {
                            HStack {
                                Spacer()
                                Button {
                                    displayLimit = rows.count
                                } label: {
                                    Text("Show all \(rows.count) items")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 8)
                                Spacer()
                            }
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
        .onPreferenceChange(TableWidthPreferenceKey.self) { newWidth in
            // Guard against micro-changes (< 1pt) to avoid redundant resolve() calls
            // on every layout pass — the table is pixel-aligned so sub-point diffs
            // never change the resolved column widths anyway.
            guard abs(newWidth - availableWidth) > 1 else { return }
            availableWidth = newWidth
            resolvedColumns = Self.resolve(allColumns, availableWidth: newWidth, isCompact: ClusterWorkspaceLayoutMode(width: newWidth) == .compact)
        }
        .onChange(of: targetSection) { _, _ in
            displayLimit = Self.initialWindow
            resolvedColumns = Self.resolve(allColumns, availableWidth: availableWidth, isCompact: isCompact)
        }
        .onChange(of: targetKind) { _, _ in
            displayLimit = Self.initialWindow
            resolvedColumns = Self.resolve(allColumns, availableWidth: availableWidth, isCompact: isCompact)
        }
        .onChange(of: rows.count) { _, newCount in
            // A filter that narrows the list must not leave the window wider than
            // the list itself, and a fresh fetch starts from the top again.
            displayLimit = min(max(displayLimit, Self.initialWindow), max(newCount, Self.initialWindow))
        }
        .onChange(of: showsNamespaceColumn) { _, _ in
            resolvedColumns = Self.resolve(allColumns, availableWidth: availableWidth, isCompact: isCompact)
        }
    }

    private let rowHorizontalPadding: CGFloat = 14
    private let columnSpacing: CGFloat = 12

    private func headerRow(_ resolved: [ResolvedColumn]) -> some View {
        HStack(spacing: columnSpacing) {
            ForEach(resolved) { resolvedColumn in
                Text(resolvedColumn.column.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: resolvedColumn.width, alignment: resolvedColumn.column.alignment == .trailing ? .trailing : .leading)
            }
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, 9)
    }







    /// Column set + width resolution for one available width:
    /// 1. Drop `hideOnCompact` columns when compact.
    /// 2. If even minimum widths don't fit, drop lowest-priority columns one at a
    ///    time (their data is still reachable — the inspector shows everything).
    /// 3. Give every remaining column its ideal width, then hand any leftover space
    ///    entirely to the one `isFlexible` column so the table fills the workspace
    ///    instead of floating as a narrow island on wide windows.
    static func resolve(_ columns: [CTXTableColumn], availableWidth: CGFloat, isCompact: Bool) -> [ResolvedColumn] {
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

        guard extra > 0 else {
            return ordered.map { ResolvedColumn(column: $0, width: $0.idealWidth) }
        }

        let flexibleIndices = ordered.enumerated().filter {
            $0.element.isFlexible || $0.element.key == "Name" || $0.element.key == "Node" || $0.element.key == "Namespace"
        }.map(\.offset)

        var widths = ordered.map { $0.idealWidth }
        if !flexibleIndices.isEmpty {
            let addPerCol = extra / CGFloat(flexibleIndices.count)
            for idx in flexibleIndices {
                widths[idx] += addPerCol
            }
        } else if let flexibleIndex = ordered.firstIndex(where: { $0.isFlexible }) {
            widths[flexibleIndex] += extra
        }
        return zip(ordered, widths).map { ResolvedColumn(column: $0, width: $1) }
    }
}

private struct TableWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 900

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Isolated row view — giving each row its own struct lets SwiftUI identity-diff
/// rows independently. Without this, any @State change on `CTXResourceTable`
/// (e.g. hoveredRowID) caused *all* rows to re-render in the same body call.
private struct ResourceRowView: View, Equatable {
    let row: KubernetesResourceRow
    let resolved: [ResolvedColumn]
    /// Booleans rather than the selected/hovered ids: with the ids, every row in
    /// the list held a property that changed whenever *any* row was hovered, so
    /// SwiftUI had to re-evaluate all of them. Only the two rows whose own state
    /// actually flipped change value now.
    let isSelected: Bool
    let isHovered: Bool
    let rowHorizontalPadding: CGFloat
    let columnSpacing: CGFloat
    let onSelect: (KubernetesResourceRow) -> Void
    let onHoverChange: (Bool) -> Void

    /// Closures are never equal, so the synthesized conformance would always report
    /// "changed". Comparing only the data lets SwiftUI skip rows that really are
    /// unchanged — the whole point of splitting rows into their own view.
    static func == (lhs: ResourceRowView, rhs: ResourceRowView) -> Bool {
        lhs.row == rhs.row
            && lhs.isSelected == rhs.isSelected
            && lhs.isHovered == rhs.isHovered
            && lhs.resolved == rhs.resolved
            && lhs.rowHorizontalPadding == rhs.rowHorizontalPadding
            && lhs.columnSpacing == rhs.columnSpacing
    }

    var body: some View {
        HStack(spacing: columnSpacing) {
            ForEach(resolved) { resolvedColumn in
                cell(column: resolvedColumn.column, width: resolvedColumn.width)
            }
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .background(background, in: Rectangle())
        .onTapGesture { onSelect(row) }
        .onHover { onHoverChange($0) }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isHovered  { return Color.primary.opacity(0.06) }
        if row.warning { return Color.orange.opacity(0.04) }
        return .clear
    }

    @ViewBuilder
    private func cell(column: CTXTableColumn, width: CGFloat) -> some View {
        let value = row.cells[column.key] ?? "-"
        HStack(spacing: 4) {
            if (column.key == "Status" || column.key == "Ready") && value != "-" {
                statusBadge(value, warning: row.warning)
            } else if (column.key == "CPU" || column.key == "Memory" || column.key == "Disk") && value != "-" {
                telemetryCellBadge(key: column.key, value: value)
            } else if column.key == "Name" && !value.isEmpty && value != "-" {
                TechBrandIconView(name: value)
            } else {
                Text(value)
                    .font(.system(size: 12, design: column.monospaced ? .monospaced : .default))
                    .foregroundStyle(row.warning && column.key == "Status" ? .orange : .primary)
                    .lineLimit(column.key == "Message" ? 2 : 1)
                    .truncationMode(.middle)
                    // A tooltip installs its own tracking area, so this is limited
                    // to the columns whose text is actually long enough to be
                    // elided rather than applied to every cell in the table.
                    .help(column.isFlexible || column.key == "Message" ? value : "")
                    .multilineTextAlignment(column.alignment == .trailing ? .trailing : .leading)
            }

            // Built only while the row is hovered. Keeping it always-present at
            // zero opacity meant a stateful Button, with its own hover tracking,
            // existed for every copyable cell of every visible row.
            if column.copyable && value != "-" && isHovered {
                CTXCopyIconButton(value: value)
            }
        }
        .frame(width: width, alignment: column.alignment == .trailing ? .trailing : .leading)
    }

    private func statusBadge(_ text: String, warning: Bool) -> some View {
        let lower = text.lowercased()
        let isSuccess = lower == "running" || lower == "ready" || lower == "succeeded"
            || lower == "1/1" || lower == "2/2" || lower == "3/3"
        let color: Color = isSuccess ? .green : (warning ? .orange : .secondary)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func telemetryCellBadge(key: String, value: String) -> some View {
        let isCPU = key == "CPU"
        let isMem = key == "Memory"
        let icon = isCPU ? "cpu" : (isMem ? "memorychip" : "internaldrive")
        let color: Color = isCPU ? .cyan : (isMem ? .purple : .indigo)
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 0.75)
        }
    }
}
