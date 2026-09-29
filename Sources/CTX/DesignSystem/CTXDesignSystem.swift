import AppKit
import CTXCore
import SwiftUI

func copyToClipboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

/// The single authoritative CTX App Logo component rendering the exact official vector SVG icon (Resources/CTXIcon.svg).
public struct CTXAppLogoView: View {
    public var size: CGFloat = 28

    public init(size: CGFloat = 28) {
        self.size = size
    }

    private var cloudGradient: GraphicsContext.Shading {
        .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.227, green: 0.941, blue: 0.443), location: 0.0),   // #3AF071
                .init(color: Color(red: 0.133, green: 0.835, blue: 0.655), location: 0.46),  // #22D5A7
                .init(color: Color(red: 0.125, green: 0.529, blue: 1.0), location: 1.0)     // #2087FF
            ]),
            startPoint: CGPoint(x: size * (220.0 / 1024.0), y: size * (250.0 / 1024.0)),
            endPoint: CGPoint(x: size * (780.0 / 1024.0), y: size * (760.0 / 1024.0))
        )
    }

    private var innerGradient: GraphicsContext.Shading {
        .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.039, green: 0.051, blue: 0.059), location: 0.0),  // #0A0D0F
                .init(color: Color(red: 0.067, green: 0.090, blue: 0.102), location: 1.0)   // #11171A
            ]),
            startPoint: CGPoint(x: size * (330.0 / 1024.0), y: size * (375.0 / 1024.0)),
            endPoint: CGPoint(x: size * (685.0 / 1024.0), y: size * (676.0 / 1024.0))
        )
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 1024.0
            let transform = CGAffineTransform(scaleX: scale, y: scale)

            // Background Squircle #050708
            let bgPath = Path(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024), cornerRadius: 224, style: .continuous)
                .applying(transform)
            context.fill(bgPath, with: .color(Color(red: 0.02, green: 0.027, blue: 0.031)))

            // Outer Cloud Path
            let outerPath = Path { path in
                path.move(to: CGPoint(x: 286, y: 682))
                path.addLine(to: CGPoint(x: 708, y: 682))
                path.addCurve(to: CGPoint(x: 874, y: 522), control1: CGPoint(x: 800, y: 682), control2: CGPoint(x: 874, y: 611))
                path.addCurve(to: CGPoint(x: 730, y: 363), control1: CGPoint(x: 874, y: 440), control2: CGPoint(x: 811, y: 372))
                path.addCurve(to: CGPoint(x: 491, y: 190), control1: CGPoint(x: 697, y: 262), control2: CGPoint(x: 603, y: 190))
                path.addCurve(to: CGPoint(x: 242, y: 402), control1: CGPoint(x: 365, y: 190), control2: CGPoint(x: 260, y: 282))
                path.addCurve(to: CGPoint(x: 126, y: 543), control1: CGPoint(x: 175, y: 420), control2: CGPoint(x: 126, y: 476))
                path.addCurve(to: CGPoint(x: 286, y: 682), control1: CGPoint(x: 126, y: 620), control2: CGPoint(x: 194, y: 682))
                path.closeSubpath()
            }.applying(transform)

            // Inner Cloud Path (Cutout)
            let innerPath = Path { path in
                path.move(to: CGPoint(x: 324, y: 617))
                path.addLine(to: CGPoint(x: 699, y: 617))
                path.addCurve(to: CGPoint(x: 800, y: 523), control1: CGPoint(x: 755, y: 617), control2: CGPoint(x: 800, y: 575))
                path.addCurve(to: CGPoint(x: 706, y: 429), control1: CGPoint(x: 800, y: 473), control2: CGPoint(x: 759, y: 432))
                path.addLine(to: CGPoint(x: 673, y: 427))
                path.addLine(to: CGPoint(x: 663, y: 396))
                path.addCurve(to: CGPoint(x: 489, y: 273), control1: CGPoint(x: 639, y: 323), control2: CGPoint(x: 571, y: 273))
                path.addCurve(to: CGPoint(x: 306, y: 430), control1: CGPoint(x: 396, y: 273), control2: CGPoint(x: 319, y: 340))
                path.addLine(to: CGPoint(x: 301, y: 463))
                path.addLine(to: CGPoint(x: 269, y: 472))
                path.addCurve(to: CGPoint(x: 199, y: 553), control1: CGPoint(x: 228, y: 483), control2: CGPoint(x: 199, y: 515))
                path.addCurve(to: CGPoint(x: 264, y: 617), control1: CGPoint(x: 199, y: 588), control2: CGPoint(x: 228, y: 617))
                path.addLine(to: CGPoint(x: 324, y: 617))
                path.closeSubpath()
            }.applying(transform)

            // Lightning Bolt Path
            let boltPath = Path { path in
                path.move(to: CGPoint(x: 476, y: 360))
                path.addLine(to: CGPoint(x: 476, y: 456))
                path.addLine(to: CGPoint(x: 365, y: 456))
                path.addLine(to: CGPoint(x: 539, y: 664))
                path.addLine(to: CGPoint(x: 539, y: 540))
                path.addLine(to: CGPoint(x: 660, y: 540))
                path.addLine(to: CGPoint(x: 476, y: 360))
                path.closeSubpath()
            }.applying(transform)

            // Draw outer cloud
            context.fill(outerPath, with: cloudGradient)

            // Draw inner cloud cutout
            context.fill(innerPath, with: innerGradient)

            // Draw center bolt
            context.fill(boltPath, with: cloudGradient)
        }
        .frame(width: size, height: size)
    }
}

