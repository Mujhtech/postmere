import AppKit
import SwiftUI

nonisolated enum MailReadingFont: String, CaseIterable, Sendable {
    case original, sansSerif, serif, monospaced

    static let preference = "mailReadingFont"

    var title: String {
        switch self {
        case .original: "Sender’s font"
        case .sansSerif: "Sans serif"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .original, .sansSerif: .system(size: size)
        case .serif: .system(size: size, design: .serif)
        case .monospaced: .system(size: size, design: .monospaced)
        }
    }

    var cssFamily: String {
        switch self {
        case .original: ""
        case .sansSerif: "-apple-system, sans-serif"
        case .serif: "ui-serif, Georgia, serif"
        case .monospaced: "ui-monospace, Menlo, monospace"
        }
    }

    func format(_ source: NSAttributedString, size: CGFloat) -> NSAttributedString {
        guard self != .original || size != 14 else { return source }
        let styled = NSMutableAttributedString(attributedString: source)
        let bodyFont = NSFont.systemFont(ofSize: size)
        source.enumerateAttribute(.font, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            guard let original = value as? NSFont else { return }
            let traits = original.fontDescriptor.symbolicTraits
            let newSize = original.pointSize * size / 14
            let descriptor: NSFontDescriptor
            let sourceFamily = (original.familyName ?? original.fontName).lowercased()
            let symbolFont = ["symbol", "dingbats", "wingdings", "webdings", "emoji", "font awesome", "material icons"]
                .contains(where: sourceFamily.contains)
            if self == .original || traits.contains(.monoSpace) || symbolFont {
                descriptor = original.fontDescriptor
            } else {
                let design: NSFontDescriptor.SystemDesign = switch self {
                case .serif: .serif
                case .monospaced: .monospaced
                case .original, .sansSerif: .default
                }
                let family = bodyFont.fontDescriptor.withDesign(design) ?? bodyFont.fontDescriptor
                descriptor = family.withSymbolicTraits(family.symbolicTraits.union(traits.intersection([.bold, .italic])))
            }
            if let font = NSFont(descriptor: descriptor, size: newSize) {
                styled.addAttribute(.font, value: font, range: range)
            }
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
                protectedFamily: protectedFace ? style.fontFamily : null, pixels: parseFloat(style.fontSize)
            });
        }
        return runs;
    }
    function restoreRuns() {
        for (const run of entries) {
            restore(run.element, 'font-family', run.family, run.familyPriority);
            restore(run.element, 'font-size', run.size, run.sizePriority);
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
