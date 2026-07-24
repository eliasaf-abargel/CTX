import AppKit
import CTXCore
import SwiftUI

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
        let resolved = Self.resolve(allColumns, availableWidth: availableWidth, isCompact: isCompact)
        let calculatedWidth = resolved.reduce(rowHorizontalPadding * 2) { $0 + $1.1 } + CGFloat(max(0, resolved.count - 1)) * columnSpacing
        let contentWidth = max(availableWidth, calculatedWidth)

        return VStack(alignment: .leading, spacing: 0) {
            CTXGlassPanel(padding: 0) {
                ScrollView(.horizontal) {
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
                    .lineLimit(1)
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
        .background(rowBackground(row, isHovered: isHovered), in: Rectangle())
        .onTapGesture { onSelect(row) }
        .onHover { hovering in
            if hovering {
                hoveredRowID = row.id
            } else if hoveredRowID == row.id {
                hoveredRowID = nil
            }
        }
    }

    @ViewBuilder
    private func cell(_ row: KubernetesResourceRow, column: CTXTableColumn, width: CGFloat, isRowHovered: Bool) -> some View {
        let value = row.cells[column.key] ?? "-"
        HStack(spacing: 4) {
            if (column.key == "Status" || column.key == "Ready") && value != "-" {
                statusBadge(value, warning: row.warning)
            } else if (column.key == "CPU" || column.key == "Memory" || column.key == "Disk") && value != "-" {
                telemetryCellBadge(key: column.key, value: value)
            } else if column.key == "Name" && isKnownBrand(value) {
                TechBrandIconView(name: value)
            } else {
                Text(value)
                    .font(.system(size: 12, design: column.monospaced ? .monospaced : .default))
                    .foregroundStyle(row.warning && column.key == "Status" ? .orange : .primary)
                    .lineLimit(column.key == "Message" ? 2 : 1)
                    .truncationMode(.middle)
                    .help(value)
                    .multilineTextAlignment(column.alignment == .trailing ? .trailing : .leading)
            }

            if column.copyable && value != "-" {
                CTXCopyIconButton(value: value)
                    .opacity(isRowHovered ? 1 : 0)
                    .allowsHitTesting(isRowHovered)
            }
        }
        .frame(width: width, alignment: column.alignment == .trailing ? .trailing : .leading)
    }

    private func isKnownBrand(_ name: String) -> Bool {
        !name.isEmpty && name != "-"
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

    private func statusBadge(_ text: String, warning: Bool) -> some View {
        let lower = text.lowercased()
        let isSuccess = lower == "running" || lower == "ready" || lower == "succeeded" || lower == "1/1" || lower == "2/2" || lower == "3/3"
        let color: Color = isSuccess ? .green : (warning ? .orange : .secondary)

        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func rowBackground(_ row: KubernetesResourceRow, isHovered: Bool) -> Color {
        if row.id == selectedRowID {
            return Color.accentColor.opacity(0.18)
        }
        if isHovered {
            return Color.primary.opacity(0.06)
        }
        if row.warning {
            return Color.orange.opacity(0.04)
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

        guard extra > 0 else {
            return ordered.map { ($0, $0.idealWidth) }
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
        return zip(ordered, widths).map { ($0, $1) }
    }
}

private struct TableWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 900

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
