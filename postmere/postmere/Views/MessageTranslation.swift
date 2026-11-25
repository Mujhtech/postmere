import NaturalLanguage
import SwiftUI
import Translation

/// Offers to translate a message written in another language, on this Mac
/// with Apple's Translation framework: nothing is sent to a server. The
/// translation replaces the body until "Show original".
struct TranslatableMessageBody<Original: View>: View {
    let message: MailMessage
    var fontSize: Double = 14
    var readingFont = MailReadingFont.original
    @ViewBuilder let original: () -> Original

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detected: Locale.Language?
    @State private var configuration: TranslationSession.Configuration?
    @State private var translated: [String]?
    @State private var showsOriginal = false
    @State private var isTranslating = false
    @State private var error: String?
    @State private var dismissed = false

    private var target: Locale.Language { Locale.current.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detected, !dismissed {
                banner(detected)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let translated, !showsOriginal {
                RichTextMessageBody(rtf: nil, paragraphs: translated, fontSize: fontSize, readingFont: readingFont)
                    .transition(.opacity)
            } else {
                original()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: translated == nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsOriginal)
        .task(id: message.id) {
            translated = nil
            showsOriginal = false
            dismissed = false
            error = nil
            detected = await Self.foreignLanguage(in: Self.sample(message), comparedTo: target)
        }
        .translationTask(configuration) { session in
            await translate(with: session)
        }
    }

    private func banner(_ language: Locale.Language) -> some View {
        let name = Locale.current.localizedString(forLanguageCode: language.languageCode?.identifier ?? "") ?? "another language"
        return HStack(spacing: 8) {
            PostmereIcon("text.badge.plus", size: 12).foregroundStyle(palette.accentInk)
            if let error {
                Text(error).foregroundStyle(.secondary)
            } else if translated != nil {
                Text(showsOriginal ? "Written in \(name)" : "Translated from \(name)").foregroundStyle(.secondary)
            } else {
                Text("Written in \(name)").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isTranslating {
                ProgressView().controlSize(.mini)
            } else if translated != nil {
                Button(showsOriginal ? "Show Translation" : "Show Original") { showsOriginal.toggle() }
                    .buttonStyle(.accentLink)
            } else {
                Button("Translate") { start(from: language) }
                    .buttonStyle(.accentLink)
            }
            Button { withAnimation { dismissed = true } } label: {
                PostmereIcon("xmark", size: 9).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Hide")
            .accessibilityLabel("Hide translation offer")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(palette.accentInk.opacity(0.07), in: .capsule)
    }

    private func start(from language: Locale.Language) {
        error = nil
        isTranslating = true
        if configuration == nil {
            configuration = TranslationSession.Configuration(source: language, target: target)
        } else {
            configuration?.invalidate()
        }
    }

    private func translate(with session: TranslationSession) async {
        defer { isTranslating = false }
        let paragraphs = Self.paragraphs(message)
        guard !paragraphs.isEmpty else { return }
        do {
            try await session.prepareTranslation()
            let requests = paragraphs.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            var result = paragraphs
            for response in try await session.translations(from: requests) {
                if let index = response.clientIdentifier.flatMap(Int.init), result.indices.contains(index) {
                    result[index] = response.targetText
                }
            }
            translated = result
            showsOriginal = false
        } catch {
            self.error = "Translation isn’t available for this language right now."
        }
    }

    // MARK: Text

    /// The message's readable paragraphs; quoted history is translated too.
    static func paragraphs(_ message: MailMessage) -> [String] {
        let text = message.paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return text.isEmpty ? [message.displayPreview].filter { !$0.isEmpty } : Array(text.prefix(400))
    }

    static func sample(_ message: MailMessage) -> String {
        String((message.displaySubject + "\n" + paragraphs(message).joined(separator: "\n")).prefix(1_500))
    }

    /// The message's language when it is clearly not the reader's own.
    @concurrent static func foreignLanguage(in text: String, comparedTo target: Locale.Language) async -> Locale.Language? {
        let prose = readableWords(text)
        guard prose.count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose.joined(separator: " "))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let (language, confidence) = hypotheses.max(by: { $0.value < $1.value }),
              confidence >= 0.8, language != .undetermined else { return nil }
        let detected = Locale.Language(identifier: language.rawValue)
        guard detected.languageCode != target.languageCode else { return nil }
        // Close to the reader's own language is not foreign enough to offer a translation.
        if let own = hypotheses.first(where: { Locale.Language(identifier: $0.key.rawValue).languageCode == target.languageCode }),
           own.value >= 0.1 { return nil }
        return detected
    }

    /// Words a person would read. Newsletters fill their text with tracking links,
    /// encoded IDs and addresses, which a language model reads as some other language.
    nonisolated static func readableWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw -> String? in
            let token = String(raw)
            let lower = token.lowercased()
            if lower.contains("://") || lower.hasPrefix("www.") || token.contains("@") { return nil }
            let word = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard word.count >= 2, word.count <= 24 else { return nil }
            // Encoded IDs mix letters with digits or switch case mid-word.
            guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }) else { return nil }
            let inner = word.dropFirst()
            if inner.contains(where: \.isUppercase) && inner.contains(where: \.isLowercase) { return nil }
            return word
        }
    }
}
