import Foundation

@main
struct AIAssistChecks {
    @MainActor static func main() {
        // The missing-attachment check reads only what the person wrote.
        let mentions = MailAttachmentReminder.mentionsAttachment
        precondition(mentions("Hi Ada,\nI've attached the signed lease."))
        precondition(mentions("Please find the deck enclosed."))
        precondition(mentions("Adjunto el contrato."))
        precondition(!mentions("Thanks for the update, see you Thursday."))
        precondition(!mentions("Our unattached garage is free."), "a word containing 'attached' is not a promise of a file")
        precondition(!mentions("Sounds good.\n\nOn Mon, 3 Nov, Ada wrote:\n> I've attached the lease"),
                     "the quoted message below is not checked")

        // Nudges: the user's own question, a few days old, with no answer since.
        let now = Date.now
        var asked = MailMessage.samples[0]
        asked.isOutgoing = true
        asked.mailbox = .sent
        asked.paragraphs = ["Hi Clara,", "Could you send the final files by Friday?", "Thanks"]
        asked.sentAt = now.addingTimeInterval(-5 * 86_400)
        precondition(MailNudges.expectsReply(asked))
        precondition(MailNudges.waiting(in: [asked], now: now).map(\.id) == [asked.id])

        var thanks = asked
        thanks.paragraphs = ["Thanks, that's perfect."]
        precondition(!MailNudges.expectsReply(thanks), "a thank-you expects nothing")
        precondition(MailNudges.waiting(in: [thanks], now: now).isEmpty)

        var recent = asked
        recent.sentAt = now.addingTimeInterval(-3_600)
        precondition(MailNudges.waiting(in: [recent], now: now).isEmpty, "too soon to nudge")

        var stale = asked
        stale.sentAt = now.addingTimeInterval(-60 * 86_400)
        precondition(MailNudges.waiting(in: [stale], now: now).isEmpty, "too old to nudge")

        var answered = MailMessage.samples[0]
        answered.isOutgoing = false
        answered.conversationID = asked.conversationID
        answered.sentAt = now.addingTimeInterval(-2 * 86_400)
        precondition(MailNudges.waiting(in: [asked, answered], now: now).isEmpty, "they replied")
        precondition(MailNudges.waiting(in: [asked], excluding: [asked.searchConversationKey], now: now).isEmpty)

        var quoted = asked
        quoted.paragraphs = ["Sounds good.", "On Mon, Clara wrote:\n> Could you send the files?"]
        precondition(!MailNudges.expectsReply(quoted), "a question in the quoted history isn't the user's")
        // The composer folds the quoted message and always joins it back exactly.
        let reply = "Sounds good.\n\n--\nMu\n\nOn Mon, 3 Nov 2026, Ada wrote:\n> Thursday?\n> Ada"
        let split = MailQuotedReply.split(reply)!
        precondition(split.head == "Sounds good.\n\n--\nMu" && split.head + split.quote == reply)
        precondition(MailQuotedReply.title(of: split.quote) == "On Mon, 3 Nov 2026, Ada wrote:")
        precondition(MailQuotedReply.join(head: "See you then.", quote: split.quote).hasSuffix(split.quote))
        precondition(MailQuotedReply.join(head: "See you then.", quote: split.quote).hasPrefix("See you then.\n"))
        precondition(MailQuotedReply.split("Just a new message.\nNo quote here.") == nil)
        let forward = "FYI\n\n---------- Forwarded message ----------\nFrom: Ada"
        precondition(MailQuotedReply.title(of: MailQuotedReply.split(forward)!.quote) == "Forwarded message")
        precondition(MailQuotedReply.split("Hi\n\nOn Mon, Ada wrote:\n") != nil)
        print("AI assist checks passed")
    }
}
