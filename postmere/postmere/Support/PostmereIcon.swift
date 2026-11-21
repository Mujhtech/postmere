import AppKit
import SwiftUI

/// Postmere's own 24-point line icons. Keeping the drawing in one place also
/// gives native AppKit controls the same artwork as SwiftUI labels and menus.
struct PostmereIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let symbol: String
    let size: CGFloat

    init(_ symbol: String, size: CGFloat = 16) {
        self.symbol = symbol
        self.size = size
    }

    var body: some View {
        Image(nsImage: PostmereSymbols.image(symbol, size: size, colorScheme: colorScheme))
            .renderingMode(.template)
            .accessibilityHidden(true)
    }
}

struct PostmereLabel: View {
    let title: String
    let symbol: String
    let size: CGFloat

    init(_ title: String, symbol: String, size: CGFloat = 16) {
        self.title = title
        self.symbol = symbol
        self.size = size
    }

    static func emptyState(_ title: String, symbol: String, size: CGFloat) -> some View {
        Label { Text(title) } icon: {
            PostmereIcon(symbol, size: size).foregroundStyle(PostmereTheme.icon)
        }
    }

    var body: some View {
        Label { Text(title) } icon: { PostmereIcon(symbol, size: size) }
    }
}

struct PostmereSearchEmptyState: View {
    let query: String
    let clearSearch: () -> Void

    var body: some View {
        ContentUnavailableView {
            PostmereLabel.emptyState("No results", symbol: "magnifyingglass", size: 36)
        } description: {
            Text("No matches for “\(query)”.").lineLimit(3)
        } actions: {
            Button("Clear Search", action: clearSearch)
        }
    }
}

enum PostmereSymbols {
    private static var images: [String: NSImage] = [:]

    static func image(_ symbol: String, size: CGFloat = 16, colorScheme: ColorScheme) -> NSImage {
        let dark = colorScheme == .dark
        let key = "\(symbol):\(size):\(dark)"
        if let image = images[key] { return image }
        let artwork = drawing(symbol)
        // Native menu labels can draw the original pixels even when the image is a template.
        let ink = (dark ? NSColor.white : NSColor.black).cgColor
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.scaleBy(x: size / 24, y: size / 24)
            context.setStrokeColor(ink)
            context.setFillColor(ink)
            context.setLineWidth(max(1.7, 25.2 / size))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(artwork.lines.cgPath)
            context.strokePath()
            context.addPath(artwork.fills.cgPath)
            context.fillPath()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        images[key] = image
        return image
    }

