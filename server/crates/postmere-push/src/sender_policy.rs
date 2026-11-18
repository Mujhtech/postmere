use postmere_core::error::AppError;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub const SENDER_POLICY_VERSION: u32 = 1;
const MAX_RULES: usize = 4096;
const MAX_POLICY_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SenderPolicy {
    pub version: u32,
    pub screen_unknown_senders: bool,
    pub rules: Vec<SenderRule>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SenderRule {
    pub email: String,
    pub route: SenderRoute,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
pub enum SenderRoute {
    #[serde(rename = "inbox")]
    Inbox,
    #[serde(rename = "needsReply")]
    NeedsReply,
    #[serde(rename = "archive")]
    Archive,
    #[serde(rename = "blocked")]
    Blocked,
}

impl SenderPolicy {
    pub fn validate(&self) -> Result<(), AppError> {
        if self.version != SENDER_POLICY_VERSION
            || self.rules.len() > MAX_RULES
            || self.rules.iter().any(|rule| !valid_email(&rule.email))
            || serde_json::to_vec(self)
                .map_err(|_| AppError::internal("push_policy_encode"))?
                .len()
                > MAX_POLICY_BYTES
        {
            return Err(AppError::bad_request("Invalid push sender policy."));
        }
        Ok(())
    }

    /// The native client has already selected rules for this exact account.
    /// Preserve first-match order; routes never promote non-Inbox/read mail.
    pub fn allows(&self, sender: &str) -> bool {
        let sender = sender.to_lowercase();
        self.rules
            .iter()
            .find(|rule| rule.email.to_lowercase() == sender)
            .map_or(!self.screen_unknown_senders, |rule| {
                matches!(rule.route, SenderRoute::Inbox | SenderRoute::NeedsReply)
            })
    }
}

fn valid_email(email: &str) -> bool {
    email.len() <= 320
        && !email
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || matches!(c, '<' | '>' | ',' | ';'))
        && email.split_once('@').is_some_and(|(local, domain)| {
            !local.is_empty() && !domain.is_empty() && !domain.contains('@')
        })
}

/// Domain-separated resource identity binds ciphertext to its user, device,
/// and account. CredentialCipher adds the workspace to the AEAD associated data.
pub(crate) fn policy_resource_id(user: Uuid, device: Uuid, account: Uuid) -> Uuid {
    let mut hash = Sha256::new();
    hash.update(b"postmere.push.sender-policy.v1\0");
    hash.update(user.as_bytes());
    hash.update(device.as_bytes());
    hash.update(account.as_bytes());
    let digest = hash.finalize();
    Uuid::from_bytes(digest[..16].try_into().expect("SHA-256 contains 16 bytes"))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn policy(screen: bool, routes: &[SenderRoute]) -> SenderPolicy {
        SenderPolicy {
            version: 1,
            screen_unknown_senders: screen,
            rules: routes
                .iter()
                .map(|route| SenderRule {
                    email: "approved@example.test".into(),
                    route: *route,
                })
                .collect(),
        }
    }
    #[test]
    fn ordered_rules_allow_only_approved_routes_and_screen_unknowns() {
        for allow in [SenderRoute::Inbox, SenderRoute::NeedsReply] {
            let p = policy(true, &[allow, SenderRoute::Blocked]);
            assert!(p.allows("APPROVED@example.test"));
            assert!(!p.allows("unknown@example.test"));
        }
        for deny in [SenderRoute::Archive, SenderRoute::Blocked] {
            let p = policy(false, &[deny, SenderRoute::Inbox]);
            assert!(!p.allows("approved@example.test"));
            assert!(p.allows("unknown@example.test"));
        }
    }
    #[test]
    fn policy_is_bounded_and_malformed_rules_are_rejected_without_truncation() {
        let mut p = policy(true, &[SenderRoute::Inbox]);
        assert!(p.validate().is_ok());
        p.version = 2;
        assert!(p.validate().is_err());
        p.version = 1;
        for invalid in [
            "",
            "missing-at",
            "a@@b",
            "a@",
            "@b",
            " a@b",
            "a@b\n",
            "A <a@b>",
        ] {
            p.rules[0].email = invalid.into();
            assert!(p.validate().is_err(), "{invalid:?}");
        }
        p.rules[0].email = "valid@example.test".into();
        p.rules = vec![p.rules[0].clone(); MAX_RULES];
        assert!(p.validate().is_ok());
        p.rules.push(p.rules[0].clone());
        assert!(p.validate().is_err());
        p.rules.pop();
        for rule in &mut p.rules {
            rule.email = format!("{}@example.test", "x".repeat(300));
        }
        assert!(p.validate().is_err());
        assert!(serde_json::from_str::<SenderPolicy>(r#"{"version":1,"screen_unknown_senders":true,"rules":[{"email":"a@b","route":"delete"}]}"#).is_err());
        assert!(
            serde_json::from_str::<SenderPolicy>(
                r#"{"version":1,"screen_unknown_senders":true,"rules":[],"extra":true}"#
            )
            .is_err()
        );
    }
    #[test]
    fn encryption_resource_identity_separates_every_policy_owner() {
        let ids = [Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4()];
        let original = policy_resource_id(ids[0], ids[1], ids[2]);
        for index in 0..3 {
            let mut other = ids;
            other[index] = Uuid::new_v4();
            assert_ne!(original, policy_resource_id(other[0], other[1], other[2]));
        }
    }
}
