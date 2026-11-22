import Foundation

@main
struct LinkChecks {
    static func main() {
        func links(_ text: String) -> [String] {
            MailLinkDetector.attributed(text).runs.compactMap { $0.link?.absoluteString }
        }
        precondition(links("Book here: https://talent.arca.ph/book/Jjkk9vXTspD4") == ["https://talent.arca.ph/book/Jjkk9vXTspD4"])
        precondition(links("Guide (https://drive.google.com/file/d/1W/view?usp=sharing).") == ["https://drive.google.com/file/d/1W/view?usp=sharing"],
                     "Trailing punctuation stays outside the link")
        precondition(links("Write to hr@arca.ph.") == ["mailto:hr@arca.ph"])
        precondition(links("javascript:alert(1) file:///etc/passwd ftp://old.example.org").isEmpty, "Only https, http and mailto become links")
        precondition(links("Nothing to see here").isEmpty)
        let rich = NSMutableAttributedString(string: "Already linked https://a.example.org and plain https://b.example.org")
        rich.addAttribute(.link, value: URL(string: "https://elsewhere.example.org")!, range: NSRange(location: 15, length: 21))
        MailLinkDetector.link(rich)
        precondition((rich.attribute(.link, at: 15, effectiveRange: nil) as? URL)?.host == "elsewhere.example.org", "Sender links are kept")
        precondition((rich.attribute(.link, at: 48, effectiveRange: nil) as? URL)?.host == "b.example.org", "Plain URLs in formatted mail get linked")
        print("Link detection checks passed")
    }
}
