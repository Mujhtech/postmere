import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Uses a contextual NSMenu so AppKit supplies the real nearby-device commands.
struct ComposeAttachmentMenuButton: NSViewRepresentable {
    let onChooseFiles: () -> Void
    /// Consume or copy these URLs synchronously; captured temporary files are then removed.
    let onCapture: ([URL]) throws -> Void
    let onError: (Error) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = ContinuityAttachmentButton()
        update(button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        guard let button = nsView as? ContinuityAttachmentButton else { return }
        update(button)
    }

    static func dismantleNSView(_ nsView: NSButton, coordinator: ()) {
        guard let button = nsView as? ContinuityAttachmentButton else { return }
        button.onChooseFiles = nil
        button.capture.onReceive = nil
        button.capture.onError = nil
    }

    private func update(_ button: ContinuityAttachmentButton) {
        button.onChooseFiles = onChooseFiles
        button.capture.onReceive = onCapture
        button.capture.onError = onError
    }
}

/// The Services requestor is also used by the body editor's native context menu.
final class ComposeContinuityCapture: NSObject, NSServicesMenuRequestor {
    var onReceive: (([URL]) throws -> Void)?
    var onError: ((Error) -> Void)?

    func accepts(_ type: NSPasteboard.PasteboardType?) -> Bool {
        guard onReceive != nil, let type else { return false }
        return type == .pdf || NSImage.imageTypes.contains(type.rawValue)
            || UTType(type.rawValue)?.conforms(to: .image) == true
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let onReceive else { return false }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Postmere-Capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let files = try Self.captureFiles(from: pasteboard, directory: directory)
            guard !files.isEmpty else { return false }
            try onReceive(files)
            return true
        } catch {
            onError?(error)
            return false
        }
    }

    static func captureFiles(from pasteboard: NSPasteboard, directory: URL) throws -> [URL] {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !objects.isEmpty {
            return objects
        }
        var files: [URL] = []
        for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
            // Keep scans as PDF, including all of their pages, before considering image representations.
            let preferred: [NSPasteboard.PasteboardType] = [.pdf, .png, .tiff]
            let supported = preferred + item.types.filter {
                !preferred.contains($0) && UTType($0.rawValue)?.conforms(to: .image) == true
            }
            guard let type = supported.first(where: { item.types.contains($0) && item.data(forType: $0) != nil }),
                  let data = item.data(forType: type), !data.isEmpty else { continue }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let extensionName = type == .pdf ? "pdf" : UTType(type.rawValue)?.preferredFilenameExtension ?? "tiff"
            let name = type == .pdf ? "Scanned Document" : "Captured Image"
            let suffix = index == 0 ? "" : " \(index + 1)"
            let url = directory.appendingPathComponent("\(name)\(suffix).\(extensionName)")
            try data.write(to: url, options: .atomic)
            files.append(url)
        }
        return files
    }
}

private final class ContinuityAttachmentButton: NSButton {
    let capture = ComposeContinuityCapture()
    var onChooseFiles: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        image = PostmereSymbols.image("paperclip", size: 16)
        contentTintColor = .secondaryLabelColor
        imagePosition = .imageOnly
        bezelStyle = .texturedRounded
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(showAttachmentMenu(_:))
        toolTip = "Attach files or insert from iPhone"
        setAccessibilityLabel("Attach files or insert from iPhone")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, capture.accepts(returnType) { return capture }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    override func mouseDown(with event: NSEvent) { presentMenu(with: event) }

    override func menu(for event: NSEvent) -> NSMenu? { attachmentMenu() }

    @objc private func showAttachmentMenu(_ sender: Any?) {
        guard let window,
              let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
              ) else { return }
        presentMenu(with: event)
    }

    private func presentMenu(with event: NSEvent) {
        let previousResponder = window?.firstResponder
        window?.makeFirstResponder(self)
        highlight(true)
        // AppKit injects Take Photo, Scan Documents, and Sketch for compatible available devices.
        NSMenu.popUpContextMenu(attachmentMenu(), with: event, for: self)
        highlight(false)
        if window?.firstResponder === self, let previousResponder { window?.makeFirstResponder(previousResponder) }
    }

    private func attachmentMenu() -> NSMenu {
        let menu = NSMenu(title: "Attachments")
        let files = NSMenuItem(title: "Attach Files…", action: #selector(chooseFiles(_:)), keyEquivalent: "")
        files.target = self
        menu.addItem(files)
        menu.allowsContextMenuPlugIns = true
        return menu
    }

    @objc private func chooseFiles(_ sender: Any?) { onChooseFiles?() }
}