    /// Original geometry, with familiar semantic names at call sites. Artwork
    /// uses open folds, softly rounded corners and generous interior space.
    static func drawing(_ name: String) -> IconDrawing {
        var d = IconDrawing()
        switch name {
        case "tray", "tray.full", "tray.and.arrow.up", "tray.and.arrow.down":
            d.line([3, 13, 7.5, 13, 9.5, 16, 14.5, 16, 16.5, 13, 21, 13])
            d.line([3, 13, 5.5, 7, 7.5, 7]); d.line([16.5, 7, 18.5, 7, 21, 13])
            d.curve(from: [3, 13], to: [5, 20], c1: [3, 20], c2: [3, 20])
            d.line([5, 20, 19, 20])
            d.curve(from: [19, 20], to: [21, 13], c1: [21, 20], c2: [21, 20])
            if name == "tray.and.arrow.up" { d.line([12, 12, 12, 3]); d.line([8.5, 6.5, 12, 3, 15.5, 6.5]) }
            else if name == "tray.and.arrow.down" { d.line([12, 3, 12, 12]); d.line([8.5, 8.5, 12, 12, 15.5, 8.5]) }
            else { d.line([9, 7, 15, 7]); d.line([10, 10, 14, 10]) }
        case "envelope", "envelope.open", "envelope.on.envelope":
            if name == "envelope.on.envelope" { d.line([6, 4, 19, 4]); d.curve(from: [19, 4], to: [22, 7], c1: [22, 4], c2: [22, 4]); d.line([22, 7, 22, 15]) }
            d.rect(3, 6, 17, 14, radius: 2.5)
            d.line([4, 7.5, 11.5, 13, 19, 7.5])
            d.line([3.5, 18.5, 8.5, 14.5]); d.line([19.5, 18.5, 14.5, 14.5])
        case "star", "star.fill":
            var star = Path()
            for index in 0..<10 {
                let angle = Double(index) * .pi / 5 - .pi / 2
                let radius = index.isMultiple(of: 2) ? 9.2 : 4.4
                let point = CGPoint(x: 12 + cos(angle) * radius, y: 12 + sin(angle) * radius)
                if index == 0 { star.move(to: point) } else { star.addLine(to: point) }
            }
            star.closeSubpath()
            if name == "star.fill" { d.fills.addPath(star) } else { d.lines.addPath(star) }
        case "paperplane":
            d.line([3, 10, 21, 3, 15, 21, 11, 13, 3, 10], close: true)
            d.line([11, 13, 17, 7])
        case "doc", "doc.text":
            d.document(); d.line([8, 12, 16, 12]); d.line([8, 16, 13, 16])
        case "archivebox":
            d.rect(3, 4, 18, 5, radius: 1.5)
            d.line([5, 9, 5, 20, 19, 20, 19, 9]); d.line([9.5, 13, 14.5, 13])
        case "tag":
            d.line([3, 4, 12, 4, 21, 13, 13, 21, 3, 11], close: true)
            d.circle(7.5, 8.5, 1.4)
        case "trash":
            d.line([3, 6, 21, 6]); d.line([9, 6, 9, 3, 15, 3, 15, 6])
            d.line([5, 9, 6, 21, 18, 21, 19, 9]); d.line([9, 10, 9.5, 17]); d.line([15, 10, 14.5, 17])
        case "info.circle":
            d.circle(12, 12, 9)
            d.disc(12, 8, 1)
            d.line([12, 11, 12, 16])
        case "arrowshape.turn.up.left.2":
            d.line([8, 4, 2, 10, 8, 16])
            d.line([14, 4, 8, 10, 14, 16])
            d.line([8, 10, 14, 10])
            d.curve(from: [14, 10], to: [22, 20], c1: [20, 10], c2: [22, 13])
        case "arrowshape.turn.up.left", "arrow.uturn.backward":
            d.line([9, 4, 3, 10, 9, 16]); d.line([3, 10, 13, 10])
            d.curve(from: [13, 10], to: [21, 20], c1: [19, 10], c2: [21, 13])
        case "arrowshape.turn.up.right", "arrow.uturn.forward":
            d.line([15, 4, 21, 10, 15, 16]); d.line([21, 10, 11, 10])
            d.curve(from: [11, 10], to: [3, 20], c1: [5, 10], c2: [3, 13])
        case "moon.zzz":
            d.curve(from: [11, 3], to: [21, 15], c1: [7, 12], c2: [15, 19])
            d.curve(from: [21, 15], to: [11, 3], c1: [13, 28], c2: [-4, 11])
            d.line([16, 3, 21, 3, 16, 8, 21, 8])
        case "bell", "bell.badge":
            d.curve(from: [5, 15], to: [12, 4], c1: [7, 13], c2: [4, 4])
            d.curve(from: [12, 4], to: [19, 15], c1: [20, 4], c2: [17, 13])
            d.line([5, 15, 3.5, 18, 20.5, 18, 19, 15]); d.line([12, 2, 12, 4])
            d.curve(from: [9.5, 21], to: [14.5, 21], c1: [10.5, 22], c2: [13.5, 22])
            if name == "bell.badge" { d.disc(19, 4, 2.4) }
        case "person.crop.circle", "person.crop.circle.badge.questionmark":
            d.circle(12, 12, 9)
            d.circle(12, 9, 2.8)
            d.curve(from: [6, 18], to: [18, 18], c1: [6, 12], c2: [18, 12])
            if name.contains("questionmark") { d.disc(20, 4, 2.6) }
        case "building.2":
            d.rect(4, 3, 10, 18, radius: 1.5); d.line([14, 9, 20, 9, 20, 21, 14, 21])
            for y: CGFloat in [7, 11, 15] { d.line([7, y, 10, y]) }
            d.line([17, 13, 17, 14]); d.line([17, 17, 17, 18])
        case "clock":
            d.circle(12, 12, 9); d.line([12, 6.5, 12, 12, 16, 14.5])
        case "calendar":
            d.rect(3, 5, 18, 16, radius: 2.5); d.line([3, 10, 21, 10])
            d.line([8, 3, 8, 7]); d.line([16, 3, 16, 7])
            for x: CGFloat in [7, 12, 17] { d.disc(x, 14, 0.7) }; d.disc(7, 18, 0.7); d.disc(12, 18, 0.7)
        case "eye":
            d.curve(from: [2, 12], to: [22, 12], c1: [7, 2], c2: [17, 2])
            d.curve(from: [22, 12], to: [2, 12], c1: [17, 22], c2: [7, 22]); d.circle(12, 12, 3)
        case "desktopcomputer":
            d.rect(2, 3, 20, 14, radius: 2); d.line([12, 17, 12, 21]); d.line([7, 21, 17, 21])
        case "iphone":
            d.rect(6, 2, 12, 20, radius: 2.5); d.line([10, 5, 14, 5]); d.disc(12, 19, 0.7)
        case "sparkles":
            d.line([12, 3, 14.5, 9.5, 21, 12, 14.5, 14.5, 12, 21, 9.5, 14.5, 3, 12, 9.5, 9.5, 12, 3], close: true)
            d.line([20, 2, 20, 6]); d.line([18, 4, 22, 4])
        case "postmere.ask":
            // A speech bubble holding an envelope fold, its top corner left open for a spark.
            d.line([12.5, 4, 6, 4])
            d.curve(from: [6, 4], to: [3, 7], c1: [4.3, 4], c2: [3, 5.3])
            d.line([3, 7, 3, 13])
            d.curve(from: [3, 13], to: [6, 16], c1: [3, 14.7], c2: [4.3, 16])
            d.line([7.5, 16, 6.5, 20.5, 11.5, 16, 16, 16])
            d.curve(from: [16, 16], to: [19, 13], c1: [17.7, 16], c2: [19, 14.7])
            d.line([19, 13, 19, 10.5])
            d.line([7, 8, 11, 11, 15, 8])
            d.line([19, 1.5, 19.9, 4.1, 22.5, 5, 19.9, 5.9, 19, 8.5, 18.1, 5.9, 15.5, 5, 18.1, 4.1], close: true)
        case "note.text":
            d.rect(4, 3, 16, 18, radius: 2.5)
            d.line([8, 7, 16, 7]); d.line([8, 11, 16, 11]); d.line([8, 15, 12, 15])
        case "bubble.left.and.bubble.right":
            d.line([8, 13, 4, 17, 4, 5, 18, 5, 18, 13, 8, 13], close: true)
            d.line([8, 17, 15, 17, 20, 21, 20, 9])
        case "paperclip":
            d.curve(from: [9, 8], to: [15, 8], c1: [9, 4], c2: [15, 4])
            d.line([15, 8, 15, 17])
            d.curve(from: [15, 17], to: [5, 17], c1: [15, 24], c2: [5, 24])
            d.line([5, 17, 5, 7])
            d.curve(from: [5, 7], to: [19, 7], c1: [5, -1], c2: [19, -1])
            d.line([19, 7, 19, 16]); d.line([9, 8, 9, 17])
            d.curve(from: [9, 17], to: [11, 17], c1: [9, 18.5], c2: [11, 18.5])
        case "square.and.pencil":
            d.line([10, 4, 4, 4, 4, 20, 20, 20, 20, 14])
            d.line([9, 15, 10, 11, 18, 3, 21, 6, 13, 14, 9, 15], close: true)
            d.line([16, 5, 19, 8])
        case "sidebar.left":
            d.rect(3, 4, 18, 16, radius: 2.5); d.line([9, 4, 9, 20]); d.line([5.5, 8, 6.5, 8]); d.line([5.5, 12, 6.5, 12])
        case "sidebar.right":
            d.rect(3, 4, 18, 16, radius: 2.5); d.line([15, 4, 15, 20]); d.line([17.5, 8, 18.5, 8]); d.line([17.5, 12, 18.5, 12])
        case "person.crop.rectangle":
            d.rect(3, 4, 18, 16, radius: 2.5); d.circle(8.5, 9, 2.1)
            d.curve(from: [5, 17], to: [12, 17], c1: [5, 11.5], c2: [12, 11.5])
            d.line([15, 8, 18, 8]); d.line([15, 12, 18, 12]); d.line([15, 16, 17, 16])
        case "arrow.up.right":
            d.line([5, 19, 19, 5]); d.line([8, 5, 19, 5, 19, 16])
        case "link":
            d.line([8, 16, 16, 8])
            d.curve(from: [10, 7], to: [19, 5], c1: [14, 0], c2: [18, 2])
            d.curve(from: [19, 5], to: [17, 14], c1: [22, 8], c2: [22, 11])
            d.curve(from: [14, 17], to: [5, 19], c1: [10, 24], c2: [6, 22])
            d.curve(from: [5, 19], to: [7, 10], c1: [2, 16], c2: [2, 13])
        case "at":
            d.circle(11, 12, 3.5); d.line([14.5, 8.5, 14.5, 15])
            d.curve(from: [14.5, 15], to: [21, 12], c1: [17, 19], c2: [21, 17])
            d.curve(from: [21, 12], to: [3, 12], c1: [21, 0], c2: [3, 0])
            d.curve(from: [3, 12], to: [15, 21], c1: [3, 19], c2: [8, 23])
        case "magnifyingglass":
            d.circle(10.5, 10.5, 6.5); d.line([15.5, 15.5, 21, 21])
        case "line.3.horizontal.decrease.circle", "line.3.horizontal.decrease.circle.fill":
            d.circle(12, 12, 9); d.line([7, 8, 17, 8]); d.line([9, 12, 15, 12]); d.line([11, 16, 13, 16])
            if name.hasSuffix(".fill") { d.disc(20, 4, 2.5) }
        case "plus.rectangle.on.folder", "folder":
            d.line([3, 8, 3, 5, 9, 5, 12, 8, 21, 8, 21, 20, 3, 20, 3, 8], close: true)
            if name != "folder" { d.line([12, 11, 12, 17]); d.line([9, 14, 15, 14]) }
        case "paintpalette":
            d.curve(from: [12, 3], to: [3, 12], c1: [7, 3], c2: [3, 7])
            d.curve(from: [3, 12], to: [12, 21], c1: [3, 17], c2: [7, 21])
            d.curve(from: [12, 21], to: [14, 17], c1: [15, 21], c2: [15, 19])
            d.curve(from: [14, 17], to: [17, 14], c1: [13, 15], c2: [14.5, 14])
            d.curve(from: [17, 14], to: [21, 11], c1: [20, 14], c2: [21, 13])
            d.curve(from: [21, 11], to: [12, 3], c1: [21, 6.5], c2: [17, 3])
            d.disc(7.5, 12.5, 1.3)
            d.disc(10, 8, 1.3)
            d.disc(15.5, 7.5, 1.3)
        case "gearshape":
            // Four rails and offset controls make the settings mark legible at
            // sidebar sizes without a dense ring of tiny gear teeth.
            d.line([4, 7, 9, 7]); d.line([14, 7, 20, 7]); d.circle(11.5, 7, 2.5)
            d.line([4, 17, 11, 17]); d.line([16, 17, 20, 17]); d.circle(13.5, 17, 2.5)
        case "shield", "exclamationmark.shield", "checkmark.shield", "questionmark.shield":
            d.line([12, 2.5, 20, 6, 20, 12])
            d.curve(from: [20, 12], to: [12, 21.5], c1: [20, 16], c2: [16, 19.5])
            d.curve(from: [12, 21.5], to: [4, 12], c1: [8, 19.5], c2: [4, 16])
            d.line([4, 12, 4, 6, 12, 2.5])
            if name == "exclamationmark.shield" {
                d.line([12, 7, 12, 12]); d.disc(12, 15.5, 1)
            } else if name == "checkmark.shield" {
                d.line([8.5, 12, 11, 14.5, 15.5, 9.5])
            } else if name == "questionmark.shield" {
                d.curve(from: [9.8, 9.6], to: [12, 13], c1: [9.8, 6.2], c2: [15.4, 7.2])
                d.disc(12, 16, 1)
            }
        case "keyboard":
            d.rect(2, 5, 20, 14, radius: 2.5)
            for x: CGFloat in [6, 10, 14, 18] { d.disc(x, 9, 0.65); d.disc(x, 12, 0.65) }
            d.line([7, 15.5, 17, 15.5])
        case "arrow.clockwise":
            d.curve(from: [20, 10], to: [4, 10], c1: [18, 0], c2: [6, 0])
            d.curve(from: [4, 10], to: [20, 16], c1: [-1, 23], c2: [16, 26])
            d.line([20, 4, 20, 10, 14, 10])
        case "arrow.up":
            d.line([12, 21, 12, 3]); d.line([5, 10, 12, 3, 19, 10])
        case "arrow.down.to.line":
            d.line([12, 3, 12, 16]); d.line([7, 11, 12, 16, 17, 11]); d.line([4, 20, 20, 20])
        case "arrow.up.forward.square":
            d.line([11, 4, 4, 4, 4, 20, 20, 20, 20, 13]); d.line([11, 13, 21, 3]); d.line([15, 3, 21, 3, 21, 9])
        case "textformat":
            d.line([3, 19, 9, 4, 15, 19]); d.line([5.5, 13, 12.5, 13]); d.line([16, 10, 22, 10]); d.line([19, 10, 19, 19])
        case "text.badge.plus":
            d.rect(3, 3, 15, 18, radius: 2)
            d.line([7, 7, 14, 7]); d.line([7, 11, 12, 11]); d.line([7, 15, 10, 15])
            d.line([18, 12, 18, 20]); d.line([14, 16, 22, 16])
        case "rectangle.topthird.inset.filled":
            d.rect(3, 4, 18, 16, radius: 2.5); d.line([3, 10, 21, 10]); d.line([7, 7, 12, 7])
        case "face.smiling":
            d.circle(12, 12, 9); d.disc(8.5, 9, 0.8); d.disc(15.5, 9, 0.8)
            d.curve(from: [7.5, 14], to: [16.5, 14], c1: [9, 18.5], c2: [15, 18.5])
        case "list.bullet":
            for y: CGFloat in [6, 12, 18] { d.disc(4, y, 1); d.line([9, y, 21, y]) }
        case "text.alignleft", "text.aligncenter", "text.alignright":
            for (index, y) in [5.0, 10.0, 15.0, 20.0].enumerated() {
                let short = index.isMultiple(of: 2) ? 0.0 : 6.0
                let inset = name == "text.aligncenter" ? short / 2 : name == "text.alignright" ? short : 0
                d.line([3 + inset, y, 21 - short + inset, y])
            }
        case "bold":
            d.line([6, 3, 6, 21]); d.line([6, 3, 12, 3])
            d.curve(from: [12, 3], to: [12, 11], c1: [20, 3], c2: [20, 11]); d.line([6, 11, 12, 11])
            d.curve(from: [12, 11], to: [12, 21], c1: [22, 11], c2: [22, 21]); d.line([6, 21, 12, 21])
        case "italic":
            d.line([11, 4, 20, 4])
            d.line([15.5, 4, 8.5, 20])
            d.line([4, 20, 13, 20])
        case "underline":
            d.line([6, 3, 6, 11])
            d.curve(from: [6, 11], to: [18, 11], c1: [6, 19], c2: [18, 19])
            d.line([18, 11, 18, 3])
            d.line([5, 21, 19, 21])
        case "chevron.left": d.line([15, 5, 8, 12, 15, 19])
        case "chevron.right": d.line([9, 5, 16, 12, 9, 19])
        case "chevron.down": d.line([5, 9, 12, 16, 19, 9])
        case "chevron.up": d.line([5, 15, 12, 8, 19, 15])
        case "checkmark", "checkmark.circle":
            if name.hasSuffix("circle") { d.circle(12, 12, 9); d.line([7.5, 12, 10.5, 15, 16.5, 9]) }
            else { d.line([4, 12, 9, 17, 20, 6]) }
        case "plus": d.line([12, 4, 12, 20]); d.line([4, 12, 20, 12])
        case "xmark", "xmark.circle.fill":
            if name.contains("circle") { d.circle(12, 12, 9); d.line([9, 9, 15, 15]); d.line([15, 9, 9, 15]) }
            else { d.line([5, 5, 19, 19]); d.line([19, 5, 5, 19]) }
        case "ellipsis", "ellipsis.circle":
            if name.hasSuffix("circle") { d.circle(12, 12, 9) }
            for x: CGFloat in [6, 12, 18] { d.disc(x, 12, 1.65) }
        case "exclamationmark.circle":
            d.circle(12, 12, 9); d.line([12, 7, 12, 12]); d.disc(12, 16, 1)
        case "externaldrive.badge.exclamationmark":
            d.rect(3, 5, 18, 15, radius: 2.5); d.line([3, 15, 21, 15]); d.line([12, 8, 12, 10]); d.disc(12, 12.5, 0.7); d.disc(17, 17.5, 0.6)
        default:
            // Deliberately visible in development: every application symbol
            // should be added to this family, never silently fall back to SF.
            d.rect(5, 5, 14, 14, radius: 3); d.line([9, 9, 15, 15]); d.line([15, 9, 9, 15])
        }
        return d
    }
}

