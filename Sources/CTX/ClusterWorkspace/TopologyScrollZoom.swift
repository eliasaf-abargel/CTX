import AppKit
import SwiftUI

/// Scroll-wheel and trackpad handling for the map, which SwiftUI has no API for.
///
/// `MagnificationGesture` covers a trackpad pinch and nothing else — a two-finger
/// scroll or a mouse wheel never reaches SwiftUI, so on a plain mouse the only
/// way to zoom was the toolbar buttons. This gives the map what every Mac graph
/// app does:
///
///   - scroll            → pan
///   - ⌘ or ⌥ + scroll   → zoom about the pointer
///   - pinch             → zoom about the pointer
///
/// It works through a **local event monitor** rather than by overriding
/// `scrollWheel(with:)`. AppKit delivers scroll events to whichever view wins
/// hit-testing, and this view sits behind the Canvas, so an override would never
/// fire; a monitor sees the event before dispatch. That also lets `hitTest`
/// return nil, leaving clicks, drags and hover entirely to SwiftUI.
struct TopologyScrollZoom: NSViewRepresentable {
    /// Pointer position in the view's own coordinates, top-left origin, to match
    /// the space SwiftUI hands the rest of the canvas.
    var onPan: (CGSize) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    /// The part of the map the selection inspector covers, in the same top-left
    /// coordinates. A monitor sees events before hit testing, so without this the
    /// map would pan while the pointer scrolled the inspector's own list.
    var exclusion: CGRect

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        update(view)
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        update(view)
    }

    private func update(_ view: Catcher) {
        view.onPan = onPan
        view.onZoom = onZoom
        view.exclusion = exclusion
    }

    final class Catcher: NSView {
        var onPan: ((CGSize) -> Void)?
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        var exclusion: CGRect = .null
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return stopWatching() }
            startWatching()
        }

        private func startWatching() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                // Only claim events over the canvas, so the sheet's own sidebar
                // and any list behind it keep scrolling normally.
                guard self.bounds.contains(local) else { return event }
                let point = CGPoint(x: local.x, y: self.bounds.height - local.y)
                guard !self.exclusion.contains(point), !self.isOverCoveringScrollView(event) else {
                    return event
                }

                if event.type == .magnify {
                    self.onZoom?(1 + event.magnification, point)
                } else if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                    // A wheel notch carries a much larger delta than a trackpad
                    // glide, so scale the two differently or one click jumps.
                    let delta = event.hasPreciseScrollingDeltas
                        ? event.scrollingDeltaY * 0.01
                        : event.scrollingDeltaY * 0.04
                    self.onZoom?(1 + delta, point)
                } else {
                    self.onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                }
                return nil // consumed
            }
        }

        /// Whether AppKit would deliver this event to a scroll view drawn *over*
        /// the map rather than to the map itself.
        ///
        /// The exclusion rect already describes the inspector, so this is the
        /// backstop for anything else that lands on top — and it deliberately
        /// ignores scroll views the map is inside, whose scrolling is the very
        /// thing this monitor replaces.
        private func isOverCoveringScrollView(_ event: NSEvent) -> Bool {
            guard let hit = window?.contentView?.hitTest(event.locationInWindow) else { return false }
            var candidate: NSView? = hit
            while let view = candidate {
                if view is NSScrollView, !isDescendant(of: view) { return true }
                candidate = view.superview
            }
            return false
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Never intercept clicks — the monitor above needs no hit-testing, so
        /// this view can stay invisible to the mouse.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit { stopWatching() }
    }
}