/// Small icon-only copy button with a brief checkmark confirmation. Not
/// keyboard-focusable — it's a dense inline affordance next to a value, not a
/// primary control, and a focus ring here reads as an unwanted "selected" look.
struct CTXCopyIconButton: View {
    let value: String
    @State private var justCopied = false

    var body: some View {
        Button {
            copyToClipboard(value)
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                justCopied = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation {
                    justCopied = false
                }
            }
        } label: {
            Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(justCopied ? .green : .secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(value.isEmpty)
        .help("Copy")
    }
}

struct CTXIconActionButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    /// Set when the button stands for a state rather than a one-shot action. An
    /// engaged filter has to look engaged even without a text label next to it,
    /// which is the only thing an icon-only toolbar has left to say it with.
    var isOn: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    private var tooltipWidth: CGFloat {
        min(max(CGFloat(title.count) * 7 + 24, 96), 150)
    }

    private var fill: Color {
        isOn
            ? tint.opacity(isHovering ? 0.32 : 0.24)
            : Color.secondary.opacity(isHovering ? 0.22 : 0.13)
    }

    private var stroke: Color {
        isOn
            ? tint.opacity(isHovering ? 0.6 : 0.48)
            : Color.secondary.opacity(isHovering ? 0.35 : 0.24)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 28)
                .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(stroke, lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.06 : 1.0)
        .focusable(false)
        .accessibilityLabel(title)
        .help(title)
        .onHover { hovering in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.75)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .frame(width: tooltipWidth)
                    .frame(minHeight: 24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.75)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                    .offset(y: -31)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

struct CTXGlassPanel<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .ctxGlassCard(cornerRadius: 14)
    }
}

struct CTXSectionHeader: View {
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct CTXStatusBadge: View {
    let title: String
    var systemImage: String = "circle.fill"
    var tint: Color = .secondary

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().stroke(tint.opacity(0.24), lineWidth: 0.75)
            }
            .help(title)
    }
}

struct CTXEnvironmentBadge: View {
    let environment: EnvironmentType

    var body: some View {
        CTXStatusBadge(title: environment.label, systemImage: environment.systemImage, tint: environment.tint)
    }
}

/// Small icon-only reload button. Shows a smooth continuous 360° spin while
/// `isLoading`, then a brief green checkmark when the action just fired —
/// same visual language as `CTXCopyIconButton`. Not keyboard-focusable.
///
/// **Why `@State var rotation`?**
/// SwiftUI's `rotationEffect(.degrees(isLoading ? 360 : 0))` animates once
/// from 0 → 360 and then resets, which produces the "oscillating/bouncing"
/// look. The only correct approach for a continuous spin is to store a
/// dedicated angle in `@State`, set it to 360 inside a
/// `.repeatForever(autoreverses: false)` block, and drive the effect from
/// that variable — not from a computed expression.
struct CTXReloadIconButton: View {
    let action: () -> Void
    var isLoading: Bool = false
    @State private var justReloaded = false
    @State private var rotation: Double = 0

    var body: some View {
        Button {
            guard !isLoading else { return }
            action()
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                justReloaded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation { justReloaded = false }
            }
        } label: {
            Image(systemName: justReloaded ? "checkmark.circle.fill" : "arrow.clockwise")
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(justReloaded ? .green : .secondary)
                .rotationEffect(.degrees(isLoading ? rotation : 0))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(isLoading)
        .help("Reload")
        .onAppear {
            if isLoading { startSpinning() }
        }
        .onChange(of: isLoading) { _, loading in
            if loading {
                startSpinning()
            } else {
                // Stop at current angle — no jarring snap back to 0.
                withAnimation(.easeOut(duration: 0.15)) { rotation = 0 }
            }
        }
    }

