import SwiftUI

/// Place below the active To/Cc/Bcc field. Selecting a row inserts only its
/// validated email address; message subjects and private notes are never used.
struct RecipientSuggestionsView: View {
    let suggestions: [MailRecipientSuggestion]
    let onSelect: (MailRecipientSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button { onSelect(suggestion) } label: {
                    HStack(spacing: 10) {
                        PostmereIcon("person.crop.circle", size: 22).foregroundStyle(PostmereTheme.icon)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(suggestion.name.isEmpty ? suggestion.email : suggestion.name).font(.system(size: 12, weight: .medium))
                            if !suggestion.name.isEmpty { Text(suggestion.email).font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 12)
                    }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityLabel("Add \(suggestion.name.isEmpty ? suggestion.email : suggestion.name + ", " + suggestion.email)")
            }
        }
        .background(PostmereTheme.paper, in: .rect(cornerRadius: PostmereTheme.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: PostmereTheme.cardRadius).strokeBorder(PostmereTheme.rule) }
    }
}
