use crate::{config::Config, error::AppError};
use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use std::collections::BTreeMap;
use uuid::Uuid;
use zeroize::Zeroizing;

/// Versioned AEAD envelope: magic (4), key id (4), nonce (12), ciphertext/tag.
/// Workspace and resource IDs form the AAD, preventing ciphertext transplantation.
pub struct CredentialCipher {
    keys: BTreeMap<u32, Aes256Gcm>,
    active: u32,
}
impl CredentialCipher {
    pub fn from_config(config: &Config) -> Result<Self, AppError> {
        let mut keys = BTreeMap::new();
        for (&version, key) in &config.credential_keys {
            keys.insert(
                version,
                Aes256Gcm::new_from_slice(key)
                    .map_err(|_| AppError::internal("invalid_encryption_key"))?,
            );
        }
        if !keys.contains_key(&config.active_credential_key) {
            return Err(AppError::internal("missing_active_key"));
        }
        Ok(Self {
            keys,
            active: config.active_credential_key,
        })
    }
    pub fn seal(
        &self,
        workspace_id: Uuid,
        account_id: Uuid,
        plaintext: &[u8],
    ) -> Result<Vec<u8>, AppError> {
        if plaintext.len() > 1024 * 1024 {
            return Err(AppError::bad_request("Credential payload is too large."));
        }
        let mut nonce = [0u8; 12];
        getrandom::fill(&mut nonce).map_err(|_| AppError::internal("secure_random"))?;
        let mut result = b"PME1".to_vec();
        result.extend_from_slice(&self.active.to_be_bytes());
        result.extend_from_slice(&nonce);
        let aad = aad(workspace_id, account_id, &result[..8]);
        let encrypted = self.keys[&self.active]
            .encrypt(
                &Nonce::from(nonce),
                Payload {
                    msg: plaintext,
                    aad: &aad,
                },
            )
            .map_err(|_| AppError::internal("credential_encryption"))?;
        result.extend(encrypted);
        Ok(result)
    }
    pub fn open(
        &self,
        workspace_id: Uuid,
        account_id: Uuid,
        encrypted: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>, AppError> {
        if encrypted.len() < 36 || encrypted.len() > 1024 * 1024 + 36 || &encrypted[..4] != b"PME1"
        {
            return Err(AppError::internal("invalid_credential_envelope"));
        }
        let version = u32::from_be_bytes(encrypted[4..8].try_into().unwrap());
        let key = self
            .keys
            .get(&version)
            .ok_or_else(|| AppError::internal("credential_key_unavailable"))?;
        let nonce: [u8; 12] = encrypted[8..20].try_into().unwrap();
        let aad = aad(workspace_id, account_id, &encrypted[..8]);
        key.decrypt(
            &Nonce::from(nonce),
            Payload {
                msg: &encrypted[20..],
                aad: &aad,
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| AppError::internal("credential_decryption"))
    }
}
fn aad(workspace_id: Uuid, account_id: Uuid, header: &[u8]) -> Vec<u8> {
    [
        b"postmere.credentials.v1:".as_slice(),
        header,
        workspace_id.as_bytes(),
        account_id.as_bytes(),
    ]
    .concat()
}
