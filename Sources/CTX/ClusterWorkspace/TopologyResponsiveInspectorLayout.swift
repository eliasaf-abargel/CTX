import SwiftUI

/// The canvas, with the selection inspector laid over it.
///
/// The inspector is an `overlay` sized to the card, not a full-pane container
/// holding a card: a container would cover the map with a transparent sheet that
/// swallows every click, drag and hover outside the card itself. Only the card's
/// own bounds exist as far as hit testing is concerned, so the map stays
/// interactive everywhere the card is not drawn.
struct TopologyResponsiveInspectorLayout<CanvasContent: View, InspectorContent: View>: View {
    let isPresented: Bool
    @ViewBuilder let canvas: () -> CanvasContent
    @ViewBuilder let inspector: () -> InspectorContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let placement = TopologyInspectorPlacement(viewport: proxy.size)

            canvas()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .environment(\.topologyPointerExclusion, isPresented ? placement.rect : .null)
                .overlay(alignment: .topLeading) {
                    if isPresented {
                        card(placement)
                    }
                }
        }
    }

    private func card(_ placement: TopologyInspectorPlacement) -> some View {
        inspector()
            .frame(width: placement.rect.width, height: placement.rect.height)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: placement.style == .floating ? 12 : 8, y: 4)
            .offset(x: placement.rect.minX, y: placement.rect.minY)
            .transition(transition(for: placement.style))
    }

    private func transition(for style: TopologyInspectorPlacement.Style) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        switch style {
        case .floating: return .move(edge: .trailing).combined(with: .opacity)
        case .drawer: return .move(edge: .bottom).combined(with: .opacity)
        }
    }
}
