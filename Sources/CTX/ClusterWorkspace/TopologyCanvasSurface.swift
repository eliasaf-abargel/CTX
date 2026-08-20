import CTXCore
import SwiftUI

/// The interactive canvas for one structure of the map.
///
/// The view above gives this a `.id` of the graph's structural identity, so a
/// new object or connection produces a *new* surface: fresh layout, fresh pan
/// and zoom, fitted to the viewport. Everything that leaves the structure alone
/// — health, names, selection, hover — reuses this instance and therefore
/// leaves the viewport exactly where the user put it.
struct TopologyCanvasSurface: View {
    let graph: ClusterTopologyGraph
    let groupsByNodeID: [String: TopologyProjectedGroup]
    let onExpandGroup: (String) -> Void
    @Binding var scale: CGFloat
    @Binding var command: TopologyMapCommand?
    @Binding var selectedNodeID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.topologyPointerExclusion) private var pointerExclusion
    @StateObject private var model: TopologyCanvasModel
    @State private var pan: CGSize = .zero
    @State private var panAnchor: CGSize = .zero
    @State private var scaleAnchor: CGFloat = 1
    @State private var hoveredNodeID: String?
    @State private var viewport: CGSize = .zero
    @State private var hasFitted = false
    @State private var hasOwnViewport = false
    @State private var keyboardNodeID: String?
    @FocusState private var acceptsKeyboardInput: Bool

    init(
        graph: ClusterTopologyGraph,
        groupsByNodeID: [String: TopologyProjectedGroup],
        onExpandGroup: @escaping (String) -> Void,
        scale: Binding<CGFloat>,
        command: Binding<TopologyMapCommand?>,
        selectedNodeID: Binding<String?>
    ) {
        self.graph = graph
        self.groupsByNodeID = groupsByNodeID
        self.onExpandGroup = onExpandGroup
        _scale = scale
        _command = command
        _selectedNodeID = selectedNodeID
        _model = StateObject(wrappedValue: TopologyCanvasModel(graph: graph))
    }

    var body: some View {
        GeometryReader { proxy in
            canvas
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onChange(of: proxy.size, initial: true) { _, size in
                    viewport = size
                    reflow()
                }
        }
        .onChange(of: TopologyPresentationIdentity(graph)) { _, _ in
            model.refreshLabels(for: graph)
        }
        .onChange(of: command) { _, request in
            guard let request else { return }
            switch request {
            case .zoomIn: animate { zoom(to: scale * 1.25, around: nil) }
            case .zoomOut: animate { zoom(to: scale / 1.25, around: nil) }
            case .fit: fit()
            }
            command = nil
        }
        // The caret and the selection describe the same object, so a selection
        // cleared anywhere else — Escape, a scope switch, a node the projection
        // dropped — must not leave a caret pointing at nothing.
        .onChange(of: selectedNodeID) { _, id in
            keyboardNodeID = id
        }
    }

    private func fit(animated: Bool = true) {
        guard let fitted = TopologyViewportMath.fit(content: model.layout.size, in: viewport) else { return }
        hasFitted = true
        hasOwnViewport = false
        let apply = {
            scale = fitted.scale
            pan = fitted.pan
            panAnchor = fitted.pan
        }
        if animated { animate(apply) } else { apply() }
    }

    /// Keeps the graph in the pane as the pane changes size.
    ///
    /// Resizing the window otherwise leaves the map wherever a wider viewport
    /// put it, which is how a full map ends up as a thumbnail in the corner of a
    /// narrow one. A viewport the user has not moved themselves simply refits;
    /// once they have panned or zoomed, that is theirs to keep, so only the pan
    /// is corrected to keep the content against the edges. Neither is animated:
    /// a live window drag would spend every frame catching up.
    private func reflow() {
        guard hasFitted, hasOwnViewport else { return fit(animated: false) }
        let contained = TopologyViewportMath.contain(
            content: model.layout.size, scale: scale, pan: pan, viewport: viewport
        )
        guard contained != pan else { return }
        pan = contained
        panAnchor = contained
    }

    private var highlighted: Set<String>? {
        guard let anchor = selectedNodeID, graph.node(anchor) != nil else { return nil }
        return graph.ancestors(of: anchor).union(graph.descendants(of: anchor))
    }

    // MARK: - Drawing

    private var canvas: some View {
        let lit = highlighted
        return Canvas(rendersAsynchronously: false) { context, _ in
            context.translateBy(x: pan.width, y: pan.height)
            context.scaleBy(x: scale, y: scale)
            TopologyCanvasRenderer(
                graph: graph,
                layout: model.layout,
                labels: model.labels,
                scale: scale,
                highlighted: lit,
                selectedNodeID: selectedNodeID,
                hoveredNodeID: hoveredNodeID ?? keyboardNodeID
            ).draw(in: context)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            TopologyScrollZoom(
                onPan: { delta in
                    pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
                    panAnchor = pan
                    hasOwnViewport = true
                },
                onZoom: { factor, at in zoom(to: scale * factor, around: at) },
                exclusion: pointerExclusion
            )
        )
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hoveredNodeID = node(at: point)?.id
            case .ended: hoveredNodeID = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Below the threshold this is still a click, so don't move
                    // the graph out from under the pointer.
                    guard hypot(value.translation.width, value.translation.height) > 3 else { return }
                    pan = CGSize(
                        width: panAnchor.width + value.translation.width,
                        height: panAnchor.height + value.translation.height
                    )
                    hasOwnViewport = true
                }
                .onEnded { value in
                    acceptsKeyboardInput = true
                    if hypot(value.translation.width, value.translation.height) <= 3 {
                        // A click: select the node under it, or clear. The
                        // caret follows the selection, so it lands where the
                        // pointer did and arrows carry on from there.
                        let hit = node(at: value.startLocation)
                        animate {
                            selectedNodeID = (hit?.id == selectedNodeID) ? nil : hit?.id
                        }
                    }
                    panAnchor = pan
                }
        )
        .simultaneousGesture(
            // Anchored to the scale the pinch started from. Assigning the raw
            // gesture value (which begins at 1.0) made every pinch snap the
            // graph back to 100% before it moved.
            MagnificationGesture()
                .onChanged { value in zoom(to: scaleAnchor * value, around: nil) }
                .onEnded { _ in scaleAnchor = scale }
        )
        .onAppear { scaleAnchor = scale }
        .help(hoveredNodeID.flatMap { graph.node($0) }.map { TopologyNodeTooltip.text(for: $0, in: graph) } ?? "")
        .focusable()
        .focused($acceptsKeyboardInput)
        .onKeyPress(.leftArrow) { navigate(.left); return .handled }
        .onKeyPress(.rightArrow) { navigate(.right); return .handled }
        .onKeyPress(.upArrow) { navigate(.up); return .handled }
        .onKeyPress(.downArrow) { navigate(.down); return .handled }
        .onKeyPress(.return) { activate(); return .handled }
        .onKeyPress(.space) { activate(); return .handled }
        .onKeyPress(.escape) { clearSelection(); return .handled }
        .accessibilityRepresentation {
            TopologyCanvasAccessibility(
                graph: graph,
                layout: model.layout,
                orderedNodeIDs: model.hitIndex.orderedNodeIDs,
                groupsByNodeID: groupsByNodeID,
                selectedNodeID: selectedNodeID,
                pan: pan,
                scale: scale,
                onSelect: { focus($0) },
                onExpand: onExpandGroup
            )
        }
    }

    // MARK: - Interaction

    /// View point → graph point → whichever pill contains it.
    private func node(at point: CGPoint) -> TopologyGraphNode? {
        let inGraph = CGPoint(
            x: (point.x - pan.width) / scale,
            y: (point.y - pan.height) / scale
        )
        return model.hitIndex.nodeID(at: inGraph).flatMap(graph.node)
    }

    /// Arrows move one caret that *is* the selection: the inspector over the
    /// map describes whatever the caret is on, so arrowing through the graph
    /// reads out each object rather than requiring a second key to ask what was
    /// just landed on.
    private func navigate(_ direction: TopologyHitIndex.Direction) {
        guard let next = TopologyKeyboardNavigation.next(
            from: keyboardNodeID ?? selectedNodeID,
            toward: direction,
            in: graph,
            layout: model.layout,
            hitIndex: model.hitIndex
        ) else { return }
        focus(next)
    }

    /// Puts the caret on a node, selects it, and brings it into view.
    private func focus(_ id: String) {
        keyboardNodeID = id
        animate { selectedNodeID = id }
        reveal(id)
    }

    /// Return and Space act on what the caret is already on: a synthetic node
    /// stands for objects that are not drawn yet, so activating it expands it;
    /// a real object has nothing further to open, so activation confirms the
    /// selection the arrows made.
    private func activate() {
        guard let id = keyboardNodeID ?? selectedNodeID ?? model.hitIndex.orderedNodeIDs.first else { return }
        if groupsByNodeID[id] != nil {
            onExpandGroup(id)
            return
        }
        focus(id)
    }

    private func clearSelection() {
        keyboardNodeID = nil
        animate { selectedNodeID = nil }
    }

    /// Pans the smallest distance that puts the caret's pill fully inside the
    /// viewport. Arrowing towards a node the viewport does not cover would
    /// otherwise move a caret nobody can see.
    private func reveal(_ id: String) {
        guard let frame = model.layout.frame(id) else { return }
        let shift = TopologyViewportMath.shift(
            toReveal: frame, pan: pan, scale: scale, viewport: viewport
        )
        guard shift != .zero else { return }
        animate {
            pan = CGSize(width: pan.width + shift.width, height: pan.height + shift.height)
            panAnchor = pan
        }
    }

    private func zoom(to target: CGFloat, around pivot: CGPoint?) {
        let zoomed = TopologyViewportMath.zoom(
            to: target, around: pivot, pan: pan, scale: scale, viewport: viewport
        )
        scale = zoomed.scale
        pan = zoomed.pan
        panAnchor = pan
        hasOwnViewport = true
    }

    /// Fit, zoom, selection and caret movement are all conveniences rather than
    /// information, so Reduce Motion turns them into instant changes.
    private func animate(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.easeOut(duration: 0.18), changes)
        }
    }
}
