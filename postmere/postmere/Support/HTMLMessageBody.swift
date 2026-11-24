import SwiftUI
import WebKit

/// Displays one message inside the reader's scroll view. Each message owns its image-loading choice.
struct HTMLMessageBody: View {
    @Environment(\.postmereAccent) private var palette
    let html: String
    let paragraphs: [String]
    let fontSize: Double
    var readingFont = MailReadingFont.original
    var quoteContext: MailQuoteContext?
    var onBlockedTrackerCountChange: (Int) -> Void = { _ in }

    @AppStorage("loadRemoteMailImagesAutomatically") private var automaticImages = true
    @AppStorage("blockSenderTrackingPixels") private var blocksTrackers = true
    @State private var layout = MessageHTMLLayout()
    @State private var page: WebPage?
    @State private var loadedSource: Source?
    @State private var consentedHTML: String?
    @State private var imageError: String?
    @State private var failed = false
    @State private var documentGeneration = 0
    /// Hides the first, image-less inspection pass so the message appears once,
    /// complete, instead of rendering twice.
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var loadsImages: Bool { automaticImages || consentedHTML == html }

    private struct Source: Equatable {
        let html: String
        let loadsImages: Bool
        let blocksTrackers: Bool
        let quoteContext: MailQuoteContext?
    }
    private struct Typography: Equatable {
        let font: MailReadingFont
        let size: Double
        let document: Int
    }

    var body: some View {
        let source = Source(html: html, loadsImages: loadsImages, blocksTrackers: blocksTrackers,
                            quoteContext: quoteContext)
        VStack(alignment: .leading, spacing: 8) {
            if layout.hasRemoteImages && !loadsImages && !failed {
                Button("Load Remote Images") { imageError = nil; consentedHTML = html }
                    .controlSize(.small)
                    .tint(palette.accentInk)
                    .help("Allow images from the sender’s servers for this message")
            }
            if let imageError { Text(imageError).font(.caption).foregroundStyle(.secondary) }
            if failed {
                RichTextMessageBody(rtf: nil, paragraphs: paragraphs, fontSize: fontSize, readingFont: readingFont, quoteContext: quoteContext)
                    .textSelection(.enabled)
            } else {
                ZStack(alignment: .topLeading) {
                    if !isVisible {
                        MessageBodySkeleton(fontSize: fontSize)
                            .transition(.opacity)
                    }
                    if let page { renderedMessage(page) }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: isVisible)
            }
        }
        .onChange(of: layout.blockedTrackerCount, initial: true) { _, count in onBlockedTrackerCountChange(count) }
        .onChange(of: automaticImages) { consentedHTML = nil }
        .task(id: palette.rgb) {
            _ = try? await page?.callJavaScript("document.documentElement.style.setProperty('--postmere-quote-ink', ink)",
                                                arguments: ["ink": palette.accentInkCSS], contentWorld: .defaultClient)
        }
        .task(id: Typography(font: readingFont, size: fontSize, document: documentGeneration)) {
            guard documentGeneration > 0, let page else { return }
            _ = try? await page.callJavaScript("globalThis.postmereReadingType?.(family, size)",
                                                arguments: ["family": readingFont.cssFamily, "size": fontSize],
                                                contentWorld: .defaultClient)
        }
        .task(id: source) {
            if loadedSource != source { await loadMessage(source) }
        }
        .onDisappear { page?.stopLoading() }
    }

    private var isVisible: Bool { revealed && layout.hasDocumentLayout }

    private func renderedMessage(_ page: WebPage) -> some View {
        MessageWebView(page: page, documentHeight: layout.height,
                       needsReaderViewport: layout.needsReaderViewport || !isVisible)
            .opacity(isVisible ? 1 : 0)
            .accessibilityHidden(!isVisible)
            .accessibilityLabel("Message body")
    }

    private func loadMessage(_ source: Source) async {
        // Reveal when the final pass is ready, or after a short wait so slow
        // image servers never hold the message back.
        revealed = false
        let reveal = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            if !Task.isCancelled { revealed = true }
        }
        defer { reveal.cancel(); if !Task.isCancelled { revealed = true } }
        loadedSource = nil
        page?.stopLoading()
        let currentPage = layout.makePage(quoteContext: quoteContext, readingFont: readingFont, size: fontSize)
        page = currentPage
        failed = false
        imageError = nil

