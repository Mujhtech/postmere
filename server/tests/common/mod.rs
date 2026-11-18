use postmere_core::config::Config;
use std::collections::BTreeMap;
use zeroize::Zeroizing;

pub fn config(database_url: String) -> Config {
    let mut rate_key = vec![0u8; 32];
    getrandom::fill(&mut rate_key).unwrap();
    Config {
        database_url,
        bind_addr: "127.0.0.1:0".parse().unwrap(),
        public_base_url: "http://127.0.0.1:8080".parse().unwrap(),
        mcp_redirect_uris: Vec::new(),
        max_body_bytes: 30 * 1024 * 1024,
        session_hours: 24,
        session_absolute_days: 30,
        credential_keys: BTreeMap::from([(1, Zeroizing::new(vec![7u8; 32]))]),
        active_credential_key: 1,
        rate_limit_key: Zeroizing::new(rate_key),
        google_client_id: None,
        google_client_secret: None,
        microsoft_client_id: None,
        microsoft_client_secret: None,
        microsoft_tenant: "common".into(),
        ai_api_key: None,
        ai_model: "test-disabled".into(),
    }
}
