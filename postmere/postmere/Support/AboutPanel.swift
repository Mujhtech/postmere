import AppKit

/// The standard About window with Postmere's name, version, a one-line
/// description and the copyright from the bundle.
enum AboutPanel {
    @MainActor static func show() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(
            string: "Native Mac mail, calendar and assistants on your own server.",
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
