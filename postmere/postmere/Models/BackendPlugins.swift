import Foundation

/// Arbitrary JSON carried through untouched, such as a tool's arguments.
nonisolated enum PluginJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([PluginJSON]), object([String: PluginJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([PluginJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: PluginJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
}

/// Decodes an element if it can, so one unreadable item never fails a list.
nonisolated struct Lossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

// MARK: Catalog

nonisolated struct PluginInfo: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let version: Int
    let icon: String
    let tint: String
    /// Plain-language descriptions of what the plugin may read or do.
    let permissions: [String]
    var enabled: Bool
    var settings: [PluginSetting]
    let activity: [PluginActivity]
}

nonisolated struct PluginSetting: Decodable, Identifiable, Equatable, Sendable {
    enum Kind: String, Decodable, Sendable { case toggle, choice }
    struct Option: Decodable, Equatable, Sendable, Identifiable {
        let value: String
        let title: String
        var id: String { value }

        init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            value = try pair.decode(String.self)
            title = try pair.decode(String.self)
        }
    }

    let key: String
    let title: String
    let type: Kind
    let options: [Option]?
    var value: PluginJSON
    var id: String { key }
}

nonisolated struct PluginActivity: Decodable, Equatable, Sendable, Identifiable {
    let tool: String
    let succeeded: Bool
    let at: Date
    var id: String { "\(tool)-\(at.timeIntervalSinceReferenceDate)" }

    /// "remind_bill" → "Remind bill".
    var title: String {
        let words = tool.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

nonisolated struct PluginList: Decodable, Sendable {
    let plugins: [PluginInfo]
}

nonisolated struct PluginUpdate: Encodable, Sendable {
    let enabled: Bool
    let values: [String: PluginJSON]
}

// MARK: Cards

/// The card schema the app understands. Newer servers may send components
/// this build doesn't know; those are skipped, never drawn raw.
nonisolated let pluginCardSchema = 1

nonisolated struct PluginCard: Decodable, Equatable, Sendable {
    let title: String
    let subtitle: String?
    let body: [PluginComponent]
    let actions: [PluginCardAction]

    enum CodingKeys: String, CodingKey { case title, subtitle, body, actions }

    init(title: String, subtitle: String? = nil, body: [PluginComponent] = [], actions: [PluginCardAction] = []) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        body = (try container.decodeIfPresent([PluginComponent].self, forKey: .body) ?? []).filter { $0 != .unsupported }
        actions = (try container.decodeIfPresent([Lossy<PluginCardAction>].self, forKey: .actions) ?? []).compactMap(\.value)
    }
}

nonisolated enum PluginComponent: Decodable, Equatable, Sendable {
    case text(String)
    case facts([(label: String, value: String)])
    case steps(labels: [String], current: Int)
    case badge(label: String, tint: String?)
    case divider
    case unsupported

    private enum CodingKeys: String, CodingKey { case type, text, items, labels, current, label, tint }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text": self = .text(try container.decode(String.self, forKey: .text))
        case "facts":
            let pairs = try container.decode([[String]].self, forKey: .items)
            self = .facts(pairs.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil })
        case "steps":
            let labels = try container.decode([String].self, forKey: .labels)
            let current = try container.decode(Int.self, forKey: .current)
            self = labels.indices.contains(current) ? .steps(labels: labels, current: current) : .unsupported
        case "badge":
            self = .badge(label: try container.decode(String.self, forKey: .label),
                          tint: try container.decodeIfPresent(String.self, forKey: .tint))
        case "divider": self = .divider
        default: self = .unsupported
        }
    }

    static func == (lhs: PluginComponent, rhs: PluginComponent) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): a == b
        case (.facts(let a), .facts(let b)): a.map(\.label) == b.map(\.label) && a.map(\.value) == b.map(\.value)
        case (.steps(let a, let i), .steps(let b, let j)): a == b && i == j
        case (.badge(let a, let s), .badge(let b, let t)): a == b && s == t
        case (.divider, .divider), (.unsupported, .unsupported): true
        default: false
        }
    }
}

