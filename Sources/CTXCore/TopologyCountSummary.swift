import Foundation

/// What the map is showing, phrased at three lengths.
///
/// One sentence cannot serve a toolbar that has to survive from a 1600pt window
/// down to a 500pt one. Written as a single long string it was also the widest
/// thing in the bar, so the labelled layout stopped fitting long before the
/// buttons in it actually ran out of room, and the whole toolbar dropped to
/// icons on displays with space to spare.
///
/// All three are derived from the same snapshot, so they cannot disagree about
/// the map the way independently assembled strings did.
public struct TopologyCountSummary: Equatable, Sendable {
    /// Every number, for the tooltip and the popover.
    public let full: String
    /// Drawn out of eligible, in words.
    public let medium: String
    /// Drawn out of eligible, as a ratio.
    public let short: String

    public init(
        visibleRealCount: Int,
        syntheticGroupCount: Int,
        eligibleCount: Int,
        projectionHiddenCount: Int
    ) {
        var full = "Showing \(visibleRealCount) real"
        if syntheticGroupCount > 0 {
            full += " + \(syntheticGroupCount) group\(syntheticGroupCount == 1 ? "" : "s")"
        }
        full += " · \(eligibleCount) filter-eligible"
        if projectionHiddenCount > 0 {
            full += " · \(projectionHiddenCount) grouped/omitted"
        }
        self.full = full

        if projectionHiddenCount > 0 {
            medium = "\(visibleRealCount) of \(eligibleCount) shown"
            short = "\(visibleRealCount)/\(eligibleCount)"
        } else {
            medium = "\(visibleRealCount) shown"
            short = "\(visibleRealCount)"
        }
    }

    public init(_ snapshot: TopologyMapSnapshot) {
        self.init(
            visibleRealCount: snapshot.visibleRealCount,
            syntheticGroupCount: snapshot.syntheticGroupCount,
            eligibleCount: snapshot.eligibleCount,
            projectionHiddenCount: snapshot.projectionHiddenCount
        )
    }
}
