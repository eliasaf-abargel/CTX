import AppKit
import SwiftUI

/// Which windows get CTX's chromeless, vibrant treatment.
///
/// Opt-in on purpose. The app delegate used to clear the background of every
/// titled window that became key, so the Settings window was transparent too —
/// and an `NSOpenPanel` run over it had the desktop showing through behind it.
/// Only the windows CTX actually designs ask for that treatment; everything
/// else, now and later, is a normal macOS window.
@MainActor
enum CTXWindowChrome {
    private static var chromeless = Set<ObjectIdentifier>()

    static func markChromeless(_ window: NSWindow) {
        chromeless.insert(ObjectIdentifier(window))
        apply(to: window)
    }

    static func apply(to window: NSWindow) {
        guard window.styleMask.contains(.titled),
              chromeless.contains(ObjectIdentifier(window)) else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.titlebarSeparatorStyle = .none
    }
}

private struct ChromelessWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window until it is in the hierarchy.
        DispatchQueue.main.async {
            if let window = view.window {
                CTXWindowChrome.markChromeless(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            CTXWindowChrome.markChromeless(window)
        }
    }
}

extension View {
    /// Marks this view's window as one of CTX's own designed windows.
    func ctxChromelessWindow() -> some View {
        background(ChromelessWindowMarker())
    }
}