    private func startSpinning() {
        rotation = 0
        withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}


/// A small live-status LED: a filled dot, with an optional looping ring-pulse
/// while `isPulsing` (e.g. a check in flight). Never pulses at rest — a
/// permanently-animating "healthy" indicator stops meaning anything.
struct CTXStatusDot: View {
    var tint: Color
    var isPulsing: Bool = false
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 8, height: 8)
            .overlay {
                if isPulsing {
                    Circle()
                        .stroke(tint, lineWidth: 1)
                        .scaleEffect(pulse ? 2.4 : 1)
                        .opacity(pulse ? 0 : 0.7)
                }
            }
            .onAppear { startPulseIfNeeded() }
            .onChange(of: isPulsing) { _, _ in startPulseIfNeeded() }
    }

    private func startPulseIfNeeded() {
        guard isPulsing else {
            pulse = false
            return
        }
        pulse = false
        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}

struct CTXEmptyStateView: View {
    let title: String
    let message: String
    var systemImage: String = "tray"

    var body: some View {
        CTXStateView(systemImage: systemImage, title: title, message: message, tint: .secondary)
    }
}

struct CTXLoadingStateView: View {
    let title: String
    var message: String = "Preparing inspection preview"

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

struct CTXErrorStateView: View {
    let title: String
    let message: String

    var body: some View {
        CTXStateView(systemImage: "xmark.octagon.fill", title: title, message: message, tint: .red)
    }
}

struct CTXSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .frame(minWidth: 80)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.18), lineWidth: 0.75)
        }
    }
}

struct CTXResourceCard: View {
    let title: String
    let value: String
    var subtitle: String = ""
    var systemImage: String = "square.grid.2x2"
    var tint: Color = .accentColor

    @State private var isHovered = false

    var body: some View {
        CTXGlassPanel(padding: 13) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .fixedSize()
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(value)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.tail)
                    if !subtitle.isEmpty {
                        // Two lines rather than one: the subtitle is the only
                        // place the card says *what* its number is made of, and
                        // "123 running · 1 failing" cut to "123 running · 1 fa…"
                        // loses the half that matters.
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
        }
        // Fills its grid cell rather than hugging its content, so a card with a
        // short subtitle sits flush with a taller neighbour instead of floating.
        .frame(minHeight: 88, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(isHovered ? 0.35 : 0.0), lineWidth: 1)
        }
        .scaleEffect(isHovered ? 1.025 : 1.0)
        .shadow(color: tint.opacity(isHovered ? 0.15 : 0.0), radius: isHovered ? 8 : 0, x: 0, y: isHovered ? 3 : 0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .help([title, value, subtitle].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

/// Filled, high-emphasis action — one per screen/panel at most (Done, primary CTA).
struct CTXPrimaryButton: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 26)
            .background(
                LinearGradient(colors: [.accentColor, .accentColor.opacity(0.85)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.25 : 0.12), lineWidth: 1)
            }
            .shadow(color: Color.accentColor.opacity(isHovered ? 0.35 : 0.15), radius: isHovered ? 6 : 3, x: 0, y: isHovered ? 2 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovered ? 1.025 : 1.0))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            .focusEffectDisabled()
    }
}

/// Bordered, medium-emphasis action — Retry, Reload, Compare, Export. Owns its own
/// fill/stroke rather than relying on the system `.bordered` style, which can render
/// flat/dark depending on the surrounding material — this stays visually consistent
/// everywhere it's used.
struct CTXSecondaryButton: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption2.weight(.bold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 26)
            .background(
                Color.secondary.opacity(configuration.isPressed ? 0.22 : (isHovered ? 0.18 : 0.11)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(isHovered ? 0.35 : 0.2), lineWidth: 0.75)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovered ? 1.025 : 1.0))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            .focusEffectDisabled()
    }
}

/// Low-emphasis inline text action — Copy YAML, Show details, Copy diagnostics. No
/// border or fill, just tinted text, for actions that live inside content rather than
/// a toolbar. `.focusEffectDisabled()` on all three styles keeps the system's blue
/// keyboard-focus ring (which macOS auto-applies to the first control in a new
/// popover/sheet) from reading as an accidental "selected" highlight on a button
/// that's actually just sitting there unpressed.
struct CTXInlineActionButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .focusEffectDisabled()
    }
}

