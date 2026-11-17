//! Mail account ownership, OAuth, synchronization, and durable delivery.
//! The mail and sync modules share transactional locks and remain one crate.

pub mod mail;
pub mod mail_sync;
