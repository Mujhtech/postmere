#if os(macOS)
import AppKit
private typealias ReadingFont = NSFont
private typealias ReadingFontDescriptor = NSFontDescriptor
private let monoTrait = NSFontDescriptor.SymbolicTraits.monoSpace
private let styleTraits: NSFontDescriptor.SymbolicTraits = [.bold, .italic]
#else
import UIKit
private typealias ReadingFont = UIFont
private typealias ReadingFontDescriptor = UIFontDescriptor
private let monoTrait = UIFontDescriptor.SymbolicTraits.traitMonoSpace
private let styleTraits: UIFontDescriptor.SymbolicTraits = [.traitBold, .traitItalic]
#endif
import SwiftUI

nonisolated enum MailReadingFont: String, CaseIterable, Sendable {
    // Stored raw values stay stable: older choices keep working.
    case original, sansSerif, rounded, serif, monospaced
    case helveticaNeue, avenirNext, optima, charter, hoeflerText, palatino, georgia

    static let preference = "mailReadingFont"

    /// The system family, then fonts that ship with every Mac.
    static let systemFonts: [Self] = [.sansSerif, .rounded, .serif, .monospaced]
    static let macFonts: [Self] = [.helveticaNeue, .avenirNext, .optima, .charter, .hoeflerText, .palatino, .georgia]

    var title: String {
        switch self {
        case .original: "Sender’s font"
        case .sansSerif: "San Francisco"
        case .rounded: "SF Rounded"
        case .serif: "New York"
        case .monospaced: "SF Mono"
        case .helveticaNeue: "Helvetica Neue"
        case .avenirNext: "Avenir Next"
        case .optima: "Optima"
        case .charter: "Charter"
        case .hoeflerText: "Hoefler Text"
        case .palatino: "Palatino"
        case .georgia: "Georgia"
        }
    }

    /// The installed family name for the named Mac fonts.
    var familyName: String? {
        switch self {
        case .helveticaNeue: "Helvetica Neue"
        case .avenirNext: "Avenir Next"
        case .optima: "Optima"
        case .charter: "Charter"
        case .hoeflerText: "Hoefler Text"
        case .palatino: "Palatino"
        case .georgia: "Georgia"
        default: nil
        }
    }

    private var isSerif: Bool { [.serif, .charter, .hoeflerText, .palatino, .georgia].contains(self) }

    func font(size: CGFloat) -> Font {
        if let familyName { return .custom(familyName, size: size) }
        return switch self {
        case .rounded: .system(size: size, design: .rounded)
        case .serif: .system(size: size, design: .serif)
        case .monospaced: .system(size: size, design: .monospaced)
        default: .system(size: size)
        }
    }

    var cssFamily: String {
        if let familyName { return "'\(familyName)', \(isSerif ? "ui-serif, serif" : "-apple-system, sans-serif")" }
        return switch self {
        case .original: ""
        case .rounded: "ui-rounded, -apple-system, sans-serif"
        case .serif: "ui-serif, Georgia, serif"
        case .monospaced: "ui-monospace, Menlo, monospace"
        default: "-apple-system, sans-serif"
        }
    }

    func format(_ source: NSAttributedString, size: CGFloat) -> NSAttributedString {
        guard self != .original || size != 14 else { return source }
        let styled = NSMutableAttributedString(attributedString: source)
        let bodyFont = ReadingFont.systemFont(ofSize: size)
        source.enumerateAttribute(.font, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            guard let original = value as? ReadingFont else { return }
            let traits = original.fontDescriptor.symbolicTraits
            let newSize = original.pointSize * size / 14
            var descriptor: ReadingFontDescriptor
            #if os(macOS)
            let sourceFamily = (original.familyName ?? original.fontName).lowercased()
            #else
            let sourceFamily = original.familyName.lowercased()
            #endif
            let symbolFont = ["symbol", "dingbats", "wingdings", "webdings", "emoji", "font awesome", "material icons"]
                .contains(where: sourceFamily.contains)
            if self == .original || traits.contains(monoTrait) || symbolFont {
                descriptor = original.fontDescriptor
            } else {
                let design: ReadingFontDescriptor.SystemDesign = switch self {
                case .serif: .serif
                case .monospaced: .monospaced
                case .rounded: .rounded
                default: .default
                }
                let family = familyName.map { ReadingFontDescriptor(fontAttributes: [.family: $0]) }
                    ?? bodyFont.fontDescriptor.withDesign(design) ?? bodyFont.fontDescriptor
                let styled: ReadingFontDescriptor? = family.withSymbolicTraits(family.symbolicTraits.union(traits.intersection(styleTraits)))
                descriptor = styled ?? family
            }
            let font: ReadingFont? = ReadingFont(descriptor: descriptor, size: newSize)
            if let font { styled.addAttribute(.font, value: font, range: range) }
        }
        return styled
    }
}

