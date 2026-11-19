import SwiftUI

/// An engraved lake stamp and a folded envelope, drawn in the colors of Postmere's app icon.
struct OnboardingPostage: View {
    let compact: Bool
    let arrived: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var appearance

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 320, proxy.size.height / 222)
            let settled = arrived || reduceMotion

            ZStack {
                foldedEnvelope
                    .frame(width: 203, height: 131)
                    .rotationEffect(.degrees(settled ? -10 : -15))
                    .offset(x: settled ? -21 : -34, y: settled ? 12 : 22)
                    .opacity(settled ? 1 : 0)
                lakeStamp
                    .frame(width: 135, height: 161)
                    .rotationEffect(.degrees(settled ? 8 : 14))
                    .offset(x: settled ? 7 : 15, y: settled ? -7 : -18)
                    .opacity(settled ? 1 : 0)
                cancellation
                    .frame(width: 102, height: 61)
                    .rotationEffect(.degrees(-10))
                    .scaleEffect(settled ? 1 : 1.12)
                    .opacity(settled ? 1 : 0)
                    .offset(x: 76, y: 35)
            }
            .frame(width: 320, height: 222)
            .animation(reduceMotion ? nil : .spring(duration: 0.58, bounce: 0.08), value: arrived)
            .scaleEffect(scale)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var foldedEnvelope: some View {
        let paper = Color(red: 0.92, green: 0.88, blue: 0.76)
        let edge = Color(red: 0.62, green: 0.56, blue: 0.43)
        return Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.6, dy: 0.6)
            let body = Path(roundedRect: rect, cornerRadius: 4)
            context.fill(body, with: .linearGradient(Gradient(colors: [paper, Color(red: 0.98, green: 0.95, blue: 0.86)]),
                                                      startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            context.stroke(body, with: .color(edge.opacity(0.46)), lineWidth: 0.8)
            let flap = Path { path in
                path.move(to: CGPoint(x: 2, y: 3))
                path.addLine(to: CGPoint(x: 96, y: 76))
                path.addQuadCurve(to: CGPoint(x: 107, y: 76), control: CGPoint(x: 101.5, y: 81))
                path.addLine(to: CGPoint(x: 201, y: 3))
            }
            context.stroke(flap, with: .color(.white.opacity(0.78)), lineWidth: 2.6)
            context.stroke(flap, with: .color(edge.opacity(0.58)), lineWidth: 0.8)
            let seams = Path { path in
                path.move(to: CGPoint(x: 2, y: 128))
                path.addLine(to: CGPoint(x: 82, y: 66))
                path.move(to: CGPoint(x: 201, y: 128))
                path.addLine(to: CGPoint(x: 122, y: 66))
            }
            context.stroke(seams, with: .color(edge.opacity(0.55)), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(appearance == .dark ? 0.28 : 0.12), radius: 5, y: 4)
    }

    private var lakeStamp: some View {
        Canvas { context, size in
            let edge = perforations(in: size)
            let paper = Color(red: 0.98, green: 0.96, blue: 0.85)
            let ink = Color(red: 0.10, green: 0.27, blue: 0.23)
            let light = Color(red: 0.88, green: 0.85, blue: 0.66)
            let gold = Color(red: 0.77, green: 0.63, blue: 0.37)
            context.fill(edge, with: .color(paper))
            context.stroke(edge, with: .color(.black.opacity(0.17)), lineWidth: 0.65)
            let plate = CGRect(x: 9, y: 9, width: 117, height: 143)
            context.fill(Path(plate), with: .color(ink))
            let image = CGRect(x: 13, y: 13, width: 109, height: 109)
            var landscape = context
            landscape.clip(to: Path(image))
            landscape.translateBy(x: image.minX, y: image.minY)
            drawLake(in: &landscape, paper: light, green: ink, gold: gold)
            context.stroke(Path(plate.insetBy(dx: 2, dy: 2)), with: .color(light.opacity(0.88)), lineWidth: 0.65)
            context.stroke(Path(image), with: .color(light.opacity(0.85)), lineWidth: 0.55)
            let title = Text(verbatim: "POSTMERE").font(.system(size: 12, weight: .medium, design: .serif)).tracking(1.65).foregroundStyle(paper)
            context.draw(title, at: CGPoint(x: 68, y: 135.5))
        }
        .shadow(color: .black.opacity(appearance == .dark ? 0.36 : 0.18), radius: 2, x: 0, y: 2)
        .shadow(color: .black.opacity(appearance == .dark ? 0.24 : 0.10), radius: 6, x: 1, y: 5)
    }

    private func perforations(in size: CGSize) -> Path {
        var path = Path()
        let inset: CGFloat = 0.5
        let corners = [CGPoint(x: inset, y: inset), CGPoint(x: size.width - inset, y: inset),
                       CGPoint(x: size.width - inset, y: size.height - inset), CGPoint(x: inset, y: size.height - inset)]
        path.move(to: corners[0])
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            let length = hypot(b.x - a.x, b.y - a.y)
            let dx = (b.x - a.x) / length, dy = (b.y - a.y) / length
            let count = Int((length / 8).rounded())
            let pitch = length / CGFloat(count)
            func point(_ distance: CGFloat, _ depth: CGFloat = 0) -> CGPoint {
                CGPoint(x: a.x + dx * distance - dy * depth, y: a.y + dy * distance + dx * depth)
            }
            for hole in 0..<count {
                let center = (CGFloat(hole) + 0.5) * pitch
                path.addLine(to: point(center - 2.1))
                path.addQuadCurve(to: point(center + 2.1), control: point(center, 5.8))
            }
            path.addLine(to: b)
        }
        path.closeSubpath()
        return path
    }

    private func drawLake(in context: inout GraphicsContext, paper: Color, green: Color, gold: Color) {
        let area = CGRect(x: 0, y: 0, width: 109, height: 109)
        context.fill(Path(area), with: .color(paper))
        // Fine parallel lines, cut through by the low sun, form the sky of the print.
        var hatching = Path()
        for y in stride(from: CGFloat(1), through: 64, by: 2.4) {
            hatching.move(to: CGPoint(x: 0, y: y))
            hatching.addQuadCurve(to: CGPoint(x: 110, y: y - 0.5), control: CGPoint(x: 62, y: y + 1.4))
        }
        context.stroke(hatching, with: .color(green.opacity(0.50)), lineWidth: 0.55)
        let sun = CGRect(x: 59, y: 17, width: 23, height: 23)
        context.fill(Path(ellipseIn: sun), with: .color(gold))
        context.stroke(Path(ellipseIn: sun.insetBy(dx: -1.7, dy: -1.7)), with: .color(paper), lineWidth: 1.6)

        // Layered ridgelines; their engraving follows the slope into the valley.
        let distant = Path { p in
            p.move(to: CGPoint(x: -1, y: 55))
            p.addQuadCurve(to: CGPoint(x: 26, y: 44), control: CGPoint(x: 14, y: 43))
            p.addQuadCurve(to: CGPoint(x: 52, y: 47), control: CGPoint(x: 40, y: 48))
            p.addQuadCurve(to: CGPoint(x: 72, y: 41), control: CGPoint(x: 62, y: 43))
            p.addQuadCurve(to: CGPoint(x: 110, y: 30), control: CGPoint(x: 93, y: 34))
            p.addLine(to: CGPoint(x: 110, y: 86))
            p.addLine(to: CGPoint(x: -1, y: 86))
            p.closeSubpath()
        }
        context.fill(distant, with: .color(paper))
        context.stroke(distant, with: .color(green), lineWidth: 1)
        var ridges = context
        ridges.clip(to: distant)
        var cuts = Path()
        for i in 0..<68 {
            let x = CGFloat(i * 3) - 29
            cuts.move(to: CGPoint(x: x, y: 29))
            cuts.addQuadCurve(to: CGPoint(x: x - 35, y: 73), control: CGPoint(x: x - 9, y: 49))
        }
        ridges.stroke(cuts, with: .color(green.opacity(0.68)), lineWidth: 0.7)

        let shore = Path { p in
            p.move(to: CGPoint(x: -1, y: 59))
            p.addQuadCurve(to: CGPoint(x: 27, y: 63), control: CGPoint(x: 14, y: 59))
            p.addQuadCurve(to: CGPoint(x: 64, y: 67), control: CGPoint(x: 45, y: 66))
            p.addQuadCurve(to: CGPoint(x: 96, y: 53), control: CGPoint(x: 70, y: 66))
            p.addLine(to: CGPoint(x: 110, y: 47))
            p.addLine(to: CGPoint(x: 110, y: 73))
            p.addQuadCurve(to: CGPoint(x: 59, y: 72), control: CGPoint(x: 80, y: 72))
            p.addQuadCurve(to: CGPoint(x: 0, y: 76), control: CGPoint(x: 22, y: 74))
            p.closeSubpath()
        }
        context.fill(shore, with: .color(green))
        // A tree is cut as alternating, irregular boughs so its silhouette reads at both sizes.
        func pine(_ x: CGFloat, _ base: CGFloat, _ height: CGFloat, _ width: CGFloat) -> Path {
            var tree = Path()
            tree.move(to: CGPoint(x: x, y: base - height))
            for tier in 1...8 {
                let fraction = CGFloat(tier) / 9
                let depth = base - height + fraction * height
                tree.addLine(to: CGPoint(x: x + fraction * width * (tier.isMultiple(of: 2) ? 0.83 : 1), y: depth))
                tree.addLine(to: CGPoint(x: x + fraction * width * 0.35, y: depth - height * 0.035))
            }
            tree.addLine(to: CGPoint(x: x + 0.55, y: base))
            tree.addLine(to: CGPoint(x: x - 0.55, y: base))
            for tier in (1...8).reversed() {
                let fraction = CGFloat(tier) / 9
                let depth = base - height + fraction * height
                tree.addLine(to: CGPoint(x: x - fraction * width * 0.32, y: depth - height * 0.055))
                tree.addLine(to: CGPoint(x: x - fraction * width * (tier.isMultiple(of: 2) ? 1 : 0.86), y: depth + 0.7))
            }
            tree.closeSubpath()
            return tree
        }
        var trees = Path()
        for i in 0..<46 {
            let x = CGFloat(i) * 2.5
            let base = 68 - max(0, x - 69) * 0.43 - max(0, 44 - x) * 0.19
            let height = CGFloat(4 + ((i * 47 + 19) % 8))
            trees.addPath(pine(x, base + 1, height, height * 0.25))
        }
        for (x, b, h, w): (CGFloat, CGFloat, CGFloat, CGFloat) in [(1, 73, 58, 11), (12, 72, 49, 9), (20, 72, 32, 7), (27, 72, 18, 4)] {
            trees.addPath(pine(x, b, h, w))
        }
        context.fill(trees, with: .color(green))

        let water = Path { p in
            p.move(to: CGPoint(x: -1, y: 76))
            p.addQuadCurve(to: CGPoint(x: 64, y: 72), control: CGPoint(x: 23, y: 74))
            p.addLine(to: CGPoint(x: 110, y: 73))
            p.addLine(to: CGPoint(x: 110, y: 110))
            p.addLine(to: CGPoint(x: -1, y: 110))
            p.closeSubpath()
        }
        context.fill(water, with: .color(paper))
        var waterContext = context
        waterContext.clip(to: water)
        var reflection = waterContext
        var bands = Path()
        for row in 0..<15 {
            let y = 72 + CGFloat(row) * 2.5
            bands.addRect(CGRect(x: 0, y: y, width: 109, height: 1.45 - CGFloat(row) * 0.075))
        }
        reflection.clip(to: bands)
        reflection.translateBy(x: 0, y: 116)
        reflection.scaleBy(x: 1, y: -0.6)
        reflection.fill(trees, with: .color(green.opacity(0.52)))
        var ripples = Path()
        var glints = Path()
        for row in 0..<26 {
            let y = 72 + CGFloat(row) * 1.55
            for mark in 0..<8 {
                let seed = row * 41 + mark * 23
                let x = CGFloat((seed * 19) % 119) - 8
                let length = CGFloat(3 + (seed * 7) % 17)
                let reflectedSun = abs(x - 68) < 5 + CGFloat(row) * 0.3
                var cut = Path()
                cut.move(to: CGPoint(x: x, y: y))
                cut.addLine(to: CGPoint(x: x + length, y: y + CGFloat(seed % 3) * 0.12))
                if reflectedSun { glints.addPath(cut) } else { ripples.addPath(cut) }
            }
        }
        waterContext.stroke(ripples, with: .color(green.opacity(0.84)), lineWidth: 0.75)
        waterContext.stroke(glints, with: .color(gold), lineWidth: 1)
    }

    private var cancellation: some View {
        let ink = appearance == .dark ? Color(red: 0.70, green: 0.77, blue: 0.66) : Color(red: 0.19, green: 0.31, blue: 0.27)
        return Canvas { context, _ in
            let ring = CGRect(x: 5, y: 4, width: 47, height: 47)
            context.stroke(Path(ellipseIn: ring), with: .color(ink.opacity(0.65)), lineWidth: compact ? 1.7 : 1.15)
            context.stroke(Path(ellipseIn: ring.insetBy(dx: 3, dy: 3)), with: .color(ink.opacity(0.5)), lineWidth: 0.75)
            let mark = Text(verbatim: "P").font(.system(size: 25, weight: .regular, design: .serif)).italic().foregroundStyle(ink.opacity(0.72))
            context.draw(mark, at: CGPoint(x: ring.midX, y: ring.midY - 0.5))
            var waves = Path()
            for line in 0..<4 {
                let y = CGFloat(11 + line * 7)
                waves.move(to: CGPoint(x: 49, y: y))
                waves.addCurve(to: CGPoint(x: 102, y: y + 3), control1: CGPoint(x: 66, y: y - 11), control2: CGPoint(x: 75, y: y + 15))
            }
            context.stroke(waves, with: .color(ink.opacity(0.62)), lineWidth: compact ? 1.7 : 1.15)
        }
    }
}
