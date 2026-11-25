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
            .mailPanelSurface()
        }
    }

    private var displayName: String { name.isEmpty ? address : name }
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
