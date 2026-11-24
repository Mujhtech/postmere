import Foundation
import Contacts
import ImageIO
import Observation

@MainActor
@Observable
final class MailContactPhotos {
    static let shared = MailContactPhotos()

    private(set) var authorization = CNContactStore.authorizationStatus(for: .contacts)
    private(set) var revision = 0
    private let lookup = ContactPhotoLookup()
    private let cache = NSCache<NSString, CachedPhoto>()
    private var observers: [NSObjectProtocol] = []

    var canRead: Bool { authorization == .authorized }

    private init() {
        cache.countLimit = 256
        for notification in [Notification.Name.CNContactStoreDidChange, MailPlatform.didBecomeActive] {
            let observer = NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] note in
                let contactsChanged = note.name == .CNContactStoreDidChange
                MainActor.assumeIsolated { self?.refresh(contactsChanged: contactsChanged) }
            }
            observers.append(observer)
        }
    }

    func requestAccess() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        refresh(contactsChanged: true)
    }

    private func refresh(contactsChanged: Bool) {
        let current = CNContactStore.authorizationStatus(for: .contacts)
        guard contactsChanged || authorization != current else { return }
        authorization = current
        cache.removeAllObjects()
        revision += 1
    }

    func cachedPhoto(email: String, enlarged: Bool) -> CGImage? {
        guard canRead, !email.isEmpty else { return nil }
        return cache.object(forKey: "\(enlarged)-\(email)" as NSString)?.image
    }

    func photo(email: String, enlarged: Bool) async -> CGImage? {
        guard canRead, !email.isEmpty else { return nil }
        let key = "\(enlarged)-\(email)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let version = revision
        let image = await lookup.photo(email: email, enlarged: enlarged)
        guard version == revision, canRead, !Task.isCancelled else { return nil }
        cache.setObject(CachedPhoto(image), forKey: key)
        return image
    }

    private final class CachedPhoto {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }
}

private actor ContactPhotoLookup {
    private let store = CNContactStore()

    func photo(email: String, enlarged: Bool) -> CGImage? {
        let keys: [CNKeyDescriptor] = enlarged
            ? [CNContactImageDataKey as CNKeyDescriptor, CNContactThumbnailImageDataKey as CNKeyDescriptor]
            : [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else { return nil }
        for contact in contacts {
            let data = enlarged ? (contact.imageData ?? contact.thumbnailImageData) : contact.thumbnailImageData
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { continue }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: enlarged ? 640 : 96
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        return nil
    }
}
