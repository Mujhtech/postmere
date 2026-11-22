import AppKit
import SwiftUI

/// A colour wheel that opens the system colour panel, so it reads as "pick
/// any colour" rather than as one more swatch. When the current colour is a
/// custom one, the wheel is ringed and shows that colour in its centre.
struct ColorWheelButton: View {
    let title: String
    @Binding var rgb: Int
    var isCustom: Bool
    var size: CGFloat = 22
    @State private var hovering = false

    var body: some View {
        Button {
            ColorPanelBridge.shared.present(rgb: rgb) { rgb = $0 }
        } label: {
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.85), .white.opacity(0)],
                                                          center: .center, startRadius: 0, endRadius: size * 0.5)))
                if isCustom {
                    Circle().fill(Color(hex: UInt32(rgb)))
                        .frame(width: size * 0.5, height: size * 0.5)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                }
            }
            .frame(width: size, height: size)
            .padding(3)
            .overlay(Circle().strokeBorder(isCustom ? Color(hex: UInt32(rgb)) : .clear, lineWidth: 2))
            .scaleEffect(hovering ? 1.06 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isCustom ? .isSelected : [])
    }
}

/// Routes the shared colour panel to whichever wheel opened it last.
@MainActor final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((Int) -> Void)?

    func present(rgb: Int, onChange: @escaping (Int) -> Void) {
        let panel = NSColorPanel.shared
        self.onChange = nil
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                              blue: CGFloat(rgb & 255) / 255, alpha: 1)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        self.onChange = onChange
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let rgb = PostmereAccent.rgbValue(of: Color(nsColor: panel.color)) else { return }
        onChange?(rgb)
    }
}
