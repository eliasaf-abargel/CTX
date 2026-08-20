import CoreGraphics

/// A spatial index over topology node frames.
///
/// Layout columns do not overlap horizontally and rows within a column do not
/// overlap vertically, so hit testing needs two binary searches instead of a
/// scan through every graph node.
public struct TopologyHitIndex: Sendable {
    public enum Direction: Sendable {
        case left
        case right
        case up
        case down
    }

    private struct Entry: Sendable {
        let id: String
        let frame: CGRect
    }

    private struct Column: Sendable {
        let minX: CGFloat
        let maxX: CGFloat
        let entries: [Entry]
    }

    private let columns: [Column]
    private let locations: [String: (column: Int, row: Int)]

    /// Every node in drawn order: column by column, top to bottom inside each.
    /// This is the order a sighted user reads the map in, so it is also the
    /// order assistive technology should walk it in.
    public let orderedNodeIDs: [String]

    public init(layout: TopologyGraphLayout.Result) {
        let entries = layout.positions.map { id, position in
            Entry(
                id: id,
                frame: CGRect(
                    x: position.x,
                    y: position.y,
                    width: TopologyGraphLayout.nodeWidth,
                    height: TopologyGraphLayout.nodeHeight
                )
            )
        }
        let grouped = Dictionary(grouping: entries, by: \.frame.minX)
        columns = grouped.keys.sorted().map { x in
            let sorted = grouped[x, default: []].sorted {
                ($0.frame.minY, $0.id) < ($1.frame.minY, $1.id)
            }
            return Column(
                minX: x,
                maxX: sorted.map(\.frame.maxX).max() ?? x,
                entries: sorted
            )
        }

        var locations: [String: (column: Int, row: Int)] = [:]
        for (columnIndex, column) in columns.enumerated() {
            for (rowIndex, entry) in column.entries.enumerated() {
                locations[entry.id] = (columnIndex, rowIndex)
            }
        }
        self.locations = locations
        orderedNodeIDs = columns.flatMap { $0.entries.map(\.id) }
    }

    /// The frame the node occupies in graph coordinates.
    public func frame(of id: String) -> CGRect? {
        guard let location = locations[id] else { return nil }
        return columns[location.column].entries[location.row].frame
    }

    /// Returns the identifier whose frame contains `point`, if any.
    public func nodeID(at point: CGPoint) -> String? {
        guard let columnIndex = containingColumn(for: point.x) else { return nil }
        let entries = columns[columnIndex].entries
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if entries[middle].frame.maxY < point.y {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < entries.count, entries[lower].frame.contains(point) else { return nil }
        return entries[lower].id
    }

    /// Returns the nearest node in a layout direction.
    public func neighbor(of id: String, toward direction: Direction) -> String? {
        guard let location = locations[id] else { return nil }
        switch direction {
        case .up:
            guard location.row > 0 else { return nil }
            return columns[location.column].entries[location.row - 1].id
        case .down:
            let entries = columns[location.column].entries
            guard location.row + 1 < entries.count else { return nil }
            return entries[location.row + 1].id
        case .left:
            return closestNode(to: id, inColumn: location.column - 1)
        case .right:
            return closestNode(to: id, inColumn: location.column + 1)
        }
    }

    private func containingColumn(for x: CGFloat) -> Int? {
        var lower = 0
        var upper = columns.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if columns[middle].maxX < x {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < columns.count else { return nil }
        let column = columns[lower]
        return x >= column.minX && x <= column.maxX ? lower : nil
    }

    private func closestNode(to id: String, inColumn columnIndex: Int) -> String? {
        guard let source = locations[id],
              columns.indices.contains(columnIndex) else { return nil }
        let sourceY = columns[source.column].entries[source.row].frame.midY
        let entries = columns[columnIndex].entries
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if entries[middle].frame.midY < sourceY {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let candidates = [lower - 1, lower].filter(entries.indices.contains)
        return candidates.min {
            abs(entries[$0].frame.midY - sourceY) < abs(entries[$1].frame.midY - sourceY)
        }.map { entries[$0].id }
    }
}
