import SwiftUI
import Contacts

struct MailParticipantAvatar: View {
    let address: String
    var name = ""
    var size: CGFloat
    @State private var showsProfile = false

    var body: some View {
        Button { showsProfile = true } label: {
            ParticipantPhoto(address: address, name: name, size: size)
        }
        .buttonStyle(.plain)
        .help("View profile for \(displayName)")
        .accessibilityLabel("View profile for \(displayName)")
        .popover(isPresented: $showsProfile) {
            VStack(spacing: 10) {
                ParticipantPhoto(address: address, name: name, size: 148, enlarged: true)
                if !name.isEmpty && name != address { Text(name).font(.headline) }
                Text(address).font(.callout).textSelection(.enabled)
                    .multilineTextAlignment(.center)
                if !MailContactPhotos.shared.canRead { ContactPhotoAccess() }
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
    @State private var loadedKey: PhotoKey?
    @State private var image: CGImage?
    @State private var website: String?

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
        let photos = MailContactPhotos.shared
        let gravatar = MailRemoteParticipantImages.gravatar
        let icons = MailRemoteParticipantImages.websiteIcons
        let key = PhotoKey(email: address, revision: photos.revision, gravatarRevision: gravatar.revision,
                           websiteRevision: icons.revision, enlarged: enlarged)
        VStack(spacing: 7) {
            Group {
                if loadedKey == key, let image {
                    if website != nil {
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
            .clipShape(.rect(cornerRadius: enlarged && image != nil ? 8 : size / 2))
            .accessibilityHidden(true)
            if enlarged {
                if loadedKey != key {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading profile photo")
                } else if let website {
                    Text("Website icon for \(website)").font(.caption).foregroundStyle(.secondary)
                } else if image == nil {
                    Text("No profile photo available.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: key) {
            let email = MailSenderDomain.email(in: address) ?? ""
            var result = await photos.photo(email: email, enlarged: enlarged)
            var domain: String?
            if result == nil, gravatar.enabled, !Task.isCancelled {
                result = await gravatar.photo(email: email)?.image
            }
            if result == nil, icons.enabled, !Task.isCancelled {
                let icon = await icons.photo(email: email)
                result = icon?.image
                domain = icon?.website
            }
            guard !Task.isCancelled else { return }
            image = result
            website = domain
            loadedKey = key
        }
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
