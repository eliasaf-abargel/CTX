import SwiftUI

private struct OnboardingStep {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
}

private let onboardingSteps: [OnboardingStep] = [
    OnboardingStep(
        systemImage: "cloud.fill",
        tint: .accentColor,
        title: "Welcome to CTX",
        message: "Your AWS, GCP, Azure, and Kubernetes contexts, in one place. Everything here reads your existing local configuration — nothing leaves this Mac."
    ),
    OnboardingStep(
        systemImage: "plus",
        tint: .accentColor,
        title: "Add, Then Connect",
        message: "Use the + button above the sidebar to add a profile, then switch it on. CTX signs you in with that provider."
    ),
    OnboardingStep(
        systemImage: "shippingbox.fill",
        tint: .green,
        title: "Missing a CLI Tool?",
        message: "If a provider's command-line tool isn't on this Mac yet, CTX offers a one-click Homebrew install before it connects."
    ),
    OnboardingStep(
        systemImage: "menubar.arrow.up.rectangle",
        tint: .blue,
        title: "Always One Click Away",
        message: "The cloud icon in your Mac's menu bar, top of the screen, opens the same profiles without switching windows."
    ),
]

struct OnboardingTourView: View {
    let onFinish: () -> Void

    @State private var stepIndex = 0
    @AccessibilityFocusState private var isTitleFocused: Bool

    private var isLastStep: Bool { stepIndex == onboardingSteps.count - 1 }
    private var step: OnboardingStep { onboardingSteps[stepIndex] }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { }
                .accessibilityHidden(true)

            VStack(spacing: 22) {
                icon

                VStack(spacing: 8) {
                    Text(step.title)
                        .font(.title3.weight(.bold))
                        .accessibilityFocused($isTitleFocused)
                    Text(step.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 320)
                .id(stepIndex)
                .transition(.opacity)
                .accessibilityElement(children: .combine)

                dots

                controls
            }
            .padding(28)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.separator.opacity(0.2), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: stepIndex)
        .transition(.opacity)
        .onAppear { isTitleFocused = true }
        .onChange(of: stepIndex) { _, _ in isTitleFocused = true }
    }

    private var icon: some View {
        Image(systemName: step.systemImage)
            .font(.system(.title, weight: .semibold))
            .foregroundStyle(step.tint)
            .frame(width: 64, height: 64)
            .background(step.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .id(stepIndex)
            .transition(.scale(scale: 0.75).combined(with: .opacity))
            .accessibilityHidden(true)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(onboardingSteps.indices, id: \.self) { index in
                Capsule()
                    .fill(index == stepIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: index == stepIndex ? 16 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(stepIndex + 1) of \(onboardingSteps.count)")
    }

    private var controls: some View {
        HStack {
            Button("Skip", action: onFinish)
                .buttonStyle(CTXSecondaryButton())
                .opacity(isLastStep ? 0 : 1)
                .disabled(isLastStep)

            Spacer()

            Button(isLastStep ? "Get Started" : "Next") {
                if isLastStep {
                    onFinish()
                } else {
                    stepIndex += 1
                }
            }
            .buttonStyle(CTXPrimaryButton())
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }
}
