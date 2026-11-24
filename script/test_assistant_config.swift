import Foundation

@main
struct AssistantConfigChecks {
    static let url = "https://mail.example.com/mcp"

    static func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    static func main() throws {
        // A new file gets just Postmere.
        var (text, result) = try AssistantConfigFile.cursor.merged(nil, url: url)
        precondition(result == .added)
        precondition((json(text)["mcpServers"] as? [String: Any])?["postmere"] as? [String: String] == ["url": url])

        // Other servers and settings stay exactly as they were.
        let existing = #"{"theme":"dark","mcpServers":{"github":{"command":"gh-mcp","args":["--x"]}}}"#
        (text, result) = try AssistantConfigFile.claudeCode.merged(existing, url: url)
        precondition(result == .added)
        let root = json(text)
        precondition(root["theme"] as? String == "dark", "Unrelated settings are kept")
        let servers = root["mcpServers"] as? [String: Any] ?? [:]
        precondition((servers["github"] as? [String: Any])?["command"] as? String == "gh-mcp", "Other servers are kept")
        precondition(servers["postmere"] as? [String: String] == ["type": "http", "url": url])

        // Running it again changes nothing; a new URL updates only the URL.
        let (again, unchanged) = try AssistantConfigFile.claudeCode.merged(text, url: url)
        precondition(unchanged == .unchanged && again == text)
        let custom = #"{"mcpServers":{"postmere":{"type":"http","url":"https://old.example.com/mcp","headers":{"X":"1"}}}}"#
        (text, result) = try AssistantConfigFile.claudeCode.merged(custom, url: url)
        let updated = (json(text)["mcpServers"] as? [String: Any])?["postmere"] as? [String: Any] ?? [:]
        precondition(result == .updated && updated["url"] as? String == url, "A changed URL is updated")
        precondition((updated["headers"] as? [String: String]) == ["X": "1"], "Extra keys on the entry are kept")

        // Each assistant's own shape.
        let vs = try AssistantConfigFile.vsCode.merged(nil, url: url).text
        precondition(((json(vs)["servers"] as? [String: Any])?["postmere"] as? [String: String]) == ["type": "http", "url": url])
        let wind = try AssistantConfigFile.windsurf.merged(nil, url: url).text
        precondition(((json(wind)["mcpServers"] as? [String: Any])?["postmere"] as? [String: String]) == ["serverUrl": url])
        let gem = try AssistantConfigFile.gemini.merged(nil, url: url).text
        precondition(((json(gem)["mcpServers"] as? [String: Any])?["postmere"] as? [String: String]) == ["httpUrl": url])

        // Files that aren't plain JSON objects are never rewritten.
        for bad in ["{ // comment\n \"mcpServers\": {} }", "[1,2]", "{\"mcpServers\": []}"] {
            do {
                _ = try AssistantConfigFile.cursor.merged(bad, url: url)
                preconditionFailure("Rewrote an unreadable file: \(bad)")
            } catch AssistantConfigFile.MergeError.unreadable {}
        }
        let blank = try AssistantConfigFile.cursor.merged("  \n", url: url).result
        precondition(blank == .added, "An empty file is treated as new")

        // Codex TOML: append, keep the rest, update in place.
        let toml = "model = \"o4\"\n\n[mcp_servers.github]\ncommand = \"gh\"\n"
        (text, result) = try AssistantConfigFile.codex.merged(toml, url: url)
        precondition(result == .added && text.hasPrefix(toml) && text.contains("[mcp_servers.postmere]\nurl = \"\(url)\"\n"))
        let rerun = try AssistantConfigFile.codex.merged(text, url: url).result
        precondition(rerun == .unchanged)
        let oldTable = "[mcp_servers.postmere]\nurl = \"https://old.example.com/mcp\"\nstartup_timeout_sec = 20\n\n[profiles.x]\nmodel = \"y\"\n"
        (text, result) = try AssistantConfigFile.codex.merged(oldTable, url: url)
        precondition(result == .updated && text.contains("url = \"\(url)\"") && !text.contains("old.example.com"))
        precondition(text.contains("startup_timeout_sec = 20") && text.contains("[profiles.x]"), "Other keys and tables stay")
        let quoted = try AssistantConfigFile.codex.merged("[mcp_servers.\"postmere\"]\nurl = \"\(url)\"\n", url: url).result
        precondition(quoted == .unchanged,
                     "A quoted table name is the same table")
        precondition(AssistantConfigFile.codex.snippet(url: "https://a.example/\"x").contains(#"url = "https://a.example/\"x""#), "Quotes are escaped")

        print("Assistant config checks passed")
    }
}
