import AppKit
import CTXCore
import SwiftUI

func copyToClipboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
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
                .font(.system(size: 10, weight: .medium))
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
    let action: () -> Void
    @State private var isHovering = false

    private var tooltipWidth: CGFloat {
        min(max(CGFloat(title.count) * 7 + 24, 96), 150)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 28)
                .background(Color.secondary.opacity(isHovering ? 0.22 : 0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.secondary.opacity(isHovering ? 0.35 : 0.24), lineWidth: 0.75)
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
                    .font(.system(size: 11, weight: .semibold))
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.separator.opacity(0.28), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 14, y: 7)
    }
}

struct CTXSectionHeader: View {
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
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
            .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 11, weight: .medium))
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
            }
        }
        .font(.system(size: 12))
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
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .fixedSize()
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(value)
                        .font(.system(size: 21, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.tail)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 88)
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
        }
        .help([title, value, subtitle].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

/// Filled, high-emphasis action — one per screen/panel at most (Done, primary CTA).
struct CTXPrimaryButton: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
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
            .font(.system(size: 11, weight: .bold))
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
            .font(.system(size: 12, weight: .medium))
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
                        .font(.system(size: 18, weight: .semibold))
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
                            .font(.system(size: 11, design: .monospaced))
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
                .font(.system(size: 26, weight: .semibold))
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
