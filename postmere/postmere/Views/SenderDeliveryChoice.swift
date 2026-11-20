import SwiftUI

struct SenderDeliveryChoice: View {
    let address: String
    let avatarWidth: CGFloat
    let accept: (SenderRoute) -> Void
    let block: () -> Void

    @Environment(\.postmereAccent) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Connect the decision to the same avatar and text column as the envelope above.
            Path { path in
                let x = avatarWidth / 2
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: 7))
                path.addQuadCurve(to: CGPoint(x: x + 6, y: 13), control: CGPoint(x: x, y: 13))
                path.addLine(to: CGPoint(x: avatarWidth - 1, y: 13))
            }
            .stroke(palette.accentInk.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: avatarWidth, height: 18)
            .accessibilityHidden(true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    status
                    actions
                }
                VStack(alignment: .leading, spacing: 6) {
                    status
                    actions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var status: some View {
        Text("New sender")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .fixedSize()
            .frame(minHeight: 26)
            .accessibilityLabel("New sender, \(address)")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Allow in Inbox", systemImage: "tray") { accept(.inbox) }
                Button("Route to Needs Reply", systemImage: "arrowshape.turn.up.left") { accept(.needsReply) }
                Button("Route to Archive", systemImage: "archivebox") { accept(.archive) }
            } label: {
                Label("Allow in Inbox", systemImage: "tray.and.arrow.down")
                    .foregroundStyle(palette.accentInk)
            } primaryAction: {
                accept(.inbox)
            }
            .menuStyle(.button)
            .controlSize(.regular)
            .help("Deliver mail from \(address) to your Inbox. Use the arrow to choose another destination.")
            .accessibilityHint("Applies to existing and future messages from this address in this account.")

            Button("Block", role: .destructive, action: block)
                .buttonStyle(.borderless)
                .foregroundStyle(PostmereTheme.destructiveInk)
                .help("Move mail from \(address) to Trash.")
                .accessibilityLabel("Block sender \(address)")
                .accessibilityHint("Moves existing and future messages from this address to Trash in this account.")
        }
        .fixedSize()
    }
}
