import CoreGraphics

/// Where the map sits inside the window.
///
/// Pure arithmetic on pan and zoom, kept apart from the canvas so the view is
/// left holding gestures, keys and drawing. Every result is absolute: the view
/// assigns it, and whether that assignment is animated is the view's decision.
enum TopologyViewportMath {
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 2.5
    static let inset: CGFloat = 24

    /// Scale so the graph fills the viewport, then centre it. Never enlarges
    /// past 1× — a three-node namespace blown up to 400% looks broken.
    static func fit(content: CGSize, in viewport: CGSize) -> (scale: CGFloat, pan: CGSize)? {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else {
            return nil
        }
        let scale = min(max(min(
            (viewport.width - inset * 2) / content.width,
            (viewport.height - inset * 2) / content.height
        ), minScale), 1.0)
        return (scale, CGSize(
            width: (viewport.width - content.width * scale) / 2,
            height: (viewport.height - content.height * scale) / 2
        ))
    }

    /// Keeps the point under the cursor fixed while zooming, the way every map
    /// does. Passing `nil` for `focus` zooms about the viewport centre.
    static func zoom(
        to target: CGFloat,
        around focus: CGPoint?,
        pan: CGSize,
        scale: CGFloat,
        viewport: CGSize
    ) -> (scale: CGFloat, pan: CGSize) {
        let next = min(max(target, minScale), maxScale)
        let pivot = focus ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let anchored = CGPoint(x: (pivot.x - pan.width) / scale, y: (pivot.y - pan.height) / scale)
        return (next, CGSize(
            width: pivot.x - anchored.x * next,
            height: pivot.y - anchored.y * next
        ))
    }

    /// Pan corrected so the graph still meets the viewport it is drawn in.
    ///
    /// A window the user narrows keeps the zoom they chose, but the pan that
    /// centred the graph in a 1400pt pane leaves it off the edge of a 600pt one.
    /// An axis whose scaled content is smaller than the viewport is centred; an
    /// axis larger than it is held so the content's edges cannot come inside the
    /// viewport's and expose empty space.
    static func contain(
        content: CGSize,
        scale: CGFloat,
        pan: CGSize,
        viewport: CGSize
    ) -> CGSize {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else {
            return pan
        }
        return CGSize(
            width: contained(pan.width, content: content.width * scale, viewport: viewport.width),
            height: contained(pan.height, content: content.height * scale, viewport: viewport.height)
        )
    }

    private static func contained(_ offset: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat {
        guard content > viewport else { return (viewport - content) / 2 }
        return min(max(offset, viewport - content), 0)
    }

    /// The smallest pan that puts a node's frame fully inside the viewport, or
    /// `.zero` when it already is. A node taller or wider than the viewport is
    /// aligned to its leading edge rather than pushed off the opposite one.
    static func shift(
        toReveal frame: CGRect,
        pan: CGSize,
        scale: CGFloat,
        viewport: CGSize
    ) -> CGSize {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let onScreen = CGRect(
            x: frame.minX * scale + pan.width,
            y: frame.minY * scale + pan.height,
            width: frame.width * scale,
            height: frame.height * scale
        )
        var shift = CGSize.zero
        if onScreen.minX < inset {
            shift.width = inset - onScreen.minX
        } else if onScreen.maxX > viewport.width - inset {
            shift.width = max(viewport.width - inset - onScreen.maxX, inset - onScreen.minX)
        }
        if onScreen.minY < inset {
            shift.height = inset - onScreen.minY
        } else if onScreen.maxY > viewport.height - inset {
            shift.height = max(viewport.height - inset - onScreen.maxY, inset - onScreen.minY)
        }
        return shift
    }
}
