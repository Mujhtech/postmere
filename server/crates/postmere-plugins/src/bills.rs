//! Bills and invoices: amount, due date and the payment link, plus a reminder
//! before the due date. Receipts for money already paid get a quieter card.
use crate::card::{Action, Card, Component, Effect, ToolResult};
use crate::detect::{self, Money};
use crate::plugin::{
    Context, Manifest, MessageAction, Permission, Plugin, SettingField, SettingKind, ToolError,
};
use chrono::{Days, NaiveDate};
use serde_json::{Value, json};

pub struct Bills;

const BILL_WORDS: &[&str] = &[
    "invoice",
    "amount due",
    "balance due",
    "total due",
    "payment due",
    "due date",
    "your bill",
    "statement is ready",
    "minimum payment",
];
const PAID_WORDS: &[&str] = &[
    "payment received",
    "thank you for your payment",
    "thanks for your payment",
    "has been paid",
    "paid in full",
    "payment confirmation",
];
const AMOUNT_CUES: &[&str] = &[
    "amount due",
    "balance due",
    "total due",
    "payment due",
    "minimum payment",
    "amount:",
    "amount paid",
    "total:",
    "total",
    "balance",
    "invoice",
];
const DUE_CUES: &[&str] = &[
    "due date",
    "due on",
    "due by",
    "payment due",
    "is due",
    "due:",
    "due ",
];

#[derive(Debug, PartialEq)]
struct Bill {
    amount: Money,
    due: Option<NaiveDate>,
    paid: bool,
    invoice: Option<String>,
    pay_link: Option<String>,
}

impl Bills {
    fn bill(context: &Context) -> Option<Bill> {
        let text = context.text;
        if !text.mentions(BILL_WORDS) && !text.mentions(PAID_WORDS) {
            return None;
        }
        let haystack = format!("{}\n{}", text.subject, text.body);
        let amount = detect::amount(&haystack, AMOUNT_CUES)?;
        let paid = text.mentions(PAID_WORDS);
        let due = (!paid)
            .then(|| detect::date_after(&haystack, DUE_CUES, context.today))
            .flatten();
        Some(Bill {
            amount,
            due,
            paid,
            invoice: detect::code_after(
                &haystack,
                &["invoice number", "invoice no", "invoice #", "invoice"],
            ),
            pay_link: (!paid)
                .then(|| {
                    detect::link_matching(
                        text,
                        &[
                            "pay now",
                            "pay invoice",
                            "pay bill",
                            "make a payment",
                            "pay online",
                            "/pay",
                        ],
                    )
                })
                .flatten(),
        })
    }

    fn reminder_date(bill: &Bill, context: &Context) -> Option<NaiveDate> {
        let due = bill.due?;
        let days: u64 = context
            .setting_str("remind_days_before", "3")
            .parse()
            .unwrap_or(3);
        let date = due.checked_sub_days(Days::new(days))?.max(context.today);
        (due >= context.today).then_some(date)
    }
}

fn short_date(date: NaiveDate, today: NaiveDate) -> String {
    let days = (date - today).num_days();
    match days {
        0 => "today".into(),
        1 => "tomorrow".into(),
        2..=6 => date.format("%A").to_string(),
        _ if date.format("%Y").to_string() == today.format("%Y").to_string() => {
            date.format("%b %-d").to_string()
        }
        _ => date.format("%b %-d, %Y").to_string(),
    }
}

fn remind_title(date: NaiveDate, today: NaiveDate) -> String {
    match (date - today).num_days() {
        0 => "Remind Me Today".into(),
        1 => "Remind Me Tomorrow".into(),
        2..=6 => format!("Remind Me {}", date.format("%A")),
        _ => format!("Remind Me on {}", short_date(date, today)),
    }
}

