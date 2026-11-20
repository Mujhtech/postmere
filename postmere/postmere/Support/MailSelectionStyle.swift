import AppKit
import SwiftUI

extension View {
    func mailSelection(_ selected: Bool, joinsAbove: Bool = false, joinsBelow: Bool = false,
                       horizontalInset: CGFloat = 6) -> some View {
        modifier(MailSelectionStyle(selected: selected, joinsAbove: joinsAbove, joinsBelow: joinsBelow,
                                    horizontalInset: horizontalInset))
    }
}

private struct MailSelectionStyle: ViewModifier {
    let selected: Bool
    let joinsAbove: Bool
    let joinsBelow: Bool
    let horizontalInset: CGFloat
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
            .padding(.horizontal, horizontalInset)
            .background { MailSelectionTableConfiguration().frame(width: 0, height: 0) }
            .accessibilityHidden(true)
    }
}

/// The List still owns focus, keyboard navigation and selection. Its rows supply the highlight.
private struct MailSelectionTableConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.configureTable() }

    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureTable()
        }

        func configureTable() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    guard table.selectionHighlightStyle != .none else { return }
                    // Changing a table style can invalidate its hosted rows. Wait for
                    // SwiftUI to finish the update that installed this background.
                    DispatchQueue.main.async { [weak table] in
                        guard let table, table.selectionHighlightStyle != .none else { return }
                        table.selectionHighlightStyle = .none
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
