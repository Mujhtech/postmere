import AppKit

/// The standard About window with Postmere's name, version, a one-line
/// description and the copyright from the bundle.
enum AboutPanel {
    @MainActor static func show() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(
            string: "A native Mac mail client with its own server.\nMail, calendar, assistants and plugins in one place.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ]
        )
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Postmere",
            .credits: credits,
        ])
    }
}
