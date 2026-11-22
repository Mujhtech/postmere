import SwiftUI

/// A Liquid Glass segmented control: a soft capsule track with a glass thumb
/// that slides to the chosen option.
struct GlassSegmentedControl<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var symbol: String?
        var id: Value { value }
    }

    let title: String
    @Binding var selection: Value
    let options: [Option]
    var compact = false

    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), in: .capsule)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .fixedSize()
        .textCase(nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func segment(_ option: Option) -> some View {
        let selected = option.value == selection
        return Button {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.38, bounce: 0.22)) {
                selection = option.value
            }
        } label: {
            HStack(spacing: 5) {
                if let symbol = option.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .accessibilityHidden(true)
                }
                Text(option.title)
            }
            .font(.system(size: compact ? 11 : 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, compact ? 10 : 13)
            .frame(height: compact ? 22 : 26)
            .background {
                if selected {
                    Capsule()
                        .fill(scheme == .dark ? Color.white.opacity(0.14) : Color.white)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.1), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "thumb", in: thumb)
                } else if hovered == option.value {
                    Capsule().fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? option.value : (hovered == option.value ? nil : hovered) }
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
