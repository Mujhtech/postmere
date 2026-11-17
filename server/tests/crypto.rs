mod common;
use postmere_core::crypto::CredentialCipher;
use uuid::Uuid;
use zeroize::Zeroizing;

#[test]
fn envelopes_bind_workspace_and_account_detect_tampering_and_rotate_keys() {
    let config = common::config(String::new());
    let cipher = CredentialCipher::from_config(&config).unwrap();
    let workspace = Uuid::new_v4();
    let account = Uuid::new_v4();
    let payload = b"a provider refresh token";
    let sealed = cipher.seal(workspace, account, payload).unwrap();
    assert_ne!(
        sealed,
        cipher.seal(workspace, account, payload).unwrap(),
        "nonces must be fresh"
    );
    assert_eq!(
        cipher.open(workspace, account, &sealed).unwrap().as_slice(),
        payload
    );
    assert!(cipher.open(Uuid::new_v4(), account, &sealed).is_err());
    assert!(cipher.open(workspace, Uuid::new_v4(), &sealed).is_err());
    for index in [0, 4, 8, 20, sealed.len() - 1] {
        let mut corrupt = sealed.clone();
        corrupt[index] ^= 1;
        assert!(cipher.open(workspace, account, &corrupt).is_err());
    }
    for len in [0, 3, 20, 35] {
        assert!(cipher.open(workspace, account, &sealed[..len]).is_err());
    }
    let mut rotated = config.clone();
    rotated
        .credential_keys
        .insert(2, Zeroizing::new(vec![8; 32]));
    rotated.active_credential_key = 2;
    let rotated_cipher = CredentialCipher::from_config(&rotated).unwrap();
    assert_eq!(
        rotated_cipher
            .open(workspace, account, &sealed)
            .unwrap()
            .as_slice(),
        payload
    );
    let new = rotated_cipher.seal(workspace, account, payload).unwrap();
    assert_eq!(&new[4..8], &2u32.to_be_bytes());
    assert!(cipher.open(workspace, account, &new).is_err());
    rotated.credential_keys.remove(&1);
    assert!(
        CredentialCipher::from_config(&rotated)
            .unwrap()
            .open(workspace, account, &sealed)
            .is_err()
    );
}