/// The one shared "something failed" card — icon, title, message, optional Retry,
/// a collapsed-by-default Show/Hide details toggle, and Copy diagnostics. Used by
/// every screen that can show a read failure (resource lists, Logs, Overview)
/// instead of each maintaining its own near-identical layout. Raw diagnostic text
/// stays hidden until the user explicitly asks for it, and is never auto-selected
/// or highlighted — `.textSelection(.enabled)` only allows a manual drag-select,
/// same as any other inspectable text in the app.
struct CTXDiagnosticCard: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    var diagnosticSummary: String?
    var retry: (() -> Void)?
    @State private var showDetails = false

    var body: some View {
        CTXGlassPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(.headline, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 32, height: 32)
                        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let retry {
                        CTXRetryButton(action: retry)
                    }
                }

                if let diagnosticSummary {
                    HStack(spacing: 12) {
                        Button(showDetails ? "Hide details" : "Show details") {
                            showDetails.toggle()
                        }
                        .buttonStyle(CTXInlineActionButton())
                        .controlSize(.small)
                        CTXDiagnosticsButton(summary: diagnosticSummary)
                    }

                    if showDetails {
                        Text(diagnosticSummary)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }
}

/// Retries exactly one failed operation — never a blanket "reload everything."
/// Always the same visual weight wherever a fetch can fail.
struct CTXRetryButton: View {
    var title: String = "Retry"
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(CTXSecondaryButton())
            .controlSize(.small)
    }
}

/// Copies a sanitized diagnostic summary (never raw stdout/stderr, tokens, or
/// kubeconfig contents — the summary passed in is already redacted upstream).
struct CTXDiagnosticsButton: View {
    let summary: String

    var body: some View {
        CTXCopyIconButton(value: summary)
    }
}

/// Small "last successful refresh" caption — `nil` reads as "Not refreshed" so a
/// screen that has never loaded doesn't imply a stale timestamp of zero.
struct CTXLastUpdatedLabel: View {
    let date: Date?

    var body: some View {
        Text(date.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not refreshed")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Small inline banner shown *above* already-loaded data — never replaces it. Two
/// states: a background revalidation in progress, or one that just failed (in which
/// case the stale-but-good data underneath stays visible and Retry re-triggers only
/// that fetch).
struct CTXInlineRefreshingIndicator: View {
    enum State {
        case refreshing
        case failed
    }

    var state: State
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .refreshing:
                ProgressView()
                    .controlSize(.mini)
                Text("Refreshing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Refresh failed — showing last loaded data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let retry {
                    Button("Retry", action: retry)
                        .buttonStyle(CTXInlineActionButton())
                        .controlSize(.mini)
                }
            }
        }
    }
}

struct CTXStateView: View {
    let systemImage: String
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(.title, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 150)
    }
}

public enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case dark = "Dark"
    case light = "Light"
    case system = "System"

    public var id: String { rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    public var systemImage: String {
        switch self {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .system: return "laptopcomputer"
        }
    }

    /// SwiftUI's `preferredColorScheme` only reaches the SwiftUI hierarchy. Open
    /// and save panels, alerts, menus and the window frame are AppKit and read
    /// `NSApp.appearance` — unset, they follow the system while the app follows
    /// this setting, which is why a file picker came up light over a dark app.
    /// `nil` means "follow the system", which is what System expects.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }

    public static let storageKey = "ctxAppAppearance"

    public static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .dark
    }
}

/// Behind-window vibrancy so the desktop background shows through the content area (blurred).
public struct VisualEffectBackground: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    public var material: NSVisualEffectView.Material = .hudWindow
    public var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    public init(material: NSVisualEffectView.Material = .hudWindow, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = blendingMode
        view.state = .active
        view.material = colorScheme == .light ? .underWindowBackground : material
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = colorScheme == .light ? .underWindowBackground : material
    }
}

public extension View {
    func ctxHeaderButton(tint: Color = .primary, isProminent: Bool = false) -> some View {
        buttonStyle(CTXHeaderButtonStyle(tint: tint, isProminent: isProminent))
    }
}

public struct CTXHeaderButtonStyle: ButtonStyle {
    public let tint: Color
    public let isProminent: Bool
    @State private var isHovered = false

    public init(tint: Color = .primary, isProminent: Bool = false) {
        self.tint = tint
        self.isProminent = isProminent
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isProminent ? Color.white : tint)
            .background {
                if isProminent {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0.04))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isProminent ? tint.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

struct CTXGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                if colorScheme == .light {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .background(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color.primary.opacity(0.015))
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        colorScheme == .light
                            ? Color.primary.opacity(0.12)
                            : Color.white.opacity(0.12),
                        lineWidth: 0.75
                    )
            }
            .shadow(
                color: colorScheme == .light
                    ? Color.black.opacity(0.08)
                    : Color.black.opacity(0.04),
                radius: 8,
                y: 4
            )
    }
}

public extension View {
    func ctxGlassCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(CTXGlassCardModifier(cornerRadius: cornerRadius))
    }
}
