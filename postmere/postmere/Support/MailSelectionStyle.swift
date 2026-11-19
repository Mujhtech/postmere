import SwiftUI

extension View {
    func mailSelection(_ selected: Bool, joinsAbove: Bool = false, joinsBelow: Bool = false) -> some View {
        modifier(MailSelectionStyle(selected: selected, joinsAbove: joinsAbove, joinsBelow: joinsBelow))
    }
}

private struct MailSelectionStyle: ViewModifier {
    let selected: Bool
    let joinsAbove: Bool
    let joinsBelow: Bool
    @Environment(\.postmereAccent) private var accent
    @Environment(\.appearsActive) private var active
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected ? AnyShapeStyle(accent.selectionInk) : AnyShapeStyle(.primary))
            .listRowBackground(selected ? background : nil)
    }

    private var background: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: joinsAbove ? 0 : 8,
                                           bottomLeadingRadius: joinsBelow ? 0 : 8,
                                           bottomTrailingRadius: joinsBelow ? 0 : 8,
                                           topTrailingRadius: joinsAbove ? 0 : 8)
        return shape.fill(accent.selectionFill)
            .saturation(active ? 1 : 0.4)
            .overlay {
                if contrast == .increased || differentiate {
                    shape.strokeBorder(accent.selectionSecondaryInk, lineWidth: 1)
                }
            }
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }
}