extension MailReadingFont {
    // The isolated WebKit world keeps original inline declarations so changing
    // the reading font can update the open document without a new navigation.
    static let webScript = #"""
    (() => {
    let entries;
    let currentFamily = '';
    let currentSize = 14;
    function restore(element, property, value, priority) {
        if (value) element.style.setProperty(property, value, priority);
        else element.style.removeProperty(property);
    }
    function measureRuns() {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        const parents = new Set();
        while (walker.nextNode()) {
            if (walker.currentNode.nodeValue.trim()) parents.add(walker.currentNode.parentElement);
        }
        const runs = [];
        for (const element of parents) {
            if (!(element instanceof HTMLElement) || element.closest('script,style,svg,math')) continue;
            const style = getComputedStyle(element);
            const firstFamily = style.fontFamily.split(',')[0].trim().replace(/^['"]|['"]$/g, '');
            const protectedFace = !!element.closest('pre,code,kbd,samp,tt') ||
                /mono|courier|consolas|menlo|monaco|font.?awesome|material (icons|symbols)|iconfont|wingdings|webdings|dingbats|\bemoji\b|^symbol$/i.test(firstFamily);
            runs.push({
                element, family: element.style.getPropertyValue('font-family'),
                familyPriority: element.style.getPropertyPriority('font-family'),
                size: element.style.getPropertyValue('font-size'),
                sizePriority: element.style.getPropertyPriority('font-size'),
                lineHeight: element.style.getPropertyValue('line-height'),
                lineHeightPriority: element.style.getPropertyPriority('line-height'),
                // A fixed line height must grow with the text, or larger text overlaps.
                linePixels: style.lineHeight.endsWith('px') ? parseFloat(style.lineHeight) : NaN,
                protectedFamily: protectedFace ? style.fontFamily : null, pixels: parseFloat(style.fontSize)
            });
        }
        return runs;
    }
    function restoreRuns() {
        for (const run of entries) {
            restore(run.element, 'font-family', run.family, run.familyPriority);
            restore(run.element, 'font-size', run.size, run.sizePriority);
            restore(run.element, 'line-height', run.lineHeight, run.lineHeightPriority);
        }
    }
    globalThis.postmereReadingType = (family, size) => {
        if (!document.body || family === currentFamily && size === currentSize) return;
        if (entries) restoreRuns();
        if (!family && size === 14) {
            entries = undefined;
        } else {
            if (!entries) entries = measureRuns();
            for (const run of entries) {
                if (family) run.element.style.setProperty('font-family', run.protectedFamily || family, 'important');
                if (size !== 14 && Number.isFinite(run.pixels)) {
                    run.element.style.setProperty('font-size', (run.pixels * size / 14) + 'px', 'important');
                    if (Number.isFinite(run.linePixels)) {
                        run.element.style.setProperty('line-height', (run.linePixels * size / 14) + 'px', 'important');
                    }
                }
            }
        }
        currentFamily = family;
        currentSize = size;
    };
    // Re-evaluate authored media queries when the reader width changes.
    let lastWidth = innerWidth;
    window.addEventListener('resize', () => {
        if (innerWidth === lastWidth) return;
        lastWidth = innerWidth;
        if (!entries) return;
        const family = currentFamily, size = currentSize;
        globalThis.postmereReadingType('', 14);
        globalThis.postmereReadingType(family, size);
    });
    })();
    """#
}