impl Plugin for Bills {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "postmere.bills",
            name: "Bills & Invoices",
            summary: "Amount, due date and a reminder on bills.",
            version: 1,
            icon: "doc.text",
            tint: "green",
            permissions: vec![Permission::MessageRead],
            settings: vec![SettingField {
                key: "remind_days_before",
                title: "Remind me",
                kind: SettingKind::Choice {
                    options: vec![
                        ("1", "1 day before"),
                        ("3", "3 days before"),
                        ("7", "A week before"),
                    ],
                    default: "3",
                },
            }],
        }
    }

    fn banner(&self, context: &Context) -> Option<Card> {
        let bill = Self::bill(context)?;
        let amount = bill.amount.display();
        let today = context.today;
        let (title, badge) = match (bill.paid, bill.due) {
            (true, _) => (format!("{amount} paid"), Some(("Paid", "green"))),
            (false, Some(due)) if due < today => {
                (format!("{amount} overdue"), Some(("Overdue", "red")))
            }
            (false, Some(due)) => (format!("{amount} due {}", short_date(due, today)), None),
            (false, None) => (format!("{amount} due"), None),
        };
        let sender = context
            .message
            .from
            .name
            .clone()
            .filter(|n| !n.trim().is_empty())
            .unwrap_or_else(|| context.message.from.email.clone());
        let mut card = Card::new(title).subtitle(sender);
        if let Some((label, tint)) = badge {
            card = card.component(Component::Badge {
                label: label.into(),
                tint: Some(tint),
            });
        }
        let mut facts = vec![("Amount".into(), amount)];
        if let Some(due) = bill.due {
            facts.push(("Due".into(), due.format("%a, %b %-d, %Y").to_string()));
        }
        if let Some(invoice) = &bill.invoice {
            facts.push(("Invoice".into(), invoice.clone()));
        }
        card = card.component(Component::Facts { items: facts });
        if let Some(link) = bill.pay_link.clone() {
            card = card.action(Action::open("Pay", "creditcard", link));
        }
        if let Some(date) = Self::reminder_date(&bill, context) {
            let remind = Action::tool(
                remind_title(date, today),
                "bell",
                "remind_bill",
                json!({ "date": date.to_string() }),
            );
            card = card.action(if bill.pay_link.is_none() {
                Action {
                    style: crate::card::ActionStyle::Primary,
                    ..remind
                }
            } else {
                remind
            });
        }
        Some(card)
    }

    fn actions(&self, context: &Context) -> Vec<MessageAction> {
        let Some(bill) = Self::bill(context) else {
            return Vec::new();
        };
        let mut actions = Vec::new();
        if let Some(date) = Self::reminder_date(&bill, context) {
            actions.push(MessageAction {
                tool: "remind_bill",
                title: "Remind Me About This Bill".into(),
                icon: "bell",
                args: json!({ "date": date.to_string() }),
            });
        }
        if bill.pay_link.is_some() {
            actions.push(MessageAction {
                tool: "pay_bill",
                title: "Pay Bill".into(),
                icon: "creditcard",
                args: Value::Null,
            });
        }
        actions
    }

    fn call(&self, tool: &str, context: &Context, args: &Value) -> Result<ToolResult, ToolError> {
        let bill =
            Self::bill(context).ok_or(ToolError::NotApplicable("This message isn't a bill."))?;
        match tool {
            "remind_bill" => {
                let date = args
                    .get("date")
                    .and_then(Value::as_str)
                    .and_then(|s| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
                    .or_else(|| Self::reminder_date(&bill, context))
                    .ok_or(ToolError::InvalidArguments("Choose a reminder date."))?;
                if date < context.today {
                    return Err(ToolError::InvalidArguments(
                        "Choose a date that hasn't passed.",
                    ));
                }
                Ok(ToolResult {
                    toast: Some(format!("Reminder set for {}", date.format("%a, %b %-d"))),
                    effects: vec![Effect::Remind {
                        date: date.to_string(),
                    }],
                    ..ToolResult::default()
                })
            }
            "pay_bill" => {
                let url = bill
                    .pay_link
                    .ok_or(ToolError::NotApplicable("No payment link in this message."))?;
                Ok(ToolResult {
                    effects: vec![Effect::Open { url }],
                    ..ToolResult::default()
                })
            }
            _ => Err(ToolError::UnknownTool),
        }
    }
}
