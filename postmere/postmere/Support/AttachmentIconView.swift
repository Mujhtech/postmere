import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import Darwin

/// A file-specific cover that can upgrade to a local content thumbnail.
/// This view never resolves or downloads a mail provider attachment.
struct AttachmentIconView: View {
    let attachment: MailAttachment
    var size: CGFloat = 40

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var loadedThumbnail: LoadedThumbnail?

    private var fileType: AttachmentFileType {
        AttachmentFileType(name: attachment.name, mimeType: attachment.mimeType, localURL: attachment.localURL)
    }

    private var requestID: ThumbnailIdentity {
        ThumbnailIdentity(attachmentID: attachment.id, url: attachment.localURL, name: attachment.name,
                          mimeType: attachment.mimeType, byteCount: attachment.byteCount,
                          pixels: min(256, max(32, Int(ceil(size * displayScale / 32)) * 32)))
    }

    var body: some View {
        let type = fileType
        let identity = requestID
        let palette = AttachmentPalette(kind: type.kind)
        let illustrationInk = colorScheme == .dark ? palette.lightInk : palette.ink

        ZStack {
            AttachmentPaperShape()
                .fill(colorScheme == .dark ? Color(red: 0.19, green: 0.21, blue: 0.20) : Color(red: 0.99, green: 0.99, blue: 0.97))
            AttachmentPaperShape().fill(illustrationInk.opacity(colorScheme == .dark ? 0.09 : 0.045))
            AttachmentPaperShape().stroke(illustrationInk.opacity(0.32), lineWidth: max(0.7, size * 0.018))

            if let loadedThumbnail, loadedThumbnail.identity == identity {
                Image(decorative: loadedThumbnail.image, scale: displayScale)
                    .resizable().scaledToFit()
                    .frame(width: size * 0.59, height: size * 0.57)
                    .background(.white)
                    .clipShape(.rect(cornerRadius: size * 0.035))
                    .position(x: size * 0.5, y: size * 0.40)
            } else {
                AttachmentMotif(kind: type.kind)
                    .stroke(illustrationInk, style: StrokeStyle(lineWidth: max(1.1, size * 0.036), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.43, height: size * 0.38)
                    .position(x: size * 0.49, y: size * 0.40)
            }

            Path { path in
                path.move(to: CGPoint(x: size * 0.65, y: size * 0.045))
                path.addLine(to: CGPoint(x: size * 0.65, y: size * 0.245))
                path.addQuadCurve(to: CGPoint(x: size * 0.85, y: size * 0.245), control: CGPoint(x: size * 0.72, y: size * 0.27))
                path.closeSubpath()
            }.fill(illustrationInk.opacity(0.13))

            Text(type.badge)
                .font(.system(size: max(6.5, size * 0.19), weight: .bold, design: .rounded))
                .tracking(size * 0.012)
                .lineLimit(1).minimumScaleFactor(0.72)
                .foregroundStyle(.white)
                .frame(width: size * 0.78, height: max(9, size * 0.28))
                .padding(.horizontal, size * 0.045)
                .background(palette.ink, in: .rect(cornerRadius: size * 0.07))
                .position(x: size * 0.5, y: size * 0.79)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(type.badge), \(type.kind.title)")
        .task(id: identity) { await loadThumbnail(identity: identity, contentTypeIdentifier: type.contentTypeIdentifier) }
    }

    private func loadThumbnail(identity: ThumbnailIdentity, contentTypeIdentifier: String?) async {
        guard !Task.isCancelled else { return }
        loadedThumbnail = nil
        guard let url = identity.url, url.isFileURL, !Task.isCancelled else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = await Task.detached(priority: .utility) { AttachmentThumbnailSource.inspect(url: url) }.value
        guard let source, !Task.isCancelled else { return }
        let image = await AttachmentThumbnailCache.shared.image(for: source, pixels: identity.pixels, contentTypeIdentifier: contentTypeIdentifier)
        guard !Task.isCancelled, let image else { return }
        loadedThumbnail = LoadedThumbnail(identity: identity, image: image)
    }

    private struct LoadedThumbnail {
        let identity: ThumbnailIdentity
        let image: CGImage
    }

    private struct ThumbnailIdentity: Hashable {
        let attachmentID: UUID
        let url: URL?
        let name: String
        let mimeType: String?
        let byteCount: Int?
        let pixels: Int
    }
}

private struct AttachmentPalette {
    let ink: Color
    let lightInk: Color

    init(kind: AttachmentFileType.Kind) {
        let hex: (UInt32, UInt32) = switch kind {
        case .pdf: (0xB03F35, 0xF5A89B)
        case .document: (0x3D678F, 0x9DBFE1)
        case .spreadsheet: (0x24775E, 0x8AC8AF)
        case .presentation: (0x9D541E, 0xE7B48C)
        case .image: (0x76608B, 0xCDB5E0)
        case .audio: (0xA0496F, 0xE4A9C2)
        case .video: (0x5161A1, 0xAEBCEB)
        case .archive: (0x8A6B39, 0xDCC495)
        case .code: (0x416C7A, 0x9AC8D6)
        case .file: (0x586A60, 0xBAC9BF)
        }
        ink = Self.color(hex.0)
        lightInk = Self.color(hex.1)
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

private struct AttachmentPaperShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        path.move(to: point(0.21, 0.045))
        path.addLine(to: point(0.65, 0.045))
        path.addLine(to: point(0.85, 0.245))
        path.addLine(to: point(0.85, 0.86))
        path.addQuadCurve(to: point(0.79, 0.92), control: point(0.85, 0.92))
        path.addLine(to: point(0.21, 0.92))
        path.addQuadCurve(to: point(0.15, 0.86), control: point(0.15, 0.92))
        path.addLine(to: point(0.15, 0.105))
        path.addQuadCurve(to: point(0.21, 0.045), control: point(0.15, 0.045))
        path.closeSubpath()
        return path
    }
}

/// Original line artwork, deliberately different for each file family.
private struct AttachmentMotif: Shape {
    let kind: AttachmentFileType.Kind

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        func line(_ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            path.move(to: point(first.0, first.1))
            for next in points.dropFirst() { path.addLine(to: point(next.0, next.1)) }
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            path.addRoundedRect(in: CGRect(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y, width: rect.width * width, height: rect.height * height), cornerSize: CGSize(width: rect.width * 0.04, height: rect.height * 0.04))
        }
        switch kind {
        case .pdf:
            path.move(to: point(0.12, 0.85))
            path.addCurve(to: point(0.47, 0.08), control1: point(0.39, 0.63), control2: point(0.65, 0.03))
            path.addCurve(to: point(0.87, 0.70), control1: point(0.26, 0.09), control2: point(0.61, 0.86))
            path.addCurve(to: point(0.12, 0.85), control1: point(1.02, 0.53), control2: point(0.04, 0.57))
        case .document:
            box(0.08, 0.09, 0.25, 0.22)
            line([(0.46, 0.12), (0.88, 0.12)])
            line([(0.46, 0.30), (0.77, 0.30)])
            line([(0.08, 0.51), (0.88, 0.51)])
            line([(0.08, 0.72), (0.88, 0.72)])
            line([(0.08, 0.91), (0.60, 0.91)])
        case .spreadsheet:
            box(0.05, 0.08, 0.90, 0.82)
            line([(0.05, 0.35), (0.95, 0.35)])
            line([(0.05, 0.63), (0.95, 0.63)])
            line([(0.36, 0.08), (0.36, 0.90)])
            line([(0.66, 0.08), (0.66, 0.90)])
        case .presentation:
            box(0.04, 0.05, 0.92, 0.66)
            line([(0.50, 0.71), (0.50, 0.94)])
            line([(0.29, 0.94), (0.71, 0.94)])
            line([(0.22, 0.54), (0.22, 0.39)])
            line([(0.48, 0.54), (0.48, 0.28)])
            line([(0.74, 0.54), (0.74, 0.18)])
        case .image:
            box(0.04, 0.08, 0.92, 0.82)
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.19, y: rect.minY + rect.height * 0.23, width: rect.width * 0.16, height: rect.height * 0.16))
            line([(0.06, 0.78), (0.35, 0.51), (0.54, 0.68), (0.73, 0.44), (0.94, 0.69)])
        case .audio:
            for (index, height) in ([0.24, 0.55, 0.88, 0.42, 0.70, 0.30] as [CGFloat]).enumerated() {
                let x = 0.08 + CGFloat(index) * 0.165
                line([(x, 0.50 - height / 2), (x, 0.50 + height / 2)])
            }
        case .video:
            box(0.02, 0.12, 0.96, 0.72)
            line([(0.39, 0.30), (0.69, 0.48), (0.39, 0.66), (0.39, 0.30)])
            line([(0.18, 0.12), (0.18, 0.84)])
            line([(0.82, 0.12), (0.82, 0.84)])
        case .archive:
            for index in 0..<4 {
                let y = 0.04 + CGFloat(index) * 0.16
                line([(0.36, y), (0.50, y), (0.50, y + 0.08), (0.64, y + 0.08)])
            }
            box(0.36, 0.73, 0.28, 0.22)
        case .code:
            line([(0.25, 0.20), (0.03, 0.49), (0.25, 0.78)])
            line([(0.75, 0.20), (0.97, 0.49), (0.75, 0.78)])
            line([(0.59, 0.10), (0.41, 0.89)])
        case .file:
            box(0.16, 0.12, 0.68, 0.76)
            line([(0.33, 0.36), (0.67, 0.36)])
            line([(0.33, 0.57), (0.58, 0.57)])
        }
        return path
    }
}