struct IconDrawing {
    var lines = Path()
    var fills = Path()

    mutating func line(_ coordinates: [CGFloat], close: Bool = false) {
        guard coordinates.count >= 4 else { return }
        lines.move(to: CGPoint(x: coordinates[0], y: coordinates[1]))
        for index in stride(from: 2, to: coordinates.count, by: 2) {
            lines.addLine(to: CGPoint(x: coordinates[index], y: coordinates[index + 1]))
        }
        if close { lines.closeSubpath() }
    }

    mutating func curve(from: [CGFloat], to: [CGFloat], c1: [CGFloat], c2: [CGFloat]) {
        lines.move(to: CGPoint(x: from[0], y: from[1]))
        lines.addCurve(to: CGPoint(x: to[0], y: to[1]),
                       control1: CGPoint(x: c1[0], y: c1[1]), control2: CGPoint(x: c2[0], y: c2[1]))
    }

    mutating func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat) {
        lines.addRoundedRect(in: CGRect(x: x, y: y, width: width, height: height), cornerSize: CGSize(width: radius, height: radius))
    }

    mutating func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
        lines.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    mutating func disc(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
        fills.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    mutating func document() {
        line([14, 3, 5, 3, 5, 21, 19, 21, 19, 8, 14, 3], close: true)
        line([14, 3, 14, 8, 19, 8])
    }
}
