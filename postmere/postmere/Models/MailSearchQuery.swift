import Foundation

struct MailSearchToken: Identifiable, Equatable {
    enum Kind: String { case term, or, and, negation, groupStart, groupEnd }
    var id: String { "\(sourceRange.lowerBound):\(sourceRange.upperBound)" }
    let rawText: String
    let field: String?
    let value: String
    let isExcluded: Bool
    let kind: Kind
    /// Character offsets, rather than byte offsets, keep editing safe for Unicode queries.
    let sourceRange: Range<Int>
}

struct MailSearchIssue: Identifiable, Equatable {
    var id: String { "\(sourceRange.lowerBound):\(sourceRange.upperBound):\(message)" }
    let message: String
    let sourceRange: Range<Int>
}

struct MailSearchContext {
    var vipContacts: [VIPContact] = []

    func matchingVIPs(for message: MailMessage) -> [VIPContact] {
        vipContacts.filter { $0.matches(message) }
    }
}

/// A local, deterministic query language shared by search, saved views and inbox splits.
/// Spaces mean AND; OR has lower precedence. before excludes the given local day;
/// after includes its start. No query is sent to a provider by this type.
struct MailSearchQuery {
    let source: String
    let defaultField: MailSearchField
    let tokens: [MailSearchToken]
    let issues: [MailSearchIssue]
    private let expression: MailSearchExpression?

    var isValid: Bool { issues.isEmpty }

    init(source: String, defaultField: MailSearchField = .all, calendar: Calendar = .current) {
        self.source = source
        self.defaultField = defaultField
        var lexer = MailSearchLexer(source: source)
        let lexemes = lexer.scan()
        tokens = lexemes.map(\.token)
        var parser = MailSearchParser(lexemes: lexemes, calendar: calendar)
        expression = parser.parse()
        issues = lexer.issues + parser.issues
    }

    func matches(_ message: MailMessage, context: MailSearchContext = .init()) -> Bool {
        guard isValid else { return false }
        return expression?.matches(message, defaultField: defaultField, context: context) ?? true
    }

    func reasons(for message: MailMessage, context: MailSearchContext = .init()) -> [String] {
        guard matches(message, context: context) else { return [] }
        return expression?.reasons(for: message, defaultField: defaultField, context: context) ?? []
    }

    func replacingToken(id: String, with replacement: String) -> String {
        guard let token = tokens.first(where: { $0.id == id }) else { return source }
        var characters = Array(source)
        characters.replaceSubrange(token.sourceRange, with: replacement)
        return String(characters)
    }

