import SwiftUI

/// The accent capsule used for onboarding actions on every device.
struct OnboardingActionStyle: ButtonStyle {
    @Environment(\.postmereAccent) private var palette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 23).frame(minHeight: 40)
            .foregroundStyle(.white)
            .background(palette.accent.gradient, in: .capsule)
            .opacity(enabled ? (configuration.isPressed ? 0.86 : 1) : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
