// Renders the DMG window background at 1x and 2x.
//   swift script/dmg/background.swift <output-directory>
// Layout must match script/dmg/settings.py (window 640×420, icons centred at
// (170, 196) and (470, 196), 128 pt). Finder's path bar covers roughly the
// bottom 60 pt, so nothing important is drawn below y = 350.
import AppKit

let size = NSSize(width: 640, height: 420)
let appCenter = NSPoint(x: 170, y: 196)
let applicationsCenter = NSPoint(x: 470, y: 196)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func serif(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let descriptor = base.fontDescriptor.withDesign(.serif), let font = NSFont(descriptor: descriptor, size: size) {
        return font
    }
    return base
}

func centered(_ text: String, font: NSFont, color: NSColor, y: CGFloat, tracking: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color,
                                                              .paragraphStyle: style, .kern: tracking])
    let height = string.size().height
    string.draw(in: NSRect(x: 0, y: y - height / 2, width: size.width, height: height))
}

func draw() {
    // Warm paper, a touch lighter at the top, like the app's reading surface.
    NSGradient(colors: [color(0xFCFAF4), color(0xF2EDE1)])!.draw(in: NSRect(origin: .zero, size: size), angle: 90)
    // A soft pool of light behind each icon so they sit on the page.
    for center in [appCenter, applicationsCenter] {
        let glow = NSGradient(colors: [color(0xFFFFFF, 0.85), color(0xFFFFFF, 0)])!
        glow.draw(fromCenter: center, radius: 0, toCenter: center, radius: 112, options: [])
    }

    centered("POSTMERE", font: .systemFont(ofSize: 11, weight: .semibold), color: color(0xA07B42), y: 42, tracking: 2.4)
    centered("Drag to Applications to install", font: serif(24, weight: .semibold), color: color(0x1E3D35), y: 72)

    // Dashed gold arrow, the colour of the icon's wax seal, arching gently
    // from Postmere to Applications.
    let start = NSPoint(x: appCenter.x + 84, y: appCenter.y - 6)
    let end = NSPoint(x: applicationsCenter.x - 88, y: applicationsCenter.y - 6)
    let control = NSPoint(x: (start.x + end.x) / 2, y: appCenter.y - 44)
    let arc = NSBezierPath()
    arc.move(to: start)
    arc.curve(to: end, controlPoint1: control, controlPoint2: control)
    arc.lineWidth = 2.5
    arc.lineCapStyle = .round
    arc.setLineDash([0.5, 7], count: 2, phase: 0)
    color(0xB08A4E).setStroke()
    arc.stroke()

    // Arrowhead along the curve's final direction.
    let angle = atan2(end.y - control.y, end.x - control.x)
    let head = NSBezierPath()
    for side in [-1.0, 1.0] {
        let wing = angle + .pi - side * 0.5
        head.move(to: end)
        head.line(to: NSPoint(x: end.x + 11 * cos(wing), y: end.y + 11 * sin(wing)))
    }
    head.lineWidth = 2.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    centered("Mail, calendar and assistants on your own server.", font: .systemFont(ofSize: 12),
             color: color(0x6F7A72), y: 334)
}

func render(scale: CGFloat, to url: URL) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // Top-left origin so coordinates match Finder's icon positions.
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try render(scale: 1, to: output.appendingPathComponent("background.png"))
try render(scale: 2, to: output.appendingPathComponent("background@2x.png"))