    func removingToken(id: String) -> String {
        if isValid, let expression, tokens.contains(where: { $0.id == id && $0.kind == .term }) {
            return expression.removingToken(id)?.queryText ?? ""
        }
        return replacingToken(id: id, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let syntaxHelp = "Combine terms with spaces (AND), OR, parentheses, or a leading minus to exclude. Use from:, to:, subject:, before:YYYY-MM-DD, after:YYYY-MM-DD, has:attachment, is:unread, is:starred, filetype:pdf, or quoted phrases. Dates use your Mac’s time zone; after includes that day and before excludes it. Search covers downloaded mail only."
}

private struct MailSearchLexeme {
    let token: MailSearchToken
    let malformed: Bool
}

private struct MailSearchLexer {
    let source: String
    var issues: [MailSearchIssue] = []

    mutating func scan() -> [MailSearchLexeme] {
        let characters = Array(source)
        guard characters.count <= 16_384 else {
            issues.append(MailSearchIssue(message: "This search is too long. Use fewer than 16,384 characters.", sourceRange: 0..<characters.count))
            return []
        }
        var result: [MailSearchLexeme] = []
        var position = 0
        while position < characters.count {
            if characters[position].isWhitespace { position += 1; continue }
            let start = position
            let character = characters[position]
            if character == "(" || character == ")" || (character == "-" && position + 1 < characters.count && characters[position + 1] == "(") {
                position += 1
                let kind: MailSearchToken.Kind = character == "(" ? .groupStart : character == ")" ? .groupEnd : .negation
                result.append(MailSearchLexeme(token: MailSearchToken(rawText: String(character), field: nil, value: String(character), isExcluded: false, kind: kind, sourceRange: start..<position), malformed: false))
                continue
            }
            var decoded: [Character] = []
            var quoteOpen = false
            var usedQuotes = false
            var usedEscapes = false
            var firstColon: Int?
            var malformed = false
            while position < characters.count {
                let current = characters[position]
                if !quoteOpen && (current.isWhitespace || current == "(" || current == ")") { break }
                if current == "\\" {
                    usedEscapes = true
                    position += 1
                    guard position < characters.count else {
                        issues.append(MailSearchIssue(message: "Finish the escape after the backslash, or remove it.", sourceRange: start..<position))
                        malformed = true
                        break
                    }
                    decoded.append(characters[position])
                } else if current == "\"" {
                    quoteOpen.toggle()
                    usedQuotes = true
                } else {
                    if current == ":" && !quoteOpen && firstColon == nil { firstColon = decoded.count }
                    decoded.append(current)
                }
                position += 1
            }
            if quoteOpen {
                issues.append(MailSearchIssue(message: "Close the quoted phrase with a matching quotation mark.", sourceRange: start..<position))
                malformed = true
            }
            let raw = String(characters[start..<position])
            let value = String(decoded)
            var kind: MailSearchToken.Kind = .term
            if !usedQuotes && !usedEscapes && firstColon == nil {
                if value.uppercased() == "OR" { kind = .or }
                else if value.uppercased() == "AND" { kind = .and }
                else if value.uppercased() == "NOT" { kind = .negation }
            }
            let excluded = kind == .term && characters[start] == "-"
            let contentStart = excluded ? 1 : 0
            let field: String?
            let termValue: String
            if let colon = firstColon, colon >= contentStart {
                field = String(decoded[contentStart..<colon]).lowercased()
                termValue = String(decoded[(colon + 1)...])
            } else {
                field = nil
                termValue = String(decoded.dropFirst(contentStart))
            }
            result.append(MailSearchLexeme(token: MailSearchToken(rawText: raw, field: field, value: termValue, isExcluded: excluded, kind: kind, sourceRange: start..<position), malformed: malformed))
            if result.count > 256 {
                issues.append(MailSearchIssue(message: "Use fewer than 256 search terms and operators.", sourceRange: start..<position))
                return result
            }
        }
        return result
    }
}

private struct MailSearchParser {
    let lexemes: [MailSearchLexeme]
    let calendar: Calendar
    var issues: [MailSearchIssue] = []
    private var position = 0
    private var depth = 0

    init(lexemes: [MailSearchLexeme], calendar: Calendar) {
        self.lexemes = lexemes
        self.calendar = calendar
    }

    mutating func parse() -> MailSearchExpression? {
        guard !lexemes.isEmpty else { return nil }
        let expression = parseOr()
        while position < lexemes.count {
            issue("Remove the unmatched closing parenthesis.", at: lexemes[position].token)
            position += 1
        }
        return expression
    }

    private mutating func parseOr() -> MailSearchExpression? {
        guard let first = parseAnd() else { return nil }
        var choices = [first]
        while currentKind == .or {
            let separator = lexemes[position].token
            position += 1
            guard let next = parseAnd() else {
                issue("Add a search condition after OR.", at: separator)
                break
            }
            choices.append(next)
        }
        return choices.count == 1 ? choices[0] : .or(choices)
    }

    private mutating func parseAnd() -> MailSearchExpression? {
        var conditions: [MailSearchExpression] = []
        while position < lexemes.count && currentKind != .groupEnd && currentKind != .or {
            if currentKind == .and {
                let separator = lexemes[position].token
                position += 1
                if conditions.isEmpty { issue("AND needs a search condition before it.", at: separator) }
                if position == lexemes.count || currentKind == .groupEnd || currentKind == .or || currentKind == .and {
                    issue("Add a search condition after AND.", at: separator)
                }
                continue
            }
            if let condition = parseUnary() { conditions.append(condition) }
        }
        guard !conditions.isEmpty else { return nil }
        return conditions.count == 1 ? conditions[0] : .and(conditions)
    }

    private mutating func parseUnary() -> MailSearchExpression? {
        guard position < lexemes.count else { return nil }
        let lexeme = lexemes[position]
        position += 1
        if lexeme.token.kind == .negation {
            guard position < lexemes.count, currentKind != .or, currentKind != .and, currentKind != .groupEnd,
                  let next = parseUnary() else {
                issue("Add a search condition after the exclusion.", at: lexeme.token)
                return nil
            }
            return .not(next)
        }
        if lexeme.token.kind == .groupStart {
            depth += 1
            guard depth <= 32 else {
                issue("Use fewer than 32 nested groups.", at: lexeme.token)
                position = lexemes.count
                return nil
            }
            let nested = parseOr()
            depth -= 1
            if currentKind == .groupEnd { position += 1 }
            else { issue("Close this group with a matching parenthesis.", at: lexeme.token) }
            if nested == nil { issue("Add a search condition inside the parentheses.", at: lexeme.token) }
            return nested
        }
        guard lexeme.token.kind == .term else {
            issue("Add a search condition before \(lexeme.token.rawText).", at: lexeme.token)
            return nil
        }
        guard !lexeme.malformed else { return nil }
        let token = lexeme.token
        guard !token.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issue(token.field.map { "Add a value after \($0):." } ?? "Add text inside this search term.", at: token)
            return nil
        }
        let supported = ["from", "to", "cc", "bcc", "subject", "body", "before", "after", "has", "is", "filetype", "filename", "domain", "account", "category"]
        if let field = token.field, !supported.contains(field) {
            issue("Unknown operator “\(field):”. Use from:, to:, subject:, before:, after:, has:, is:, filetype:, filename:, domain:, account:, or category:. Quote literal text containing a colon.", at: token)
            return nil
        }
        var date: Date?
        let value = token.value.lowercased()
        if token.field == "before" || token.field == "after" {
            date = parseDate(token.value)
            if date == nil {
                issue("Use a real date in YYYY-MM-DD format, for example \(token.field ?? "after"):2026-11-17.", at: token)
                return nil
            }
        }
        if token.field == "has" && !["attachment", "attachments", "unsubscribe"].contains(value) {
            issue("Use has:attachment or has:unsubscribe.", at: token)
            return nil
        }
        if token.field == "is" && !["unread", "read", "starred", "vip", "needsreply", "outgoing", "incoming", "draft", "snoozed", "followup"].contains(value) {
            issue("Use is:unread, is:read, is:starred, is:vip, is:needsreply, is:outgoing, is:incoming, is:draft, is:snoozed, or is:followup.", at: token)
            return nil
        }
        if token.field == "filetype" && value.range(of: #"^[a-z0-9][a-z0-9.+*/-]*$|^\.[a-z0-9]+$"#, options: .regularExpression) == nil {
            issue("Use a file extension such as filetype:pdf or a MIME type such as filetype:image/*.", at: token)
            return nil
        }
        let term = MailSearchTerm(token: token, date: date)
        return token.isExcluded ? .not(.term(term)) : .term(term)
    }

    private var currentKind: MailSearchToken.Kind? {
        position < lexemes.count ? lexemes[position].token.kind : nil
    }

    private mutating func issue(_ message: String, at token: MailSearchToken) {
        issues.append(MailSearchIssue(message: message, sourceRange: token.sourceRange))
    }

    private func parseDate(_ value: String) -> Date? {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] >= 1 else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = DateComponents(timeZone: calendar.timeZone, year: parts[0], month: parts[1], day: parts[2])
        guard let date = gregorian.date(from: components),
              gregorian.component(.year, from: date) == parts[0], gregorian.component(.month, from: date) == parts[1],
              gregorian.component(.day, from: date) == parts[2] else { return nil }
        return gregorian.startOfDay(for: date)
    }
}

