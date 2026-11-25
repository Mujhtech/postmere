import SwiftUI

struct NeedsReplyAnnotationView: View {
    let annotation: NeedsReplyAnnotation
    let inThread: Bool
    let showSource: () -> Void
    let markDone: () -> Void

    @Environment(\.postmereAccent) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                Text("Needs Reply")
                    .font(.headline)
                    .foregroundStyle(palette.accentInk)
                    .accessibilityAddTraits(.isHeader)
                Button(action: markDone) {
                    Label("Mark Done", systemImage: "checkmark")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Remove this conversation from Needs Reply")
            }
            switch annotation.origin {
            case .marked:
                Text("Marked for reply in Postmere")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .detected(let request, let sender):
                Text(verbatim: "“\(request)”")
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                if inThread {
                    Button(action: showSource) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Detected in mail from \(sender)")
                            Image(systemName: "arrow.down").imageScale(.small)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .foregroundStyle(palette.accentInk)
                    .help("Show the message containing this request")
                    .accessibilityHint("Opens the original message in this conversation.")
                } else {
                    Text("Detected in mail from \(sender)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 11)
        .overlay(alignment: .leading) {
            Capsule().fill(palette.accentInk.opacity(0.72)).frame(width: 2)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: 600, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
