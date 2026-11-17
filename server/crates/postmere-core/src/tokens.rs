//! Random and scoped nonce tokens shared by mail, tracking, and bookings.
//! Parsed identifiers alone never establish authentication; callers must verify
//! the nonce hash and recheck current access within the scoped transaction.
use crate::error::AppError;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub fn random_token() -> Result<String, AppError> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| AppError::internal("secure_random"))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}
pub fn token_hash(token: &str) -> Vec<u8> {
    Sha256::digest(token.as_bytes()).to_vec()
}
pub fn scoped_token(workspace: Uuid, user: Uuid, id: Uuid) -> Result<String, AppError> {
    Ok(format!("{workspace}.{user}.{id}.{}", random_token()?))
}
pub fn parse_scoped_token(token: &str) -> Result<(Uuid, Uuid, Uuid), AppError> {
    if token.len() > 256 {
        return Err(AppError::not_found());
    }
    let parts: Vec<_> = token.split('.').collect();
    if parts.len() != 4
        || URL_SAFE_NO_PAD
            .decode(parts[3])
            .map(|b| b.len() != 32)
            .unwrap_or(true)
    {
        return Err(AppError::not_found());
    }
    Ok((
        parts[0].parse().map_err(|_| AppError::not_found())?,
        parts[1].parse().map_err(|_| AppError::not_found())?,
        parts[2].parse().map_err(|_| AppError::not_found())?,
    ))
}