private indirect enum MailSearchExpression {
    case term(MailSearchTerm), and([MailSearchExpression]), or([MailSearchExpression]), not(MailSearchExpression)

    func removingToken(_ id: String) -> MailSearchExpression? {
        switch self {
        case .term(let term): return term.token.id == id ? nil : self
        case .not(let child): return child.removingToken(id).map { .not($0) }
        case .and(let children), .or(let children):
            let remaining = children.compactMap { $0.removingToken(id) }
            guard !remaining.isEmpty else { return nil }
            if remaining.count == 1 { return remaining[0] }
            if case .and = self { return .and(remaining) }
            return .or(remaining)
        }
    }

    var queryText: String {
        switch self {
        case .term(let term): return term.token.rawText
        case .and(let children): return "(" + children.map(\.queryText).joined(separator: " AND ") + ")"
        case .or(let children): return "(" + children.map(\.queryText).joined(separator: " OR ") + ")"
        case .not(.term(let term)) where term.token.isExcluded: return term.token.rawText
        case .not(let child): return "NOT (\(child.queryText))"
        }
    }

    func matches(_ message: MailMessage, defaultField: MailSearchField, context: MailSearchContext) -> Bool {
        switch self {
        case .term(let term): term.matches(message, defaultField: defaultField, context: context)
        case .and(let children): children.allSatisfy { $0.matches(message, defaultField: defaultField, context: context) }
        case .or(let children): children.contains { $0.matches(message, defaultField: defaultField, context: context) }
        case .not(let child): !child.matches(message, defaultField: defaultField, context: context)
        }
    }

    func reasons(for message: MailMessage, defaultField: MailSearchField, context: MailSearchContext) -> [String] {
        switch self {
        case .term(let term): return [term.reason(for: message, context: context)]
        case .and(let children), .or(let children):
            return children.filter { $0.matches(message, defaultField: defaultField, context: context) }
                .flatMap { $0.reasons(for: message, defaultField: defaultField, context: context) }
        case .not(.term(let term)): return ["Excluded condition absent: \(term.token.field.map { "\($0):" } ?? "")\(term.token.value)"]
        case .not: return ["Does not match the excluded group"]
        }
    }
}

