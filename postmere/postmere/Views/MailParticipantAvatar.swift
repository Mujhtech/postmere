import SwiftUI
import Contacts

struct MailParticipantAvatar: View {
    let address: String
    var name = ""
    var size: CGFloat
    var messageID: UUID?
    var verifiedMark: MailVerifiedSenderMark?
    @State private var showsProfile = false

    var body: some View {
        if let verifiedMark, ParticipantPhoto.logo(for: verifiedMark) != nil {
            TimelineView(.explicit([Date.distantPast, verifiedMark.expiresAt])) { context in
                avatar(mark: context.date < verifiedMark.expiresAt ? verifiedMark : nil)
            }
        } else {
            avatar(mark: nil)
        }
    }

    private func avatar(mark verifiedMark: MailVerifiedSenderMark?) -> some View {
        Button { showsProfile = true } label: {
            ParticipantPhoto(address: address, name: name, size: size, verifiedMark: verifiedMark)
        }
        .buttonStyle(.plain)
        .help(verifiedMark?.explanation ?? "View profile for \(displayName)")
        .onChange(of: messageID) { showsProfile = false }
        .accessibilityLabel(verifiedMark.map { "View profile for \(displayName). \($0.explanation)" } ?? "View profile for \(displayName)")
        .popover(isPresented: $showsProfile) {
            VStack(spacing: 10) {
                ParticipantPhoto(address: address, name: name, size: 148, enlarged: true, verifiedMark: verifiedMark)
                if !name.isEmpty && name != address { Text(name).font(.headline) }
                Text(address).font(.callout).textSelection(.enabled)
                    .multilineTextAlignment(.center)
                if verifiedMark == nil && !MailContactPhotos.shared.canRead { ContactPhotoAccess() }
            }
            .padding(18)
            .frame(width: 252)
        }
    }

    private var displayName: String { name.isEmpty ? address : name }
}

struct ParticipantPhoto: View {
    let address: String
    let name: String
    let size: CGFloat
    var enlarged = false
    var verifiedMark: MailVerifiedSenderMark?
    @State private var loadedKey: PhotoKey?
    @State private var photo: MailRemoteParticipantImages.Photo?

    private struct PhotoKey: Equatable {
        let email: String
        let revision: Int
        let gravatarRevision: Int
        let websiteRevision: Int
        let enlarged: Bool
    }

    private var initials: String {
        let source = name.isEmpty || name.contains("@") ? String(address.prefix(while: { $0 != "@" })) : name
        let words = source.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        if let verifiedMark, let logo = Self.logo(for: verifiedMark) {
            // Reevaluate at the end of the evidence lifetime, even if the open message doesn't change.
            TimelineView(.explicit([Date.distantPast, verifiedMark.expiresAt])) { context in
                if context.date < verifiedMark.expiresAt {
                    VStack(spacing: 7) {
                        Image(nsImage: logo).resizable().scaledToFit()
                            .padding(size * 0.05)
                            .frame(width: size, height: size)
                            .background(.white, in: .circle)
                            .clipShape(.circle)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "checkmark.seal.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .blue)
                                    .font(.system(size: enlarged ? 22 : 12, weight: .bold))
                                    .accessibilityHidden(true)
                            }
                        if enlarged {
                            Text(verifiedMark.explanation).font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .help(verifiedMark.explanation)
                } else {
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private static let logos: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    fileprivate static func logo(for mark: MailVerifiedSenderMark) -> NSImage? {
        let key = mark.logoPNG as NSData
        if let cached = logos.object(forKey: key) { return cached }
        guard mark.logoPNG.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), let logo = NSImage(data: mark.logoPNG) else { return nil }
        logos.setObject(logo, forKey: key)
        return logo
    }

    private var fallback: some View {
        let photos = MailContactPhotos.shared
        let gravatar = MailRemoteParticipantImages.gravatar
        let icons = MailRemoteParticipantImages.websiteIcons
        let key = PhotoKey(email: address, revision: photos.revision, gravatarRevision: gravatar.revision,
                           websiteRevision: icons.revision, enlarged: enlarged)
        // Recycled list rows can draw a previously fetched photo on their first frame.
        let visiblePhoto = loadedKey == key ? photo : cachedPhoto()
        return VStack(spacing: 7) {
            Group {
                if let visiblePhoto {
                    let image = visiblePhoto.image
                    if visiblePhoto.website != nil {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .padding(size * 0.13)
                            .frame(width: size, height: size)
                            .background(.white)
                    } else {
                        Image(decorative: image, scale: 1).resizable()
                            .aspectRatio(contentMode: enlarged ? .fit : .fill)
                    }
                } else {
                    Text(initials).font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(PostmereTheme.avatarInk)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(PostmereTheme.avatarFill)
                }
            }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: enlarged && visiblePhoto != nil ? 8 : size / 2))
            .accessibilityHidden(true)
            if enlarged {
                if let website = visiblePhoto?.website {
                    Text("Website icon for \(website)").font(.caption).foregroundStyle(.secondary)
                } else if visiblePhoto == nil && loadedKey != key {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading profile photo")
                } else if visiblePhoto == nil {
                    Text("No profile photo available.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: key) {
            let email = MailSenderDomain.email(in: address) ?? ""
            var result = await photos.photo(email: email, enlarged: enlarged).map {
                MailRemoteParticipantImages.Photo(image: $0, website: nil)
            }
            if result == nil, gravatar.enabled, !Task.isCancelled {
                result = await gravatar.photo(email: email)
            }
            if result == nil, icons.enabled, !Task.isCancelled {
                result = await icons.photo(email: email)
            }
            guard !Task.isCancelled else { return }
            photo = result
            loadedKey = key
        }
    }

    private func cachedPhoto() -> MailRemoteParticipantImages.Photo? {
        guard let email = MailSenderDomain.email(in: address) else { return nil }
        if let image = MailContactPhotos.shared.cachedPhoto(email: email, enlarged: enlarged) {
            return .init(image: image, website: nil)
        }
        return MailRemoteParticipantImages.gravatar.cachedPhoto(email: email)
            ?? MailRemoteParticipantImages.websiteIcons.cachedPhoto(email: email)
    }
}

struct ContactPhotoAccess: View {
    private let photos = MailContactPhotos.shared
    @Environment(\.openURL) private var openURL
    @State private var requesting = false

    var body: some View {
        switch photos.authorization {
        case .notDetermined:
            Button("Use Photos from Contacts…") {
                requesting = true
                Task {
                    await photos.requestAccess()
                    requesting = false
                }
            }
            .disabled(requesting)
        case .denied, .authorized:
            Button(photos.authorization == .denied ? "Allow in System Settings…" : "Manage Access…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                    openURL(url)
                }
            }
        case .restricted:
            Text("Contacts access is restricted.").foregroundStyle(.secondary)
        @unknown default:
            Text("Contacts access unavailable.").foregroundStyle(.secondary)
        }
    }
}
