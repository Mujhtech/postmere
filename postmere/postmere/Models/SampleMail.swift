import Foundation

extension MailMessage {
    private static let fieldnotesConversationID = UUID()
    private static let fieldnotesSentAt = Date.now

    static let samples: [MailMessage] = [
        MailMessage(
            sender: "Clara Morgan",
            senderEmail: "clara@studionorth.design",
            initials: "CM",
            subject: "Fieldnotes — identity direction",
            preview: "The first direction is attached, including the wordmark, typography, and stationery options.",
            paragraphs: [
                "Hi Alex,",
                "Attached is the first identity direction for Fieldnotes. It covers the wordmark, a revised type pairing, and a few applications so you can see how the system works beyond the logo.",
                "The palette uses the warm neutral we discussed, with a darker green for emphasis. I've also included a simpler option for the stationery in the attached overview.",
                "Could you send your initial comments by Wednesday afternoon? We can use Thursday's review to settle on a direction and identify what needs another pass.",
                "If you'd like a printed set for the review, let me know and I'll bring one.",
                "Thanks,\nClara"
            ],
            timeLabel: "10:42 AM",
            isStarred: true,
            tint: "D8C5AF",
            attachment: MailAttachment(
                name: "Fieldnotes — direction.pdf",
                detail: "PDF document · 93 KB",
                localURL: Bundle.main.url(forResource: "Fieldnotes-direction", withExtension: "pdf")
            ),
            conversationID: fieldnotesConversationID,
            sentAt: fieldnotesSentAt
        ),
        MailMessage(
            sender: "Oliver Park",
            senderEmail: "oliver@formandfield.co",
            initials: "OP",
            subject: "References for the studio",
            preview: "I've added the shelving references and material samples to our shared folder.",
            paragraphs: ["Hey Alex,", "I've added the shelving references and material samples to our shared folder. The Copenhagen bookshop is a useful example of what we could do with the front wall.", "Can you check the dimensions against the floor plan? Once we know what fits, I'll ask the joiner for an estimate.", "Oliver"],
            timeLabel: "9:18 AM",
            isUnread: true,
            tint: "B7C5B9"
        ),
        MailMessage(
            sender: "Linear",
            senderEmail: "notifications@linear.app",
            initials: "L",
            subject: "Your weekly project update",
            preview: "Fieldnotes · 8 issues completed, 3 in review, and 2 added to the next cycle.",
            paragraphs: ["Your weekly workspace update", "The Fieldnotes team completed 8 issues this week. Three issues are in review, including the typography system and the message reader layout.", "Two issues were added to the next cycle: account setup and keyboard navigation. Your next cycle starts on Monday."],
            timeLabel: "8:45 AM",
            isUnread: true,
            tint: "C5BFDA"
        ),
        MailMessage(
            sender: "Nina Patel",
            senderEmail: "nina@everydaypractice.co",
            initials: "NP",
            subject: "Lunch on Tuesday",
            preview: "Booked a table for 12:30 at Common Ground. Does that still work for you?",
            paragraphs: ["Hi Alex,", "I've booked a table for 12:30 at Common Ground on Tuesday. Does that still work for you?", "I'll bring the notes from our last meeting. We should have enough time to talk through the collection before I head back to the studio.", "See you then,\nNina"],
            timeLabel: "8:12 AM",
            isUnread: true,
            account: "Personal",
            tint: "D9B9A9"
        ),
        MailMessage(
            sender: "Are.na",
            senderEmail: "hello@are.na",
            initials: "A",
            subject: "New blocks in your channels",
            preview: "Typography has 6 new blocks. See what was added to the channels you follow.",
            paragraphs: ["This week in your channels", "Typography has 6 new blocks, Collected letters has 3, and Industrial design has 12. Oliver added a set of wayfinding references to your shared studio channel.", "Open your channels to see the latest additions."],
            timeLabel: "7:30 AM",
            account: "Personal",
            tint: "D5D0C7"
        ),
        MailMessage(
            sender: "The Modern House",
            senderEmail: "journal@themodernhouse.com",
            initials: "M",
            subject: "This week in The Modern House",
            preview: "Inside a converted workshop in east London, plus new homes on the market.",
            paragraphs: ["This week in the Journal", "We visit a converted workshop in east London and talk to its owners about adapting the building for family life.", "Also in this edition: a planting guide for small city gardens and the latest homes on the market."],
            dateLabel: "Yesterday",
            timeLabel: "4:56 PM",
            account: "Personal",
            tint: "B3BCAD"
        ),
        MailMessage(
            sender: "James Wilson",
            senderEmail: "james@fieldnotes.studio",
            initials: "JW",
            subject: "Reader layout — review notes",
            preview: "I've left comments on the line length, header spacing, and attachment row.",
            paragraphs: ["Hi Alex,", "I've left comments on the line length, header spacing, and attachment row in the design file. The main issue is the reader at smaller window sizes: the sender details wrap before the subject does.", "Could you check it at 1000 and 1200 points wide before our review? Everything else looks ready for implementation.", "Thanks,\nJames"],
            dateLabel: "Yesterday",
            timeLabel: "3:24 PM",
            isUnread: true,
            tint: "B9C4CC"
        ),
        MailMessage(
            sender: "Sophie Chen",
            senderEmail: "sophie@common-ground.design",
            initials: "SC",
            subject: "Print proofs are ready",
            preview: "The proofs arrived this morning. Please check the green before we approve the run.",
            paragraphs: ["Hello Alex,", "The proofs arrived this morning. The paper stock looks good, but the green prints a little darker than it does on screen.", "I've put a set aside for you. Could you check the colour and sign off by Friday? The printer needs approval before starting the full run.", "Thanks,\nSophie"],
            dateLabel: "Yesterday",
            timeLabel: "11:06 AM",
            isStarred: true,
            tint: "D0BFC9"
        ),
        MailMessage(
            sender: "Daniel Brooks",
            senderEmail: "daniel@smallhours.co",
            initials: "DB",
            subject: "Project brief for Thursday",
            preview: "The brief is ready for Thursday's call. Budget and timing are on the last page.",
            paragraphs: ["Hi Alex,", "The brief is ready for Thursday's call. It covers the audience, the initial deliverables, and a few examples of the existing materials.", "Budget and timing are on the last page. Let me know if there's anything else you need before the meeting.", "Thanks,\nDaniel"],
            dateLabel: "Yesterday",
            timeLabel: "9:40 AM",
            tint: "C4C1A8"
        ),
        MailMessage(
            sender: "Me",
            senderEmail: "alex@fieldnotes.studio",
            initials: "A",
            subject: "Re: Identity review",
            preview: "Thanks, Oliver. Let's take the second direction into Thursday's review.",
            paragraphs: ["Thanks, Oliver.", "Let's take the second direction into Thursday's review. Please keep the current palette and include both type options so we can compare them side by side.", "I'll send the agenda on Wednesday.", "Alex"],
            dateLabel: "Yesterday",
            timeLabel: "5:18 PM",
            mailbox: .sent,
            tint: "BBC8B9"
        ),
        MailMessage(
            sender: "Me",
            senderEmail: "nina@everydaypractice.co",
            initials: "A",
            subject: "Agenda for Tuesday",
            preview: "Can we cover the collection timeline and the first supplier estimates at lunch?",
            paragraphs: ["Hi Nina,", "Can we cover the collection timeline and the first supplier estimates at lunch? I'll bring the updated schedule."],
            timeLabel: "9:02 AM",
            mailbox: .drafts,
            tint: "BBC8B9"
        ),
        MailMessage(
            sender: "Me",
            senderEmail: "alex@fieldnotes.studio",
            initials: "AJ",
            subject: "Re: Fieldnotes — identity direction",
            preview: "Let's keep the warm neutral palette and try the darker green for emphasis.",
            paragraphs: [
                "Hi Clara,",
                "Let's keep the warm neutral palette and try the darker green for emphasis. The quieter direction feels right for the studio.",
                "Could you include the wordmark on a letterhead and a small notebook cover? That should help us compare how the type works at different sizes.",
                "Thanks,\nAlex"
            ],
            dateLabel: "Yesterday",
            timeLabel: "11:06 AM",
            mailbox: .sent,
            tint: "BBC8B9",
            toRecipients: ["clara@studionorth.design"],
            conversationID: fieldnotesConversationID,
            sentAt: fieldnotesSentAt.addingTimeInterval(-23 * 60 * 60)
        ),
        MailMessage(
            sender: "Clara Morgan",
            senderEmail: "clara@studionorth.design",
            initials: "CM",
            subject: "Fieldnotes — identity direction",
            preview: "I've narrowed the identity work to two directions. A few details to confirm before I finish the first presentation.",
            paragraphs: [
                "Hi Alex,",
                "I've narrowed the identity work to two directions. One uses a warm neutral palette with a dark green accent; the other is a more minimal black-and-white system.",
                "Before I finish the first presentation, is there a direction you'd like me to focus on? I can include a few stationery applications so we can judge it in context.",
                "Best,\nClara"
            ],
            dateLabel: "Yesterday",
            timeLabel: "9:14 AM",
            mailbox: .archive,
            tint: "D8C5AF",
            conversationID: fieldnotesConversationID,
            sentAt: fieldnotesSentAt.addingTimeInterval(-25 * 60 * 60)
        ),
        MailMessage(
            sender: "Clara Morgan",
            senderEmail: "clara@studionorth.design",
            initials: "CM",
            subject: "Notes from Friday's kickoff",
            preview: "Thanks for the meeting. I'll send the first identity direction next week.",
            paragraphs: ["Hi Alex,", "Thanks for the meeting on Friday. I've shared the notes and added the agreed deliverables to the project folder.", "I'll send the first identity direction next week, ahead of Thursday's review.", "Thanks,\nClara"],
            dateLabel: "Last week",
            timeLabel: "Fri",
            mailbox: .archive,
            tint: "D8C5AF"
        ),
        MailMessage(
            sender: "Studio Supply",
            senderEmail: "orders@studiosupply.co",
            initials: "SS",
            subject: "Your order is on its way",
            preview: "Order #1048 has shipped. Estimated delivery: two to three working days.",
            paragraphs: ["Your order is on its way.", "Order #1048 has shipped with two A5 notebooks. Estimated delivery is two to three working days.", "Thank you for your order."],
            dateLabel: "Last week",
            timeLabel: "Thu",
            mailbox: .trash,
            account: "Personal",
            tint: "C4B49D"
        )
    ]
}
