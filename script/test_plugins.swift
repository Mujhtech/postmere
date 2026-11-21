import Foundation

@main
struct PluginTests {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try BackendHTTPClient.decoder().decode(type, from: Data(json.utf8))
    }

    static func main() throws {
        // The shapes below are what postmere-plugins serialises.
        let list = try decode(PluginList.self, #"""
        {"plugins":[{"id":"postmere.bills","name":"Bills & Invoices","summary":"Amount, due date and a reminder on bills.",
          "version":1,"icon":"doc.text","tint":"green","permissions":["Reads the message you're viewing."],"enabled":true,
          "settings":[{"key":"remind_days_before","title":"Remind me","type":"choice",
                       "options":[["1","1 day before"],["3","3 days before"],["7","A week before"]],"default":"3","value":"7"},
                      {"key":"show_delivered","title":"Show delivered","type":"toggle","default":true,"value":false}],
          "activity":[{"tool":"remind_bill","succeeded":true,"at":"2026-11-21T10:00:00.123456Z"}]}]}
        """#)
        let bills = list.plugins[0]
        check(bills.enabled && bills.settings.count == 2, "Plugin catalog didn't decode")
        check(bills.settings[0].key == "remind_days_before", "Setting keys must stay as the server spells them")
        check(bills.settings[0].value == .string("7") && bills.settings[0].options?.last?.title == "A week before", "Choice setting didn't decode")
        check(bills.settings[1].type == .toggle && bills.settings[1].value.bool == false, "Toggle setting didn't decode")
        check(bills.activity.first?.title == "Remind bill", "Activity title isn't readable")

        let found = try decode(MessagePlugins.self, #"""
        {"schema":1,"cards":[{"plugin_id":"postmere.packages","plugin_name":"Package Tracking","icon":"shippingbox","tint":"orange",
          "card":{"title":"Out for delivery","subtitle":"UPS · Arriving today",
            "body":[{"type":"steps","labels":["Ordered","Shipped","Out for delivery","Delivered"],"current":2},
                    {"type":"facts","items":[["Tracking","1Z999AA10123456784"]]},
                    {"type":"chart","points":[1,2]},
                    {"type":"badge","label":"Paid","tint":"green"}],
            "actions":[{"title":"Track on UPS","icon":"arrow.up.right","style":"primary","open":"https://www.ups.com/track?tracknum=1Z"},
                       {"title":"Insecure","icon":"x","style":"primary","open":"http://example.test"},
                       {"title":"Copy Number","icon":"doc.on.doc","style":"secondary","copy":"1Z999AA10123456784"},
                       {"title":"Remind Me on Dec 2","icon":"bell","style":"secondary","tool":{"name":"remind_bill","args":{"date":"2026-12-02"}}},
                       {"title":"Future","icon":"x","style":"secondary","teleport":true}]}},
          {"plugin_id":"broken"}],
         "actions":[{"plugin_id":"postmere.bills","tool":"remind_bill","title":"Remind Me About This Bill","icon":"bell","args":{"date":"2026-11-28"}},
                    {"plugin_id":"postmere.bills","tool":"pay_bill","title":"Pay Bill","icon":"creditcard"}]}
        """#)
        check(found.cards.count == 1, "An unreadable card should be skipped, not fail the message")
        let card = found.cards[0].card
        check(card.body.count == 3, "Unknown components should be skipped")
        check(card.body.first == .steps(labels: ["Ordered", "Shipped", "Out for delivery", "Delivered"], current: 2), "Steps didn't decode")
        check(card.actions.map(\.title) == ["Track on UPS", "Copy Number", "Remind Me on Dec 2"], "Insecure and unknown actions must be dropped")
        check(card.actions[0].isPrimary && !card.actions[1].isPrimary, "Action style didn't decode")
        check(card.actions[2].kind == .tool(name: "remind_bill", args: .object(["date": .string("2026-12-02")])), "Tool action didn't decode")
        check(found.actions.map(\.id) == ["postmere.bills/remind_bill", "postmere.bills/pay_bill"], "Message actions didn't decode")

        let result = try decode(PluginToolResult.self, #"""
        {"toast":"Reminder set for Wed, Dec 2","effects":[{"type":"remind","date":"2026-12-02"},{"type":"open","url":"https://pay.test/1"},
         {"type":"open","url":"file:///etc/passwd"},{"type":"future"}]}
        """#)
        check(result.toast == "Reminder set for Wed, Dec 2", "Toast didn't decode")
        check(result.effects == [.remind(DateComponents(year: 2026, month: 12, day: 2)), .open(URL(string: "https://pay.test/1")!), .unsupported, .unsupported],
              "Effects must keep https links and reminders only")

        let encoder = BackendHTTPClient.encoder()
        encoder.outputFormatting = .sortedKeys
        let call = String(decoding: try encoder.encode(PluginToolCall(messageId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                                                       args: found.actions[0].args ?? .null, today: "2026-11-21")), as: UTF8.self)
        check(call == #"{"args":{"date":"2026-11-28"},"message_id":"00000000-0000-0000-0000-000000000001","today":"2026-11-21"}"#, "Tool call encoded as \(call)")
        let update = String(decoding: try encoder.encode(PluginUpdate(enabled: true, values: ["remind_days_before": .string("1")])), as: UTF8.self)
        check(update == #"{"enabled":true,"values":{"remind_days_before":"1"}}"#, "Settings update encoded as \(update)")

        if failures > 0 { print("\(failures) plugin checks failed"); exit(1) }
        print("Plugin model checks passed")
    }
}