nonisolated private struct AttachmentThumbnailSource: Sendable {
    let url: URL
    let version: String

    static func inspect(url: URL) -> Self? {
        guard url.isFileURL else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                        .volumeIsLocalKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
              values.volumeIsLocal == true else { return nil }
        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current,
           values.ubiquitousItemDownloadingStatus != .downloaded { return nil }
        // File Provider placeholders can be dataless without being iCloud items.
        // Inspect metadata only, so requesting a cover does not hydrate the file.
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &status)
        }
        guard result == 0, status.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        let version = "\(url.standardizedFileURL.absoluteString)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return Self(url: url, version: version)
    }
}

/// Coalesces identical work, bounds memory and concurrency, and cancels a QL
/// request when its last visible consumer disappears. All bookkeeping is on MainActor.
@MainActor
private final class AttachmentThumbnailCache {
    static let shared = AttachmentThumbnailCache()
    private let cache = NSCache<NSString, CachedThumbnail>()
    private var pending: [String: PendingThumbnail] = [:]
    private var queue: [String] = []
    private var activeCount = 0

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 24 * 1_024 * 1_024
    }

    func image(for source: AttachmentThumbnailSource, pixels: Int, contentTypeIdentifier: String?) async -> CGImage? {
        let key = "\(source.version)|\(pixels)|\(contentTypeIdentifier ?? "")"
        if let cached = cache.object(forKey: key as NSString), cached.expiresAt > Date() { return cached.image }
        let consumer = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if let existing = pending[key] {
                    existing.consumers[consumer] = continuation
                } else {
                    let request = QLThumbnailGenerator.Request(fileAt: source.url, size: CGSize(width: pixels, height: pixels), scale: 1, representationTypes: .thumbnail)
                    if let contentTypeIdentifier, let type = UTType(contentTypeIdentifier) { request.contentType = type }
                    request.iconMode = false
                    let item = PendingThumbnail(request: request)
                    item.consumers[consumer] = continuation
                    pending[key] = item
                    queue.append(key)
                    startNext()
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(consumer: consumer, key: key) }
        }
    }

    private func startNext() {
        while activeCount < 4, !queue.isEmpty {
            let key = queue.removeFirst()
            guard let item = pending[key], !item.isRunning else { continue }
            item.isRunning = true
            activeCount += 1
            let generation = item.id
            QLThumbnailGenerator.shared.generateBestRepresentation(for: item.request) { [weak self] representation, _ in
                // Never replace our file artwork with a generic system icon.
                let image = representation?.type == .icon ? nil : representation?.cgImage
                guard let cache = self else { return }
                Task { @MainActor in cache.complete(key: key, generation: generation, image: image) }
            }
        }
    }

    private func complete(key: String, generation: UUID, image: CGImage?) {
        guard let item = pending[key], item.id == generation else { return }
        pending.removeValue(forKey: key)
        activeCount -= 1
        let cost = image.map { $0.bytesPerRow * $0.height } ?? 1
        // Short negative caching avoids repeated work for unsupported formats.
        cache.setObject(CachedThumbnail(image: image, expiresAt: image == nil ? Date().addingTimeInterval(30) : .distantFuture), forKey: key as NSString, cost: cost)
        for continuation in item.consumers.values { continuation.resume(returning: image) }
        startNext()
    }

    private func cancel(consumer: UUID, key: String) {
        guard let item = pending[key], let continuation = item.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(returning: nil)
        guard item.consumers.isEmpty else { return }
        pending.removeValue(forKey: key)
        if item.isRunning {
            QLThumbnailGenerator.shared.cancel(item.request)
            activeCount -= 1
        } else {
            queue.removeAll { $0 == key }
        }
        startNext()
    }

    private final class CachedThumbnail {
        let image: CGImage?
        let expiresAt: Date
        init(image: CGImage?, expiresAt: Date) { self.image = image; self.expiresAt = expiresAt }
    }

    private final class PendingThumbnail {
        let id = UUID()
        let request: QLThumbnailGenerator.Request
        var consumers: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
        var isRunning = false
        init(request: QLThumbnailGenerator.Request) { self.request = request }
    }
}