private struct MailSearchTerm {
    let token: MailSearchToken
    let date: Date?

    func matches(_ message: MailMessage, defaultField: MailSearchField, context: MailSearchContext) -> Bool {
        let value = token.value
        let lower = value.lowercased()
        switch token.field {
        case "from": return contains(value, in: [message.sender, message.senderEmail])
        case "to": return contains(value, in: message.toRecipients)
        case "cc": return contains(value, in: message.ccRecipients)
        case "bcc": return contains(value, in: message.bccRecipients)
        case "subject": return message.subject.localizedStandardContains(value)
        case "body": return contains(value, in: [message.preview] + message.paragraphs)
        case "filename": return contains(value, in: message.attachments.map(\.name))
        case "domain":
            return message.senderEmail.split(separator: "@").last.map(String.init)?.caseInsensitiveCompare(value.trimmingCharacters(in: CharacterSet(charactersIn: "@"))) == .orderedSame
        case "account": return contains(value, in: [message.account, message.providerAccountEmail ?? ""])
        case "before": return date.map { message.sentAt < $0 } ?? false
        case "after": return date.map { message.sentAt >= $0 } ?? false
        case "has": return lower == "unsubscribe" ? message.unsubscribeHeaders?.listUnsubscribe.isEmpty == false : !message.attachments.isEmpty
        case "is":
            switch lower {
            case "unread": return message.isUnread
            case "read": return !message.isUnread
            case "starred": return message.isStarred
            case "vip": return !context.matchingVIPs(for: message).isEmpty
            case "needsreply": return message.workflow.needsReply
            case "outgoing": return message.isOutgoing
            case "incoming": return !message.isOutgoing
            case "draft": return message.isDraft
            case "snoozed": return message.workflow.snoozedUntil != nil
            case "followup": return message.workflow.followUpAt != nil
            default: return false
            }
        case "filetype": return message.attachments.contains { matchesFile($0, type: lower) }
        case "category":
            let category = lower.hasPrefix("category_") ? String(lower.dropFirst(9)) : lower
            return message.providerLabelIDs.contains { $0.caseInsensitiveCompare("CATEGORY_\(category)") == .orderedSame }
        default:
            switch defaultField {
            case .sender: return contains(value, in: [message.sender, message.senderEmail])
            case .subject: return message.subject.localizedStandardContains(value)
            case .all:
                return contains(value, in: [message.sender, message.senderEmail, message.subject, message.preview]
                    + message.paragraphs + message.toRecipients + message.ccRecipients + message.bccRecipients + message.attachments.map(\.name))
            }
        }
    }

    func reason(for message: MailMessage, context: MailSearchContext) -> String {
        if token.field == "is" && token.value.lowercased() == "vip" {
            return context.matchingVIPs(for: message).map { "VIP \($0.kind == .person ? "sender" : "domain"): \($0.value)" }.joined(separator: "; ")
        }
        if token.field == "category" { return "Gmail category: \(token.value)" }
        if token.field == "has" && token.value.lowercased() == "unsubscribe" { return "The message includes a List-Unsubscribe header" }
        if let field = token.field { return "Matches \(field):\(token.value)" }
        return "Contains “\(token.value)”"
    }

    private func contains(_ value: String, in strings: [String]) -> Bool {
        strings.contains { $0.localizedStandardContains(value) }
    }

    private func matchesFile(_ attachment: MailAttachment, type: String) -> Bool {
        let type = type.hasPrefix(".") ? String(type.dropFirst()) : type
        let mime = attachment.mimeType?.lowercased() ?? ""
        let extensionName = (attachment.name as NSString).pathExtension.lowercased()
        if type.contains("/") {
            if type.hasSuffix("/*") { return mime.hasPrefix(String(type.dropLast())) }
            return mime == type
        }
        if extensionName == type { return true }
        let commonMIMEs = ["pdf": "application/pdf", "txt": "text/plain", "csv": "text/csv", "ics": "text/calendar", "zip": "application/zip", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "mp3": "audio/mpeg", "mp4": "video/mp4"]
        if commonMIMEs[type] == mime { return true }
        let families: [String: Set<String>] = [
            "image": ["jpg", "jpeg", "png", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg"],
            "audio": ["mp3", "m4a", "wav", "flac", "aac", "ogg"],
            "video": ["mp4", "mov", "m4v", "avi", "webm", "mkv"],
            "text": ["txt", "csv", "md", "html", "htm", "ics"]
        ]
        return families[type].map { mime.hasPrefix("\(type)/") || $0.contains(extensionName) } ?? false
    }
}
