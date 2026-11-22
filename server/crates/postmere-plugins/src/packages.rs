//! Package Tracking: carrier, stage and estimate for shipping mail, with a
//! link to the carrier's tracking page. Everything is read from the message.
use crate::card::{Action, Card, Component, Effect, ToolResult};
use crate::detect::{self, ShipmentStage, Tracking};
use crate::plugin::{
    Context, Manifest, MessageAction, Permission, Plugin, SettingField, SettingKind, ToolError,
};
use serde_json::Value;

pub struct Packages;

const STEPS: [&str; 4] = ["Ordered", "Shipped", "Out for delivery", "Delivered"];

impl Packages {
    fn tracking(context: &Context) -> Option<Tracking> {
        detect::tracking_number(context.text)
    }
}

impl Plugin for Packages {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "postmere.packages",
            name: "Package Tracking",
            summary: "Delivery status and tracking links on shipping mail.",
            version: 1,
            icon: "shippingbox",
            tint: "orange",
            brands: vec![],
            permissions: vec![Permission::MessageRead],
            settings: vec![SettingField {
                key: "show_delivered",
                title: "Show delivered packages",
                kind: SettingKind::Toggle { default: true },
            }],
        }
    }

    fn banner(&self, context: &Context) -> Option<Card> {
        let tracking = Self::tracking(context)?;
        let stage = detect::shipment_stage(context.text);
        if stage == Some(ShipmentStage::Delivered) && !context.setting_bool("show_delivered", true)
        {
            return None;
        }
        let title = match stage {
            Some(ShipmentStage::Ordered) => "Label created",
            Some(ShipmentStage::Shipped) => "On the way",
            Some(ShipmentStage::OutForDelivery) => "Out for delivery",
            Some(ShipmentStage::Delivered) => "Delivered",
            None => "Package on the way",
        };
        let mut subtitle = tracking.carrier.name().to_owned();
        if stage != Some(ShipmentStage::Delivered)
            && let Some(estimate) = detect::delivery_estimate(context.text)
        {
            subtitle.push_str(" · Arriving ");
            subtitle.push_str(&estimate);
        }
        let mut card = Card::new(title).subtitle(subtitle);
        if let Some(brand) = tracking.carrier.brand() {
            card = card.brand(brand);
        }
        if let Some(stage) = stage {
            card = card.component(Component::Steps {
                labels: STEPS.iter().map(|s| (*s).into()).collect(),
                current: stage as usize,
            });
        }
        Some(
            card.component(Component::Facts {
                items: vec![("Tracking".into(), tracking.number.clone())],
            })
            .action(Action::open(
                format!("Track on {}", tracking.carrier.name()),
                "arrow.up.right",
                tracking.carrier.tracking_url(&tracking.number),
            ))
            .action(Action::copy("Copy Number", "doc.on.doc", tracking.number)),
        )
    }

    fn actions(&self, context: &Context) -> Vec<MessageAction> {
        Self::tracking(context)
            .map(|_| MessageAction {
                tool: "track_package",
                title: "Track Package".into(),
                icon: "shippingbox",
                args: Value::Null,
            })
            .into_iter()
            .collect()
    }

    fn call(&self, tool: &str, context: &Context, _args: &Value) -> Result<ToolResult, ToolError> {
        match tool {
            "track_package" => {
                let tracking = Self::tracking(context).ok_or(ToolError::NotApplicable(
                    "No tracking number in this message.",
                ))?;
                Ok(ToolResult {
                    effects: vec![Effect::Open {
                        url: tracking.carrier.tracking_url(&tracking.number),
                    }],
                    ..ToolResult::default()
                })
            }
            _ => Err(ToolError::UnknownTool),
        }
    }
}
