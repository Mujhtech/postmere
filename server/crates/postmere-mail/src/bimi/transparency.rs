//! Verify a v1 embedded SCT over the RFC 6962 precertificate entry.
use ring::signature::{ECDSA_P256_SHA256_ASN1, UnparsedPublicKey};
use sha2::{Digest, Sha256};
use x509_cert::{
    Certificate, TbsCertificate,
    der::{Decode, Encode, asn1::ObjectIdentifier},
    ext::pkix::{HashAlgorithm, SignatureAlgorithm, SignedCertificateTimestampList},
    spki::SubjectPublicKeyInfoOwned,
};

// https://gorgon.ct.digicert.com/log, the BIMI log listed for our pinned MVAs.
// The SPKI is checked against the log ID in the SCT, and its P-256 public key
// authenticates the signed entry. It also signs the log's public tree heads.
const GORGON: &[u8] = include_bytes!("gorgon.spki");
const SCT_LIST: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.3.6.1.4.1.11129.2.4.2");

pub(super) fn verified(
    leaf: &TbsCertificate,
    issuer: &Certificate,
    now: chrono::DateTime<chrono::Utc>,
) -> bool {
    let Ok(Some((_, list))) = leaf.get::<SignedCertificateTimestampList>() else {
        return false;
    };
    let Ok(timestamps) = list.parse_timestamps() else {
        return false;
    };
    let mut tbs = leaf.clone();
    let Some(extensions) = tbs.extensions.as_mut() else {
        return false;
    };
    extensions.retain(|e| e.extn_id != SCT_LIST);
    let Ok(tbs_der) = tbs.to_der() else {
        return false;
    };
    let Ok(issuer_der) = issuer.tbs_certificate.subject_public_key_info.to_der() else {
        return false;
    };
    let Ok(log_key) = SubjectPublicKeyInfoOwned::from_der(GORGON) else {
        return false;
    };
    let Some(point) = log_key.subject_public_key.as_bytes() else {
        return false;
    };
    let issuer_hash = Sha256::digest(issuer_der);
    let log_id: [u8; 32] = Sha256::digest(GORGON).into();
    let Ok(now) = u64::try_from(now.timestamp_millis()) else {
        return false;
    };
    timestamps
        .iter()
        .filter_map(|s| s.parse_timestamp().ok())
        .any(|s| {
            if s.log_id.key_id != log_id
                || s.timestamp > now
                || s.signature.algorithm.hash != HashAlgorithm::Sha256
                || s.signature.algorithm.signature != SignatureAlgorithm::Ecdsa
            {
                return false;
            }
            let mut input = Vec::with_capacity(47 + tbs_der.len() + s.extensions.as_slice().len());
            input.extend_from_slice(&[0, 0]); // version, certificate_timestamp
            input.extend_from_slice(&s.timestamp.to_be_bytes());
            input.extend_from_slice(&[0, 1]); // precert_entry
            input.extend_from_slice(&issuer_hash);
            input.extend_from_slice(&(tbs_der.len() as u32).to_be_bytes()[1..]);
            input.extend_from_slice(&tbs_der);
            input.extend_from_slice(&(s.extensions.as_slice().len() as u16).to_be_bytes());
            input.extend_from_slice(s.extensions.as_slice());
            UnparsedPublicKey::new(&ECDSA_P256_SHA256_ASN1, point)
                .verify(&input, s.signature.signature.as_slice())
                .is_ok()
        })
}
