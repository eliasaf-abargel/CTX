import CTXCore
import SwiftUI

/// A one-shot instruction from the toolbar. The canvas owns the viewport
/// transform, so the buttons ask for a change rather than writing `scale`
/// themselves — assigning scale from outside moved the graph off centre,
/// because zoom without a pivot is a translation too.
enum TopologyMapCommand {
    case zoomIn
    case zoomOut
    case fit
}

/// The cluster map.
///
/// Everything — edges, node pills, labels — is drawn into a **single** `Canvas`
/// by ``TopologyCanvasSurface``. That is not a micro-optimisation: the previous
/// version placed one SwiftUI view per node inside a `ZStack` sized to the whole
/// graph and then applied `scaleEffect` to it. `scaleEffect` forces the entire
/// scaled subtree to be rasterised offscreen, so a 140-object namespace asked
/// AppKit for a 1460×4464 render target with a material blur behind every node.
/// The app hung and the canvas came back empty. One Canvas costs the same
/// whether it draws six nodes or six hundred.
///
/// This view exists to decide one thing: which structure the surface is drawing.
/// Keying the surface on the graph's structural identity is what separates the
/// two kinds of change the map receives. A new or removed object rebuilds the
/// surface — new layout, refitted viewport. A pod going CrashLoopBackOff, or a
/// group's name counting down, reuses it, so the pan and zoom the user set
/// survive.
///
/// Whether there is anything to map at all — and whether emptiness means
/// "loading" or "nothing here" — is decided by the pane above, which owns the
/// loading state this view cannot see.
struct ClusterDAGGraphView: View {
    let graph: ClusterTopologyGraph
    let groupsByNodeID: [String: TopologyProjectedGroup]
    let onExpandGroup: (String) -> Void
    /// Reported outward for the toolbar's percentage readout; only the canvas
    /// ever writes it.
    @Binding var scale: CGFloat
    @Binding var command: TopologyMapCommand?
    /// Owned by the parent, so the canvas and the sidebar can never describe two
    /// different objects.
    @Binding var selectedNodeID: String?

    /// A ceiling on honesty rather than on performance — the Canvas will happily
    /// draw thousands, but past this the columns are taller than any screen and
    /// the names are unreadable at the zoom needed to fit them.
    private static let renderLimit = 1200

    var body: some View {
        if graph.nodes.count > Self.renderLimit {
            CTXEmptyStateView(
                title: "\(graph.nodes.count) objects is too many to read at once",
                message: "Choose a narrower namespace or search for an object above. Add + to include its directed lineage.",
                systemImage: "square.grid.3x3.topleft.filled"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // There is no canvas to carry it out, and a zoom queued against a
            // map the user cannot see must not fire when one reappears.
            .onChange(of: command, initial: true) { _, request in
                if request != nil { command = nil }
            }
        } else {
            TopologyCanvasSurface(
                graph: graph,
                groupsByNodeID: groupsByNodeID,
                onExpandGroup: onExpandGroup,
                scale: $scale,
                command: $command,
                selectedNodeID: $selectedNodeID
            )
            .id(TopologyStructuralIdentity(graph))
        }
    }
}