        do {
            // When both remote images and sender trackers are allowed, one navigation suffices.
            // All other combinations start with a data-only policy for inspection.
            let directDisplay = loadsImages && !blocksTrackers
            try await loadDocument(in: currentPage, remoteImages: directDisplay)
            if directDisplay { loadedSource = source; return }
            try Task.checkCancellation()
            let result = try await currentPage.callJavaScript("return globalThis.postmereImageAnalysis?.()",
                                                              contentWorld: .defaultClient)
            try Task.checkCancellation()
            guard let analysis = result as? [String: Any],
                  let resources = analysis["trackingURLs"] as? [String],
                  let count = analysis["blockedTrackerCount"] as? Int,
                  let ordinary = analysis["hasOrdinaryImages"] as? Bool,
                  let trackingImages = analysis["hasRemoteTrackingImages"] as? Bool else {
                // Keep the fully readable, restricted document if analysis could not finish.
                return
            }
            layout.blockedTrackerCount = blocksTrackers ? count : 0
            layout.hasRemoteImages = ordinary || (!blocksTrackers && trackingImages)
            guard loadsImages, layout.hasRemoteImages else { loadedSource = source; return }

            if blocksTrackers && !resources.isEmpty {
                do { try await layout.protectTrackingPixels(resources) }
                catch {
                    if !Task.isCancelled { imageError = "Remote images could not be loaded with tracking protection." }
                    return
                }
            }
            try Task.checkCancellation()
            try await loadDocument(in: currentPage, remoteImages: true)
            loadedSource = source
        } catch {
            guard !Task.isCancelled else { return }
            if layout.hasDocumentLayout { imageError = "Some message content could not be loaded." }
            else { failed = true }
        }
    }

    private func loadDocument(in page: WebPage, remoteImages: Bool) async throws {
        let document = await Self.document(html: html, remoteImages: remoteImages, ink: palette.accentInkCSS)
        try Task.checkCancellation()
        for try await _ in page.load(html: document) { try Task.checkCancellation() }
        try Task.checkCancellation()
        documentGeneration += 1
    }

    @concurrent private static func document(html: String, remoteImages: Bool, ink: String) async -> String {
        let images = remoteImages ? "data: https:" : "data:"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="postmere-image-pass" content="\(remoteImages ? "display" : "inspect")">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src \(images); form-action 'none'; base-uri 'none'">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta name="referrer" content="no-referrer">
        <style id="postmere-reader-styles">
        :root { color-scheme: light dark; overflow-y: hidden !important; --postmere-quote-ink: \(ink); }
        body { margin: 0; display: flow-root; font: 14px -apple-system, sans-serif; overflow-wrap: anywhere; }
        img, table { max-width: 100% !important; }
        img { object-fit: contain; }
        pre { white-space: pre-wrap; }
        </style>
        \(html)
        """
    }
}

/// Stands in for the body while it renders: a few soft lines at the reading
/// size, gently pulsing unless Reduce Motion is on.
private struct MessageBodySkeleton: View {
    let fontSize: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        let line = max(8, fontSize * 0.7)
        VStack(alignment: .leading, spacing: line * 0.9) {
            ForEach(Array([0.92, 0.98, 0.85, 0.95, 0.6].enumerated()), id: \.offset) { _, width in
                GeometryReader { proxy in
                    Capsule().fill(.quaternary).frame(width: proxy.size.width * width, height: line)
                }
                .frame(height: line)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dim ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading message")
    }
}

/// Let AppKit scroll the web surface together with the message header. Only HTML
/// whose layout depends on the viewport needs an independently positioned WebView.
private struct MessageWebView: View {
    let page: WebPage
    let documentHeight: CGFloat
    let needsReaderViewport: Bool

    private nonisolated struct Window: Equatable, Sendable {
        var height: CGFloat
        var offset: CGFloat = 0
    }
    @State private var window = Window(height: 1)
    @State private var webPosition = ScrollPosition(edge: .top)
    @State private var horizontalOffset: CGFloat = 0

    var body: some View {
        let height = needsReaderViewport ? window.height : documentHeight
        let offset = needsReaderViewport ? window.offset : 0
        WebView(page)
            .webViewLinkPreviews(.disabled)
            .webViewBackForwardNavigationGestures(.disabled)
            .webViewElementFullscreenBehavior(.disabled)
            .webViewContentBackground(.hidden)
            .webViewScrollPosition($webPosition)
            .webViewOnScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                horizontalOffset = x
            }
            .onChange(of: offset) { webPosition.scrollTo(x: horizontalOffset, y: offset) }
            .frame(height: height)
            .offset(y: offset)
            .frame(height: documentHeight, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            #if os(macOS)
            .overlay { HTMLWheelRouter().accessibilityHidden(true) }
            #else
            // The reader's scroll view moves the whole message. The web view is
            // already as tall as the email, so its own scroller would only
            // capture touches and bounce separately.
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            #endif
            .onGeometryChange(for: Window.self) { geometry in
                guard needsReaderViewport, let viewport = geometry.bounds(of: .scrollView(axis: .vertical))
                else { return Window(height: documentHeight) }
                let height = max(1, viewport.height)
                return Window(height: height, offset: min(max(0, viewport.minY), max(0, documentHeight - height)))
            } action: { window = $0 }
    }
}

/// Keep a trackpad gesture with one scroller, including its momentum. The
/// first event often has zero delta, before AppKit knows its direction.
#if os(macOS)
private struct HTMLWheelRouter: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) {}

    final class WheelView: NSView {
        private var passesHitThrough = false
        private var vertical: Bool?
        private var beginning: NSEvent?
        private weak var horizontalTarget: NSView?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !passesHitThrough, NSApp.currentEvent?.type == .scrollWheel else { return nil }
            return super.hitTest(point)
        }

        override func scrollWheel(with event: NSEvent) {
            let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
            if !phased || event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                vertical = nil
                beginning = nil
                horizontalTarget = nil
            }
            if vertical == nil {
                let x = abs(event.scrollingDeltaX), y = abs(event.scrollingDeltaY)
                guard x > 0 || y > 0 else {
                    if event.phase.contains(.began) { beginning = event }
                    return
                }
                vertical = y >= x && !event.modifierFlags.contains(.shift)
            }
            if vertical == false, horizontalTarget == nil, let root = window?.contentView {
                passesHitThrough = true
                let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                horizontalTarget = root.hitTest(point)
                passesHitThrough = false
            }
            let target = vertical == true ? enclosingScrollView : horizontalTarget
            if let beginning {
                target?.scrollWheel(with: beginning)
                self.beginning = nil
            }
            target?.scrollWheel(with: event)
            if !phased || event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
                vertical = nil
                horizontalTarget = nil
            }
        }
    }
}
#endif

/// Measures the body independently of the viewport so widening the reader can also shrink its height.
@Observable
private final class MessageHTMLLayout: NSObject, WKScriptMessageHandler {
    var height: CGFloat = 1
    var needsReaderViewport = false
    var hasDocumentLayout = false
    var hasRemoteImages = false

    var blockedTrackerCount = 0
    @ObservationIgnored private weak var pageController: WKUserContentController?

    func makePage(quoteContext: MailQuoteContext?, readingFont: MailReadingFont, size: Double) -> WebPage {
        height = 1
        hasDocumentLayout = false
        needsReaderViewport = false
        blockedTrackerCount = 0
        hasRemoteImages = false
        let controller = WKUserContentController()
        controller.add(self, contentWorld: .defaultClient, name: "messageLayout")
        pageController = controller
        let measure = #"""
        let analyzed = false;
        let lastHeight, lastViewport, lastWidth;
        let needsReaderViewport = false;
        let hasOrdinaryImages = false;
        const blockedResources = new Set();
        const trackerURLs = new Set();
        const pixels = new Set();
        let hasRemoteCSS = false;
        globalThis.postmereImageAnalysis = () => {
            if (!analyzed) return null;
            const trackingURLs = [...trackerURLs];
            // WebKit sometimes redacts a blocked URL to just its origin.
            const trackingOrigins = new Set(trackingURLs.map(url => new URL(url).origin));
            return {
                trackingURLs, blockedTrackerCount: pixels.size,
                hasOrdinaryImages: hasOrdinaryImages || hasRemoteCSS || [...blockedResources].some(url =>
                    !trackerURLs.has(url) && !trackingOrigins.has(url.replace(/\/$/, ''))),
                hasRemoteTrackingImages: trackingURLs.some(url => url.startsWith('https:'))
            };
        };
        const remoteURL = value => {
            if (!value || /^\s*data:/i.test(value)) return null;
            try {
                const url = new URL(value.trim().replace(/^\/\//, 'https://'));
                url.hash = '';
                return ['http:', 'https:'].includes(url.protocol) ? url.href : null;
            } catch { return null; }
        };
        const report = () => {
            const body = document.body;
            if (!body) return;
            const box = body.getBoundingClientRect();
            const bottomMargin = parseFloat(getComputedStyle(body).marginBottom) || 0;
            const root = document.documentElement;
            // The root's scrollHeight includes the viewport even for a short email.
            const rootOverflow = root.scrollHeight > root.clientHeight ? root.scrollHeight : 0;
            const height = Math.ceil(Math.max(rootOverflow,
                window.scrollY + box.top + Math.max(box.height, body.scrollHeight) + bottomMargin));
            // If stretching the web surface to its last measured content height
            // changes the content height again, the email depends on its viewport.
            if (lastHeight !== undefined && window.innerHeight === lastHeight &&
                window.innerHeight !== lastViewport && window.innerWidth === lastWidth &&
                Math.abs(height - lastHeight) > 1) needsReaderViewport = true;
            if (height === lastHeight && window.innerHeight === lastViewport) return;
            lastHeight = height;
            lastViewport = window.innerHeight;
            lastWidth = window.innerWidth;
            window.webkit.messageHandlers.messageLayout.postMessage({ height, needsReaderViewport });
        };
        document.addEventListener('securitypolicyviolation', event => {
            if (event.effectiveDirective !== 'img-src') return;
            const url = remoteURL(event.blockedURI);
            if (url?.startsWith('https:')) blockedResources.add(url);
        });
        document.addEventListener('DOMContentLoaded', () => {
            if (!document.body) return;
            document.querySelectorAll('a[target]').forEach(link => link.target = '_self');
            document.documentElement.style.setProperty('overflow-y', 'hidden', 'important');
            // Some newsletters put the whole message in a fixed-height scrolling wrapper.
            // Expand those containers while preserving clipped preheaders and horizontal overflow.
            const readerStyle = document.getElementById('postmere-reader-styles');
            const sheets = [...document.querySelectorAll('style')].filter(node => node !== readerStyle).map(node => node.textContent);
            const isViewportSized = /(?:\d|\.)(?:[dsl]?v(?:h|b|min|max))\b|@media[^{}]*(?:height|orientation|aspect-ratio)\b/i;
            needsReaderViewport = sheets.some(css => isViewportSized.test(css)) ||
                [...document.querySelectorAll('[style*="vh" i],[style*="vb" i],[style*="vmin" i],[style*="vmax" i]')]
                    .some(element => isViewportSized.test(element.getAttribute('style')));
            const scrollerSelector = sheets.some(css => /\boverflow(?:-[xy]|-block|-inline)?\s*:/i.test(css)) ?
                'body, body *' : '[style*="overflow" i]';
            const scrollers = [...document.querySelectorAll(scrollerSelector)].reverse().filter(element =>
                element instanceof HTMLElement && !element.matches('textarea, select, input') &&
                ['auto', 'scroll'].includes(getComputedStyle(element).overflowY));
            const fitScrollers = () => {
                // Expand descendants first, so a fixed-height ancestor can see the new content size.
                for (const element of scrollers) {
                    if (!element.clientHeight || element.scrollHeight <= element.clientHeight + 1) continue;
                    element.style.setProperty('height', 'auto', 'important');
                    element.style.setProperty('max-height', 'none', 'important');
                    element.style.setProperty('overflow-y', 'visible', 'important');
                }
                report();
            };
            let pending = false;
            const scheduleFit = () => {
                if (pending) return;
                pending = true;
                requestAnimationFrame(() => { pending = false; fitScrollers(); });
            };
            new ResizeObserver(scheduleFit).observe(document.body);
            window.addEventListener('resize', scheduleFit);
            document.addEventListener('load', scheduleFit, true);
            document.addEventListener('toggle', scheduleFit, true);
            fitScrollers();
            // The local document has no HTTPS base for scheme-relative image URLs.
            for (const node of document.querySelectorAll('img, picture source, [background]')) {
                for (const attr of ['src', 'srcset', 'background']) {
                    const value = node.getAttribute(attr);
                    if (!value) continue;
                    const resolved = value.replace(/(^|\s+|,\s+)(?=\/\/)/g, '$1https:');
                    if (resolved !== value) node.setAttribute(attr, resolved);
                }
            }
            if (document.querySelector('meta[name="postmere-image-pass"]').content === 'display') return;
            const displayURLs = new Set();
            const remoteStyles = [];
            let hasRemoteStyleSheet = false;
            for (const node of document.querySelectorAll('style, [style]')) {
                const sheet = node.tagName === 'STYLE';
                const css = sheet ? node.textContent + (node.getAttribute('style') || '') : node.getAttribute('style');
                if (/(?:url|image-set)\([^)]*(?:https:)?\/\//i.test(css)) {
                    remoteStyles.push(css);
                    if (sheet) hasRemoteStyleSheet = true;
                }
            }
            // A missing image can have a zero layout size. A hidden responsive
            // banner is not a beacon just because it is currently invisible.
            const pixelLength = value => {
                if (!value || !/^\s*\d+(?:\.\d+)?(?:px)?\s*$/i.test(value)) return null;
                return parseFloat(value);
            };
            const pixelSized = element => {
                const style = getComputedStyle(element);
                const size = axis => {
                    const declared = pixelLength(element.style[axis]) ?? pixelLength(element.getAttribute(axis));
                    const max = pixelLength(style.getPropertyValue('max-' + axis));
                    if (max !== null && max <= 2) return true;
                    if (declared !== null) return declared <= 2;
                    const computed = pixelLength(style[axis]);
                    return computed !== null && computed > 0 ? computed <= 2 : null;
                };
                const width = size('width'), height = size('height');
                if (width === true && height === true) return true;
                const hidden = element.hidden || style.display === 'none' ||
                    style.visibility === 'hidden' || style.opacity === '0';
                return hidden && (width === true && height === null || height === true && width === null);
            };
            const openEndpoint = address => {
                const { hostname, pathname } = new URL(address);
                const on = domain => hostname === domain || hostname.endsWith('.' + domain);
                return (on('sendgrid.net') && /^\/wf\/open\/?$/.test(pathname)) ||
                    ((on('list-manage.com') || on('mandrillapp.com')) && pathname === '/track/open.php');
            };
            const classify = (urls, selected, isPixel) => {
                for (const url of urls) {
                    if (isPixel || openEndpoint(url)) trackerURLs.add(url);
                    else displayURLs.add(url);
                }
                if (selected && trackerURLs.has(selected)) pixels.add(selected);
            };
            const imageURLs = element => {
                const result = [];
                for (const attr of ['src', 'srcset', 'background']) {
                    const value = element.getAttribute(attr);
                    if (!value) continue;
                    const candidates = attr === 'srcset' ? value.split(/,(?=\s*(?:https?:|\/\/))/i).map(item => item.trim().split(/\s+/)[0]) : [value];
                    for (const candidate of candidates) { const url = remoteURL(candidate); if (url) result.push(url); }
                }
                return result;
            };
            for (const image of document.images) {
                const sources = image.closest('picture')?.querySelectorAll('source') || [];
                const urls = [...imageURLs(image), ...[...sources].flatMap(imageURLs)];
                const selected = image.currentSrc || image.getAttribute('src');
                classify(urls, selected ? remoteURL(selected) : urls[0], urls.length && pixelSized(image));
            }
            const cssURLs = css => [...css.matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/gi)]
                .map(match => remoteURL(match[1])).filter(Boolean);
            // Include background pixels applied by newsletter CSS as well as HTML attributes.
            const backgrounds = document.querySelectorAll(hasRemoteStyleSheet ? '*' : '[background], [style*="background" i]');
            for (const element of backgrounds) {
                const urls = cssURLs(getComputedStyle(element).backgroundImage);
                const attribute = remoteURL(element.getAttribute('background'));
                if (attribute) urls.push(attribute);
                if (urls.length) {
                    const tiny = pixelSized(element);
                    for (const url of urls) classify([url], url, tiny);
                }
            }
            hasRemoteCSS = remoteStyles.some(css => {
                const urls = cssURLs(css);
                return !urls.length || urls.some(url => !trackerURLs.has(url));
            });
            hasOrdinaryImages = [...displayURLs].some(url => url.startsWith('https:') && !trackerURLs.has(url));
            analyzed = true;
        }, { once: true });
        """#
        controller.addUserScript(WKUserScript(source: measure, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
        let typography = MailReadingFont.webScript + "\nglobalThis.postmereReadingType('\(readingFont.cssFamily)', \(size));"
        controller.addUserScript(WKUserScript(source: typography, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        if let quoteContext { MailHTMLQuoteDisclosure(context: quoteContext).install(in: controller) }
        var config = WebPage.Configuration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController = controller
        config.defaultNavigationPreferences.allowsContentJavaScript = false
        config.deviceSensorAuthorization = .init(decision: .deny)
        return WebPage(configuration: config, navigationDecider: MessageLinkPolicy())
    }

    /// Install resource rules before relaxing the document's image policy. These also
    /// block a detected pixel URL if another element or a stylesheet references it.
    func protectTrackingPixels(_ trackingURLs: [String]) async throws {
        guard let controller = pageController else { throw URLError(.cancelled) }
        let list = try await MessageTrackerRuleCache.rules(for: trackingURLs)
        try Task.checkCancellation()
        guard controller === pageController else { throw URLError(.cancelled) }
        controller.add(list)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, userContentController === pageController,
              let values = message.body as? [String: Any] else { return }
        guard let height = values["height"] as? Double, height.isFinite else { return }
        let nextHeight = max(1, height)
        if nextHeight != self.height { self.height = nextHeight }
        needsReaderViewport = values["needsReaderViewport"] as? Bool == true
        hasDocumentLayout = true
    }
}

/// Reopening an email can reuse a compiled blocker. Each document still inspects its
/// own markup and must produce the same resource list before it can use the blocker.
@MainActor private enum MessageTrackerRuleCache {
    private static let cache: NSCache<NSArray, WKContentRuleList> = {
        let cache = NSCache<NSArray, WKContentRuleList>()
        cache.countLimit = 24
        cache.totalCostLimit = 256 * 1024
        return cache
    }()

    static func rules(for urls: [String]) async throws -> WKContentRuleList {
        let key = urls as NSArray
        if let cached = cache.object(forKey: key) { return cached }
        let (rules, folder) = try await prepare(urls)
        defer { Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) } }
        try Task.checkCancellation()
        guard let store = WKContentRuleListStore(url: folder),
              let list = try await store.compileContentRuleList(forIdentifier: "mail-tracking-pixels",
                                                                 encodedContentRuleList: rules)
        else { throw URLError(.cannotCreateFile) }
        cache.setObject(list, forKey: key, cost: rules.utf8.count)
        return list
    }

    @concurrent private static func prepare(_ urls: [String]) async throws -> (String, URL) {
        try Task.checkCancellation()
        let rules = try MailTrackingPixelRules.encoded(for: urls)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (rules, folder)
    }
}

private struct MessageLinkPolicy: WebPage.NavigationDeciding {
    func decidePolicy(for action: WebPage.NavigationAction,
                      preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if action.target?.isMainFrame == true,
           url.absoluteString == "about:blank" || url.absoluteString.hasPrefix("about:blank#") {
            return .allow
        }
        if action.navigationType == .linkActivated, action.source.isMainFrame,
           ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            MailPlatform.open(url)
        }
        return .cancel
    }
}