nonisolated struct PluginCardAction: Decodable, Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case open(URL)
        case copy(String)
        case tool(name: String, args: PluginJSON)
    }

    let title: String
    let icon: String
    let isPrimary: Bool
    let kind: Kind
    var id: String { title }

    private enum CodingKeys: String, CodingKey { case title, icon, style, open, copy, tool }
    private struct Tool: Decodable { let name: String; let args: PluginJSON? }

    init(title: String, icon: String, isPrimary: Bool, kind: Kind) {
        self.title = title
        self.icon = icon
        self.isPrimary = isPrimary
        self.kind = kind
    }

    /// Fails for an action this build can't run (or an unsafe link), which the
    /// card then leaves out.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "arrow.up.right"
        isPrimary = try container.decodeIfPresent(String.self, forKey: .style) == "primary"
        if let link = try container.decodeIfPresent(String.self, forKey: .open) {
            guard let url = URL(string: link), url.scheme == "https", url.host() != nil else {
                throw DecodingError.dataCorruptedError(forKey: .open, in: container, debugDescription: "Plugins may only open https links.")
            }
            kind = .open(url)
        } else if let text = try container.decodeIfPresent(String.self, forKey: .copy) {
            kind = .copy(text)
        } else {
            let tool = try container.decode(Tool.self, forKey: .tool)
            kind = .tool(name: tool.name, args: tool.args ?? .null)
        }
    }
}

nonisolated struct PluginCardResult: Decodable, Equatable, Sendable, Identifiable {
    let pluginId: String
    let pluginName: String
    let icon: String
    let tint: String
    let card: PluginCard
    var id: String { pluginId }
}

nonisolated struct PluginMessageAction: Decodable, Equatable, Sendable, Identifiable {
    let pluginId: String
    let tool: String
    let title: String
    let icon: String
    let args: PluginJSON?
    var id: String { "\(pluginId)/\(tool)" }
}

nonisolated struct MessagePlugins: Decodable, Equatable, Sendable {
    let schema: Int
    let cards: [PluginCardResult]
    let actions: [PluginMessageAction]

    static let empty = MessagePlugins(schema: pluginCardSchema, cards: [], actions: [])

    init(schema: Int, cards: [PluginCardResult], actions: [PluginMessageAction]) {
        self.schema = schema
        self.cards = cards
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey { case schema, cards, actions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        cards = (try container.decode([Lossy<PluginCardResult>].self, forKey: .cards)).compactMap(\.value)
        actions = (try container.decode([Lossy<PluginMessageAction>].self, forKey: .actions)).compactMap(\.value)
    }
}

nonisolated struct PluginToolCall: Encodable, Sendable {
    let messageId: UUID
    let args: PluginJSON
    let today: String
}

nonisolated struct PluginToolResult: Decodable, Sendable {
    enum Effect: Decodable, Equatable, Sendable {
        case open(URL)
        case remind(DateComponents)
        case unsupported

        private enum CodingKeys: String, CodingKey { case type, url, date }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "open":
                let url = URL(string: try container.decode(String.self, forKey: .url))
                self = url.flatMap { $0.scheme == "https" ? .open($0) : nil } ?? .unsupported
            case "remind":
                let parts = try container.decode(String.self, forKey: .date).split(separator: "-").compactMap { Int($0) }
                self = parts.count == 3 ? .remind(DateComponents(year: parts[0], month: parts[1], day: parts[2])) : .unsupported
            default: self = .unsupported
            }
        }
    }

    let card: PluginCard?
    let toast: String?
    let effects: [Effect]

    private enum CodingKeys: String, CodingKey { case card, toast, effects }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        card = try container.decodeIfPresent(PluginCard.self, forKey: .card)
        toast = try container.decodeIfPresent(String.self, forKey: .toast)
        effects = try container.decodeIfPresent([Effect].self, forKey: .effects) ?? []
    }
}
