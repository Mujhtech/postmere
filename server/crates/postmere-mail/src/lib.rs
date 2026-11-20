//! Mail account ownership, OAuth, synchronization, and durable delivery.
//! The mail and sync modules share transactional locks and remain one crate.

mod bimi_cert;
pub mod mail;
pub mod mail_labels;
pub mod mail_sync;
mod sender_mark;
