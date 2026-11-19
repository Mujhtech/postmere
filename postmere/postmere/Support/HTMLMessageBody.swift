import AppKit
import SwiftUI
import WebKit

/// Displays one message inside the reader's scroll view. Each message owns its image-loading choice.
struct HTMLMessageBody: View {
    let html: String
    let paragraphs: [String]
    let fontSize: Double
    var onBlockedTrackerCountChange: (Int) -> Void = { _ in }

    @AppStorage("loadRemoteMailImagesAutomatically") private var automaticImages = true
    @AppStorage("blockSenderTrackingPixels") private var blocksTrackers = true
    @State private var layout = MessageHTMLLayout()
    @State private var page: WebPage?
    @State private var consentedHTML: String?
    @State private var imageError: String?
    @State private var failed = false
    @State private var verticalEdges = HTMLScrollEdges()

    private var loadsImages: Bool { automaticImages || consentedHTML == html }

    private struct Source: Equatable {
        let html: String
        let fontSize: Double
        let loadsImages: Bool
        let blocksTrackers: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if layout.hasRemoteImages && !loadsImages && !failed {
                Button("Load Remote Images") { imageError = nil; consentedHTML = html }
                    .controlSize(.small)
                    .tint(PostmereTheme.accentInk)
                    .help("Allow images from the sender’s servers for this message")
            }
            if let imageError { Text(imageError).font(.caption).foregroundStyle(.secondary) }
            if failed {
                RichTextMessageBody(rtf: nil, paragraphs: paragraphs, fontSize: fontSize)
                    .textSelection(.enabled)
            } else {
                ZStack(alignment: .topLeading) {
                    if !layout.hasDocumentLayout { openingPreview }
                    if let page { renderedMessage(page) }
                }
            }
        }
        .onChange(of: layout.blockedTrackerCount, initial: true) { _, count in onBlockedTrackerCountChange(count) }
        .onChange(of: automaticImages) { consentedHTML = nil }
        .task(id: Source(html: html, fontSize: fontSize, loadsImages: loadsImages, blocksTrackers: blocksTrackers)) {
            await loadMessage()
        }
        .onDisappear { page?.stopLoading() }
    }

    @ViewBuilder private var openingPreview: some View {
        if let first = paragraphs.first(where: { !$0.isEmpty }) {
            Text(verbatim: String(first.prefix(600)))
                .font(.system(size: fontSize))
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProgressView("Loading message…").controlSize(.small)
        }
    }

    private func renderedMessage(_ page: WebPage) -> some View {
        WebView(page)
            .webViewLinkPreviews(.disabled)
            .webViewBackForwardNavigationGestures(.disabled)
            .webViewElementFullscreenBehavior(.disabled)
            .webViewContentBackground(.hidden)
            .webViewOnScrollGeometryChange(for: HTMLScrollEdges.self) { geometry in
                HTMLScrollEdges(above: geometry.visibleRect.minY > 1,
                                below: geometry.visibleRect.maxY < geometry.contentSize.height - 1)
            } action: { _, edges in
                verticalEdges = edges
            }
            .overlay {
                HTMLWheelRouter(capped: layout.isHeightCapped, edges: verticalEdges)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: layout.height)
            .opacity(layout.hasDocumentLayout ? 1 : 0)
            .accessibilityHidden(!layout.hasDocumentLayout)
            .accessibilityLabel("Message body")
    }

    private func loadMessage() async {
        page?.stopLoading()
        let currentPage = layout.makePage()
        page = currentPage
        failed = false
        imageError = nil

        // Inspect sender markup under a data-only image policy before any remote
        // request can start, including when automatic images are enabled.
        do {
            for try await _ in currentPage.load(html: document(remoteImages: false)) { try Task.checkCancellation() }
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
            guard loadsImages, layout.hasRemoteImages else { return }

            if blocksTrackers && !resources.isEmpty {
                do { try await layout.protectTrackingPixels(resources) }
                catch {
                    if !Task.isCancelled { imageError = "Remote images could not be loaded with tracking protection." }
                    return
                }
            }
            try Task.checkCancellation()
            for try await _ in currentPage.load(html: document(remoteImages: true)) { try Task.checkCancellation() }
        } catch {
            guard !Task.isCancelled else { return }
            if layout.hasDocumentLayout { imageError = "Some message content could not be loaded." }
            else { failed = true }
        }
    }

    private func document(remoteImages: Bool) -> String {
        let images = remoteImages ? "data: https:" : "data:"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="postmere-image-pass" content="\(remoteImages ? "display" : "inspect")">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src \(images); form-action 'none'; base-uri 'none'">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta name="referrer" content="no-referrer">
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; display: flow-root; font: \(fontSize)px -apple-system, sans-serif; overflow-wrap: anywhere; }
        img, table { max-width: 100% !important; }
        img { object-fit: contain; }
        pre { white-space: pre-wrap; }
        </style>
        \(html)
        """
    }
}

private struct HTMLScrollEdges: Hashable {
    var above = false
    var below = false
}

/// The reader owns vertical input. WebKit handles clicks, text selection, horizontal input,
/// and the part of a very long document that extends beyond its native view.
private struct HTMLWheelRouter: NSViewRepresentable {
    let capped: Bool
    let edges: HTMLScrollEdges

    func makeNSView(context: Context) -> WheelView { WheelView() }

    func updateNSView(_ view: WheelView, context: Context) {
        view.capped = capped
        view.edges = edges
    }

    final class WheelView: NSView {
        var capped = false
        var edges = HTMLScrollEdges()
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .scrollWheel,
                  !event.modifierFlags.contains(.shift),
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  super.hitTest(point) != nil else { return nil }

            if capped {
                if event.scrollingDeltaY > 0 && edges.above { return nil }
                if event.scrollingDeltaY < 0 && edges.below && visibleRect.maxY >= bounds.maxY - 1 { return nil }
            }
            return self
        }

        override func scrollWheel(with event: NSEvent) {
            if let scroll = enclosingScrollView { scroll.scrollWheel(with: event) }
            else { super.scrollWheel(with: event) }
        }
    }
}

/// Measures the body independently of the viewport so widening the reader can also shrink its height.
@Observable
private final class MessageHTMLLayout: NSObject, WKScriptMessageHandler {
    static let maximumHeight: CGFloat = 32_768
    var height: CGFloat = 1
    var hasDocumentLayout = false
    var isHeightCapped = false
    var hasRemoteImages = false

    var blockedTrackerCount = 0
    @ObservationIgnored private weak var pageController: WKUserContentController?

    func makePage() -> WebPage {
        height = 1
        hasDocumentLayout = false
        isHeightCapped = false
        blockedTrackerCount = 0
        hasRemoteImages = false
        let controller = WKUserContentController()
        controller.add(self, contentWorld: .defaultClient, name: "messageLayout")
        pageController = controller
        let measure = #"""
        let analyzed = false;
        let lastHeight;
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
            if (!value) return null;
            try {
                const url = new URL(value.trim().replace(/^\/\//, 'https://'));
                url.hash = '';
                return ['http:', 'https:'].includes(url.protocol) ? url.href : null;
            } catch { return null; }
        };
        const report = () => {
            const body = document.body;
            if (!body) return;
            const height = Math.ceil(Math.max(body.getBoundingClientRect().bottom, body.scrollHeight));
            if (height === lastHeight) return;
            lastHeight = height;
            window.webkit.messageHandlers.messageLayout.postMessage({ height });
        };
        document.addEventListener('securitypolicyviolation', event => {
            if (event.effectiveDirective !== 'img-src') return;
            const url = remoteURL(event.blockedURI);
            if (url?.startsWith('https:')) blockedResources.add(url);
        });
        document.addEventListener('DOMContentLoaded', () => {
            if (!document.body) return;
            document.querySelectorAll('a[target]').forEach(link => link.target = '_self');
            new ResizeObserver(report).observe(document.body);
            report();
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
            const remoteStyles = [...document.querySelectorAll('style, [style]')]
                .map(node => (node.tagName === 'STYLE' ? node.textContent : '') + (node.getAttribute('style') || ''))
                .filter(css => /(?:url|image-set)\([^)]*(?:https:)?\/\//i.test(css));
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
            const hasRemoteStyleSheet = [...document.querySelectorAll('style')].some(node =>
                remoteStyles.includes(node.textContent));
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
        let rules = try MailTrackingPixelRules.encoded(for: trackingURLs)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let store = WKContentRuleListStore(url: folder) else { throw URLError(.cannotCreateFile) }
        let list = try await store.compileContentRuleList(forIdentifier: "mail-tracking-pixels",
                                                          encodedContentRuleList: rules)
        try Task.checkCancellation()
        guard let list, controller === pageController else { throw URLError(.cancelled) }
        controller.add(list)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, userContentController === pageController,
              let values = message.body as? [String: Any] else { return }
        guard let height = values["height"] as? Double, height.isFinite else { return }
        // Very long messages retain WebKit scrolling beyond the native view's drawing area.
        isHeightCapped = height > Self.maximumHeight
        self.height = min(Self.maximumHeight, max(1, height))
        hasDocumentLayout = true
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
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }
}
