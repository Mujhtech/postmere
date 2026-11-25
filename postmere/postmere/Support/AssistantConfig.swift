import Foundation

/// Where an assistant keeps its MCP servers, and how to add Postmere there without
/// touching anything else in the file.
nonisolated struct AssistantConfigFile: Sendable, Equatable {
    enum Format: Sendable, Equatable {
        /// A JSON object holding servers under `container`, each entry built from the URL by `entry`.
        case json(container: String, urlKey: String, type: String?)
        /// Codex's TOML: an `[mcp_servers.postmere]` table.
        case toml
    }

    /// Relative to the home folder, e.g. ".cursor/mcp.json".
    let path: String
    let format: Format

    static let serverName = "postmere"

    enum MergeResult: Equatable {
        case added, updated, unchanged
    }

    enum MergeError: LocalizedError, Equatable {
        /// The file isn't plain JSON (comments, trailing commas) or isn't an object.
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path):
                "Postmere couldn’t read ~/\(path) safely, so it left it alone. Copy the configuration and add it by hand."
            }
        }
    }

    /// The configuration as a complete minimal file, for copying.
    func snippet(url: String) -> String {
        switch format {
        case .json(let container, _, _):
            let object: [String: Any] = [container: [Self.serverName: entry(url: url)]]
            return Self.encode(object)
        case .toml:
            return tomlTable(url: url)
        }
    }

    /// The file with Postmere added or updated, keeping every other setting.
    /// `existing` is nil when there's no file yet.
    func merged(_ existing: String?, url: String) throws -> (text: String, result: MergeResult) {
        switch format {
        case .json(let container, _, _): try mergeJSON(existing, url: url, container: container)
        case .toml: mergeTOML(existing, url: url)
        }
    }

    // MARK: JSON

    private func entry(url: String) -> [String: String] {
        guard case .json(_, let urlKey, let type) = format else { return [:] }
        var entry = [urlKey: url]
        if let type { entry["type"] = type }
        return entry
    }

    private func mergeJSON(_ existing: String?, url: String, container: String) throws -> (text: String, result: MergeResult) {
        var root: [String: Any] = [:]
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = existing.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MergeError.unreadable(path)
            }
            root = object
        }
        var servers: [String: Any] = [:]
        if let current = root[container] {
            guard let dictionary = current as? [String: Any] else { throw MergeError.unreadable(path) }
            servers = dictionary
        }
        let wanted = entry(url: url)
        let result: MergeResult
        if let current = servers[Self.serverName] as? [String: Any] {
            // Keep anything else the person set on the entry, such as headers or a disabled flag.
            if wanted.allSatisfy({ current[$0.key] as? String == $0.value }) {
                return (existing ?? Self.encode(root), .unchanged)
            }
            servers[Self.serverName] = current.merging(wanted) { _, new in new }
            result = .updated
        } else {
            servers[Self.serverName] = wanted
            result = .added
        }
        root[container] = servers
        return (Self.encode(root), result)
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: TOML

    private func tomlTable(url: String) -> String {
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "[mcp_servers.\(Self.serverName)]\nurl = \"\(escaped)\"\n"
    }

    private static func isPostmereHeader(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        return compact == "[mcp_servers.\(serverName)]" || compact == "[mcp_servers.\"\(serverName)\"]"
    }

    private func mergeTOML(_ existing: String?, url: String) -> (text: String, result: MergeResult) {
        let table = tomlTable(url: url)
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (table, .added) }
        var lines = existing.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: Self.isPostmereHeader) else {
            let base = existing.hasSuffix("\n") ? existing : existing + "\n"
            return (base + "\n" + table, .added)
        }
        // The table runs to the next header. Its other keys (headers, timeouts) stay;
        // only the url line is set.
        var end = start + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        let urlLine = table.components(separatedBy: "\n")[1]
        if let index = (start + 1..<end).first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("url") }) {
            if lines[index].trimmingCharacters(in: .whitespaces) == urlLine { return (existing, .unchanged) }
            lines[index] = urlLine
        } else {
            lines.insert(urlLine, at: start + 1)
        }
        return (lines.joined(separator: "\n"), .updated)
    }
}

extension AssistantConfigFile {
    static let claudeCode = AssistantConfigFile(path: ".claude.json", format: .json(container: "mcpServers", urlKey: "url", type: "http"))
    static let cursor = AssistantConfigFile(path: ".cursor/mcp.json", format: .json(container: "mcpServers", urlKey: "url", type: nil))
    static let vsCode = AssistantConfigFile(path: "Library/Application Support/Code/User/mcp.json",
                                            format: .json(container: "servers", urlKey: "url", type: "http"))
    static let windsurf = AssistantConfigFile(path: ".codeium/windsurf/mcp_config.json",
                                              format: .json(container: "mcpServers", urlKey: "serverUrl", type: nil))
    static let gemini = AssistantConfigFile(path: ".gemini/settings.json", format: .json(container: "mcpServers", urlKey: "httpUrl", type: nil))
    static let codex = AssistantConfigFile(path: ".codex/config.toml", format: .toml)
}
