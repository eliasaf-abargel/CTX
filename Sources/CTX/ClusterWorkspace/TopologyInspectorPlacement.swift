import SwiftUI

/// Where the selection inspector sits over the map, and which part of the map it
/// therefore covers.
///
/// The canvas is always the whole pane, so the inspector is a cover rather than a
/// column and selecting a node never re-lays out the graph. The rect is computed
/// rather than measured because the scroll-wheel router needs the same geometry
/// the card is drawn with: a measured rect would describe where the card was one
/// frame ago, which is exactly when a scroll lands in the wrong place.
struct TopologyInspectorPlacement {
    enum Style {
        case floating
        case drawer
    }

    /// Under this width a 340pt card leaves too little map beside it to be worth
    /// reading, so the inspector becomes a bottom drawer instead.
    static let drawerBreakpoint: CGFloat = 760

    let style: Style
    let rect: CGRect

    init(viewport: CGSize) {
        if viewport.width < Self.drawerBreakpoint {
            let inset: CGFloat = 12
            let height = max(0, min(viewport.height - inset * 2, viewport.height * 0.46))
            style = .drawer
            rect = CGRect(
                x: inset,
                y: max(inset, viewport.height - inset - height),
                width: max(0, viewport.width - inset * 2),
                height: height
            )
        } else {
            let inset: CGFloat = 16
            let width = min(340, max(0, viewport.width - inset * 2))
            style = .floating
            rect = CGRect(
                x: max(inset, viewport.width - inset - width),
                y: inset,
                width: width,
                height: max(0, viewport.height - inset * 2)
            )
        }
    }
}

private struct TopologyPointerExclusionKey: EnvironmentKey {
    static let defaultValue = CGRect.null
}

extension EnvironmentValues {
    /// The region of the canvas the inspector covers, in the canvas's own
    /// coordinates. Pointer-driven map interaction that AppKit routes outside
    /// SwiftUI's hit testing — the scroll wheel and the trackpad pinch — has to
    /// exclude it by hand, or the map pans under a card the pointer is reading.
    var topologyPointerExclusion: CGRect {
        get { self[TopologyPointerExclusionKey.self] }
        set { self[TopologyPointerExclusionKey.self] = newValue }
    }
}
