//! Rule-based detectors shared by plugins. They run on the server before any
//! plugin is consulted, cost microseconds, and never send mail anywhere.
use chrono::NaiveDate;
use postmere_providers::Message;

/// Message text normalised once per request: subject plus readable body.
pub struct MailText {
    pub subject: String,
    pub body: String,
    /// Lowercased `subject + body` for keyword checks.
    pub lower: String,
    /// `href` targets from the HTML part, with the visible text around them.
    pub links: Vec<(String, String)>,
}

const MAX_BODY: usize = 60_000;

impl MailText {
    pub fn new(message: &Message) -> Self {
        let mut body = message.text_body.trim().to_owned();
        if body.is_empty()
            && let Some(html) = &message.html_body
        {
            body = strip_html(html);
        }
        truncate(&mut body, MAX_BODY);
        let links = message
            .html_body
            .as_deref()
            .map(html_links)
            .unwrap_or_default();
        let lower = format!("{}\n{}", message.subject, body).to_lowercase();
        Self {
            subject: message.subject.clone(),
            body,
            lower,
            links,
        }
    }
    pub fn mentions(&self, words: &[&str]) -> bool {
        words.iter().any(|w| self.lower.contains(w))
    }
}

fn truncate(text: &mut String, max: usize) {
    if text.len() > max {
        let mut end = max;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
}

pub fn strip_html(html: &str) -> String {
    let mut out = String::with_capacity(html.len() / 3);
    let mut rest = html;
    while let Some(start) = rest.find('<') {
        out.push_str(&rest[..start]);
        let tag = &rest[start..];
        let lower: String = tag.chars().take(8).collect::<String>().to_lowercase();
        let skip_to = if lower.starts_with("<style") {
            find_ci(tag, "</style>")
        } else if lower.starts_with("<script") {
            find_ci(tag, "</script>")
        } else {
            None
        };
        let after = match skip_to {
            Some(end) => start + end,
            None => start,
        };
        match rest[after..].find('>') {
            Some(end) => {
                out.push(' ');
                rest = &rest[after + end + 1..];
            }
            None => {
                rest = "";
            }
        }
    }
    out.push_str(rest);
    let decoded = out
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&#36;", "$")
        .replace("&pound;", "£")
        .replace("&euro;", "€")
        .replace("&lt;", "<")
        .replace("&gt;", ">");
    decoded.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn find_ci(haystack: &str, needle: &str) -> Option<usize> {
    haystack.to_lowercase().find(needle)
}

fn html_links(html: &str) -> Vec<(String, String)> {
    let mut links = Vec::new();
    let lower = html.to_lowercase();
    let mut from = 0;
    while let Some(found) = lower[from..].find("href=") {
        let at = from + found + 5;
        from = at;
        let Some(quote) = html[at..]
            .chars()
            .next()
            .filter(|c| *c == '"' || *c == '\'')
        else {
            continue;
        };
        let start = at + 1;
        let Some(len) = html[start..].find(quote) else {
            break;
        };
        let url = html[start..start + len].replace("&amp;", "&");
        if !url.starts_with("https://") || url.len() > 2048 {
            continue;
        }
        // The anchor's visible text, roughly: what follows up to `</a>`.
        let tail = &html[start + len..];
        let anchor_end = find_ci(tail, "</a>").unwrap_or(0).min(400);
        let anchor = strip_html(&format!("<x{}", &tail[..anchor_end]));
        links.push((url, anchor));
        if links.len() >= 200 {
            break;
        }
    }
    links
}

// MARK: Tracking numbers

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Carrier {
    Ups,
    Usps,
    FedEx,
    Dhl,
    RoyalMail,
}

impl Carrier {
    pub fn name(self) -> &'static str {
        match self {
            Self::Ups => "UPS",
            Self::Usps => "USPS",
            Self::FedEx => "FedEx",
            Self::Dhl => "DHL",
            Self::RoyalMail => "Royal Mail",
        }
    }
    /// The mark the app draws for this carrier, when it ships one.
    pub fn brand(self) -> Option<&'static str> {
        match self {
            Self::Ups => Some("ups"),
            Self::Usps => Some("usps"),
            Self::FedEx => Some("fedex"),
            Self::Dhl => Some("dhl"),
            Self::RoyalMail => None,
        }
    }
    pub fn tracking_url(self, number: &str) -> String {
        match self {
            Self::Ups => format!("https://www.ups.com/track?tracknum={number}"),
            Self::Usps => format!("https://tools.usps.com/go/TrackConfirmAction?tLabels={number}"),
            Self::FedEx => format!("https://www.fedex.com/fedextrack/?trknbr={number}"),
            Self::Dhl => format!(
                "https://www.dhl.com/global-en/home/tracking/tracking-express.html?submit=1&tracking-id={number}"
            ),
            Self::RoyalMail => {
                format!("https://www.royalmail.com/track-your-item#/tracking-results/{number}")
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tracking {
    pub carrier: Carrier,
    pub number: String,
}

const SHIPPING_WORDS: &[&str] = &[
    "tracking",
    "shipped",
    "shipment",
    "package",
    "parcel",
    "delivery",
    "delivered",
    "dispatched",
    "on its way",
    "in transit",
];

/// Finds the first carrier tracking number in shipping mail. Bare digit runs
/// only count when the carrier is named, so order numbers don't match.
pub fn tracking_number(text: &MailText) -> Option<Tracking> {
    if !text.mentions(SHIPPING_WORDS) {
        return None;
    }
    let names_fedex = text.lower.contains("fedex");
    let names_dhl = text.lower.contains("dhl");
    let names_usps = text.lower.contains("usps") || text.lower.contains("postal service");
    for source in [&text.subject, &text.body] {
        for token in tokens(source) {
            let upper = token.to_ascii_uppercase();
            let bytes = upper.as_bytes();
            let digits = bytes.iter().all(u8::is_ascii_digit);
            let found = if upper.len() == 18
                && upper.starts_with("1Z")
                && bytes.iter().all(u8::is_ascii_alphanumeric)
            {
                Some(Carrier::Ups)
            } else if digits
                && (20..=22).contains(&upper.len())
                && upper.starts_with('9')
                && (names_usps || !names_fedex)
            {
                Some(Carrier::Usps)
            } else if digits && (upper.len() == 12 || upper.len() == 15) && names_fedex {
                Some(Carrier::FedEx)
            } else if digits && upper.len() == 10 && names_dhl {
                Some(Carrier::Dhl)
            } else if upper.len() == 13
                && upper.ends_with("GB")
                && bytes[..2].iter().all(u8::is_ascii_alphabetic)
                && bytes[2..11].iter().all(u8::is_ascii_digit)
            {
                Some(Carrier::RoyalMail)
            } else {
                None
            };
            if let Some(carrier) = found {
                return Some(Tracking {
                    carrier,
                    number: upper,
                });
            }
        }
    }
    None
}

/// Alphanumeric tokens, with digit groups separated by single spaces joined
/// ("9400 1000 0000" → "940010000000"), as carriers print long numbers that way.
fn tokens(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c.is_ascii_alphanumeric() {
            current.push(c);
        } else if c == ' '
            && !current.is_empty()
            && current.bytes().all(|b| b.is_ascii_digit())
            && chars.peek().is_some_and(char::is_ascii_digit)
        {
            continue;
        } else if !current.is_empty() {
            out.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum ShipmentStage {
    Ordered,
    Shipped,
    OutForDelivery,
    Delivered,
}

pub fn shipment_stage(text: &MailText) -> Option<ShipmentStage> {
    let check = |s: &str| -> Option<ShipmentStage> {
        let s = s.to_lowercase();
        if s.contains("out for delivery") {
            Some(ShipmentStage::OutForDelivery)
        } else if (s.contains("was delivered")
            || s.contains("has been delivered")
            || s.contains("delivered:")
            || s.starts_with("delivered"))
            && !s.contains("will be delivered")
        {
            Some(ShipmentStage::Delivered)
        } else if s.contains("shipped")
            || s.contains("on its way")
            || s.contains("on the way")
            || s.contains("in transit")
            || s.contains("dispatched")
        {
            Some(ShipmentStage::Shipped)
        } else if s.contains("label created") || s.contains("order confirmed") {
            Some(ShipmentStage::Ordered)
        } else {
            None
        }
    };
    // The subject states the news; the body often mentions every stage.
    check(&text.subject).or_else(|| check(&text.body))
}

/// "Arriving Thursday", "Estimated delivery: Dec 5" → the phrase after the cue.
pub fn delivery_estimate(text: &MailText) -> Option<String> {
    const CUES: &[&str] = &[
        "estimated delivery date:",
        "estimated delivery:",
        "expected delivery:",
        "scheduled delivery:",
        "arriving ",
        "arrives ",
        "expected by ",
    ];
    for source in [&text.subject, &text.body] {
        let lower = source.to_lowercase();
        for cue in CUES {
            if let Some(at) = lower.find(cue) {
                let rest = source[at + cue.len()..].trim_start();
                let phrase: String = rest
                    .chars()
                    .take_while(|c| !matches!(c, '.' | '\n' | '|' | '!' | ';'))
                    .take(32)
                    .collect();
                let phrase = phrase.trim().trim_end_matches(',').trim().to_owned();
                if phrase.len() >= 3 {
                    return Some(phrase);
                }
            }
        }
    }
    None
}

// MARK: Money and dates

#[derive(Clone, Debug, PartialEq)]
pub struct Money {
    pub symbol: &'static str,
    pub amount: String,
}

impl Money {
    pub fn display(&self) -> String {
        if self.symbol.len() == 3 && self.symbol.is_ascii() {
            format!("{} {}", self.amount, self.symbol)
        } else {
            format!("{}{}", self.symbol, self.amount)
        }
    }
}

const SYMBOLS: &[(&str, &str)] = &[
    ("US$", "$"),
    ("$", "$"),
    ("£", "£"),
    ("€", "€"),
    ("₦", "₦"),
    ("¥", "¥"),
    ("₹", "₹"),
    ("USD", "USD"),
    ("GBP", "GBP"),
    ("EUR", "EUR"),
    ("NGN", "NGN"),
    ("CAD", "CAD"),
];

/// The first amount after any of `cues`, else the first amount in the text.
pub fn amount(text: &str, cues: &[&str]) -> Option<Money> {
    let lower = text.to_lowercase();
    for cue in cues {
        let mut from = 0;
        while let Some(found) = lower[from..].find(cue) {
            let at = from + found + cue.len();
            let window_end = floor_boundary(text, (at + 80).min(text.len()));
            if let Some(money) = first_amount(&text[at..window_end]) {
                return Some(money);
            }
            from = at;
        }
    }
    None
}

fn floor_boundary(text: &str, mut index: usize) -> usize {
    while !text.is_char_boundary(index) {
        index -= 1;
    }
    index
}

fn first_amount(text: &str) -> Option<Money> {
    let mut best: Option<(usize, Money)> = None;
    for (marker, symbol) in SYMBOLS {
        let mut from = 0;
        while let Some(found) = text[from..].find(marker) {
            let at = from + found;
            from = at + marker.len();
            if best.as_ref().is_some_and(|(b, _)| *b <= at) {
                break;
            }
            // Codes must stand alone: "USD 12" or "12.00 USD", never "USDC".
            let after = text[from..].trim_start();
            let number = leading_number(after).or_else(|| {
                (marker.len() == 3)
                    .then(|| trailing_number(&text[..at]))
                    .flatten()
            });
            if let Some(amount) = number {
                best = Some((at, Money { symbol, amount }));
                break;
            }
        }
    }
    best.map(|(_, money)| money)
}

fn leading_number(text: &str) -> Option<String> {
    let number: String = text
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == ',' || *c == '.')
        .collect();
    clean_number(number)
}

fn trailing_number(text: &str) -> Option<String> {
    let trimmed = text.trim_end();
    let number: String = trimmed
        .chars()
        .rev()
        .take_while(|c| c.is_ascii_digit() || *c == ',' || *c == '.')
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    clean_number(number)
}

fn clean_number(number: String) -> Option<String> {
    let number = number.trim_end_matches(['.', ',']).to_owned();
    let digits = number.chars().filter(char::is_ascii_digit).count();
    (digits > 0 && digits <= 12 && number.starts_with(|c: char| c.is_ascii_digit()))
        .then_some(number)
}

const MONTHS: &[&str] = &[
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
];

/// The first date after any of `cues`. A date without a year takes the next
/// occurrence on or after `today`. Slash dates read month first unless the
/// first part can't be a month.
pub fn date_after(text: &str, cues: &[&str], today: NaiveDate) -> Option<NaiveDate> {
    let lower = text.to_lowercase();
    for cue in cues {
        let mut from = 0;
        while let Some(found) = lower[from..].find(cue) {
            let at = from + found + cue.len();
            let end = floor_boundary(&lower, (at + 48).min(lower.len()));
            if let Some(date) = parse_date(&lower[at..end], today) {
                return Some(date);
            }
            from = at;
        }
    }
    None
}

fn parse_date(window: &str, today: NaiveDate) -> Option<NaiveDate> {
    let words: Vec<&str> = window
        .split(|c: char| c.is_whitespace() || c == ',')
        .filter(|w| !w.is_empty())
        .take(6)
        .collect();
    for (i, word) in words.iter().enumerate() {
        let word = word.trim_matches(|c: char| !c.is_alphanumeric() && c != '/' && c != '-');
        if let Some(date) = numeric_date(word) {
            return Some(date);
        }
        if let Some(month) = month_index(word) {
            // "December 5, 2026" / "Dec 5"
            if let Some(day) = words.get(i + 1).and_then(|w| day_number(w)) {
                let year = words.get(i + 2).and_then(|w| year_number(w));
                return resolve(year, month, day, today);
            }
            // "5 December 2026"
            if i > 0
                && let Some(day) = day_number(words[i - 1])
            {
                let year = words.get(i + 1).and_then(|w| year_number(w));
                return resolve(year, month, day, today);
            }
        }
    }
    None
}

fn numeric_date(word: &str) -> Option<NaiveDate> {
    if let Ok(date) = NaiveDate::parse_from_str(word, "%Y-%m-%d") {
        return Some(date);
    }
    let parts: Vec<&str> = word.split('/').collect();
    if parts.len() != 3 {
        return None;
    }
    let a: u32 = parts[0].parse().ok()?;
    let b: u32 = parts[1].parse().ok()?;
    let mut year: i32 = parts[2].parse().ok()?;
    if year < 100 {
        year += 2000;
    }
    let (month, day) = if a > 12 { (b, a) } else { (a, b) };
    NaiveDate::from_ymd_opt(year, month, day)
}

fn month_index(word: &str) -> Option<u32> {
    let word = word.trim_end_matches('.');
    if word.len() < 3 {
        return None;
    }
    MONTHS
        .iter()
        .position(|m| word.starts_with(m) && "january february march april may june july august september october november december sept".contains(word))
        .map(|i| i as u32 + 1)
}

fn day_number(word: &str) -> Option<u32> {
    let digits: String = word.chars().take_while(char::is_ascii_digit).collect();
    let rest = &word[digits.len()..];
    if !(rest.is_empty() || ["st", "nd", "rd", "th"].contains(&rest)) {
        return None;
    }
    digits.parse().ok().filter(|d| (1..=31).contains(d))
}

fn year_number(word: &str) -> Option<i32> {
    word.parse().ok().filter(|y| (2000..=2100).contains(y))
}

fn resolve(year: Option<i32>, month: u32, day: u32, today: NaiveDate) -> Option<NaiveDate> {
    use chrono::Datelike;
    match year {
        Some(year) => NaiveDate::from_ymd_opt(year, month, day),
        None => {
            let this = NaiveDate::from_ymd_opt(today.year(), month, day)?;
            // Allow a recent past date (an overdue bill) before rolling forward.
            if this >= today - chrono::Days::new(45) {
                Some(this)
            } else {
                NaiveDate::from_ymd_opt(today.year() + 1, month, day)
            }
        }
    }
}

/// The first link whose URL or visible text contains one of `words`.
pub fn link_matching(text: &MailText, words: &[&str]) -> Option<String> {
    text.links
        .iter()
        .find(|(url, anchor)| {
            let url = url.to_lowercase();
            let anchor = anchor.to_lowercase();
            words.iter().any(|w| anchor.contains(w)) || words.iter().any(|w| url.contains(w))
        })
        .map(|(url, _)| url.clone())
}

/// A short code after a cue, such as an invoice number.
pub fn code_after(text: &str, cues: &[&str]) -> Option<String> {
    let lower = text.to_lowercase();
    for cue in cues {
        if let Some(found) = lower.find(cue) {
            let rest = text[found + cue.len()..]
                .trim_start_matches(|c: char| c.is_whitespace() || matches!(c, '#' | ':' | '.'));
            let code: String = rest
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '-')
                .take(32)
                .collect();
            if code.len() >= 3 && code.chars().any(|c| c.is_ascii_digit()) {
                return Some(code);
            }
        }
    }
    None
}

// MARK: Senders and links

/// The sender's domain, lowercased: "alerts@acme.sentry.io" → "acme.sentry.io".
pub fn sender_domain(message: &Message) -> String {
    message
        .from
        .email
        .rsplit_once('@')
        .map(|(_, domain)| domain.trim().trim_end_matches('.').to_ascii_lowercase())
        .unwrap_or_default()
}

/// True when `host` is `domain` or one of its subdomains.
pub fn host_is(host: &str, domain: &str) -> bool {
    host == domain
        || host
            .strip_suffix(domain)
            .is_some_and(|prefix| prefix.ends_with('.'))
}

/// Splits an https URL into lowercased host and the path after it.
pub fn https_parts(url: &str) -> Option<(String, &str)> {
    let rest = url.strip_prefix("https://")?;
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let host = &rest[..end];
    if host.is_empty() || host.contains(['@', ':']) {
        return None;
    }
    Some((host.to_ascii_lowercase(), &rest[end..]))
}

/// The first https link in the body text or the HTML part accepted by
/// `wanted(host, path)`, trimmed of trailing punctuation.
pub fn find_link(text: &MailText, wanted: impl Fn(&str, &str) -> bool) -> Option<String> {
    let from_body = text.body.match_indices("https://").map(|(at, _)| {
        text.body[at..]
            .split(|c: char| c.is_whitespace() || matches!(c, '<' | '>' | '"' | ')' | ']'))
            .next()
            .unwrap_or_default()
            .to_owned()
    });
    let from_links = text.links.iter().map(|(url, _)| url.clone());
    from_body
        .chain(from_links)
        .map(|url| url.trim_end_matches(['.', ',', ';', ':']).to_owned())
        .filter(|url| url.len() <= 1024)
        .find(|url| https_parts(url).is_some_and(|(host, path)| wanted(&host, path)))
}

/// The rest of the line after `cue` (case-insensitive), trimmed, at most 80 chars.
pub fn value_after(text: &str, cue: &str) -> Option<String> {
    let lower = text.to_lowercase();
    let at = lower.find(cue)? + cue.len();
    let value: String = text
        .get(at..)?
        .trim_start_matches([' ', ':', '\t'])
        .chars()
        .take_while(|c| *c != '\n' && *c != '\r')
        .take(80)
        .collect();
    let value = value.trim().to_owned();
    (!value.is_empty()).then_some(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(subject: &str, body: &str) -> MailText {
        MailText {
            subject: subject.into(),
            body: body.into(),
            lower: format!("{subject}\n{body}").to_lowercase(),
            links: Vec::new(),
        }
    }

    #[test]
    fn finds_carrier_numbers_only_in_shipping_mail() {
        let ups = text("Your order has shipped", "Tracking: 1z999aa10123456784.");
        assert_eq!(
            tracking_number(&ups),
            Some(Tracking {
                carrier: Carrier::Ups,
                number: "1Z999AA10123456784".into()
            })
        );
        let usps = text("Shipped", "USPS tracking 9400 1000 0000 0000 0000 00");
        assert_eq!(tracking_number(&usps).unwrap().carrier, Carrier::Usps);
        assert_eq!(tracking_number(&usps).unwrap().number.len(), 22);
        let fedex = text("FedEx shipment", "Tracking number 123456789012");
        assert_eq!(tracking_number(&fedex).unwrap().carrier, Carrier::FedEx);
        let royal = text("Your parcel is on its way", "Ref AB123456789GB");
        assert_eq!(tracking_number(&royal).unwrap().carrier, Carrier::RoyalMail);
        // An order number in a receipt is not a tracking number.
        assert_eq!(
            tracking_number(&text("Receipt", "Order 123456789012")),
            None
        );
        assert_eq!(
            tracking_number(&text("Shipped", "Order 123456789012")),
            None
        );
    }

    #[test]
    fn reads_shipment_stage_from_subject_first() {
        let t = text(
            "Out for delivery: your package",
            "It shipped Monday and will be delivered today",
        );
        assert_eq!(shipment_stage(&t), Some(ShipmentStage::OutForDelivery));
        let t = text(
            "Update",
            "Your package will be delivered Friday. It shipped today.",
        );
        assert_eq!(shipment_stage(&t), Some(ShipmentStage::Shipped));
        let t = text("Delivered: Your Amazon package", "");
        assert_eq!(shipment_stage(&t), Some(ShipmentStage::Delivered));
        let t = text("Shipped", "Arriving Thursday, Dec 4. Thanks!");
        assert_eq!(delivery_estimate(&t).as_deref(), Some("Thursday, Dec 4"));
    }

    #[test]
    fn finds_amounts_after_cues() {
        let body = "Invoice INV-2041. Subtotal $90.00 Amount due: $1,234.50 by Dec 5";
        assert_eq!(
            amount(body, &["amount due"]).unwrap().display(),
            "$1,234.50"
        );
        assert_eq!(
            amount("Total due 49.99 EUR.", &["total due"])
                .unwrap()
                .display(),
            "49.99 EUR"
        );
        assert_eq!(
            amount("Balance due: £12", &["balance due"])
                .unwrap()
                .display(),
            "£12"
        );
        assert_eq!(amount("Nothing here", &["amount due"]), None);
        assert_eq!(code_after(body, &["invoice"]).as_deref(), Some("INV-2041"));
    }

    #[test]
    fn parses_due_dates() {
        let today = NaiveDate::from_ymd_opt(2026, 11, 21).unwrap();
        let date = |s: &str| date_after(s, &["due"], today);
        assert_eq!(
            date("Payment due December 5, 2026."),
            NaiveDate::from_ymd_opt(2026, 12, 5)
        );
        assert_eq!(date("due by Dec 5"), NaiveDate::from_ymd_opt(2026, 12, 5));
        assert_eq!(
            date("due on 5th January"),
            NaiveDate::from_ymd_opt(2027, 1, 5)
        );
        assert_eq!(
            date("due date: 2026-12-01"),
            NaiveDate::from_ymd_opt(2026, 12, 1)
        );
        assert_eq!(
            date("due 25/12/2026"),
            NaiveDate::from_ymd_opt(2026, 12, 25)
        );
        assert_eq!(
            date("was due Nov 10"),
            NaiveDate::from_ymd_opt(2026, 11, 10)
        );
        assert_eq!(date("due soon, maybe"), None);
    }

    #[test]
    fn matches_hosts_and_links() {
        assert!(host_is("acme.sentry.io", "sentry.io"));
        assert!(host_is("sentry.io", "sentry.io"));
        assert!(!host_is("evilsentry.io", "sentry.io"));
        assert!(!host_is("sentry.io.evil.test", "sentry.io"));
        assert_eq!(https_parts("https://user@evil.test/x"), None);
        let t = text(
            "",
            "See https://acme.sentry.io/issues/42/?ref=mail. And http://acme.sentry.io/x",
        );
        assert_eq!(
            find_link(&t, |host, path| host_is(host, "sentry.io")
                && path.starts_with("/issues/"))
            .as_deref(),
            Some("https://acme.sentry.io/issues/42/?ref=mail")
        );
        assert_eq!(
            value_after("Env\nEnvironment: production\nNext", "environment").as_deref(),
            Some("production")
        );
    }

    #[test]
    fn strips_html_and_collects_links() {
        let html = r#"<style>p{color:red}</style><p>Hello&nbsp;<b>you</b></p><a href="https://pay.test/i/1?a=1&amp;b=2">Pay invoice</a>"#;
        assert_eq!(strip_html(html), "Hello you Pay invoice");
        assert_eq!(
            html_links(html),
            vec![("https://pay.test/i/1?a=1&b=2".into(), "Pay invoice".into())]
        );
    }
}
