-- Sender rules contain private email addresses. Keep them out of plaintext
-- settings; application AEAD binds each policy to workspace/user/device/account.
ALTER TABLE push_preferences ADD COLUMN encrypted_sender_policy BYTEA;
ALTER TABLE push_preferences ADD CONSTRAINT push_sender_policy_envelope_size
    CHECK (encrypted_sender_policy IS NULL OR octet_length(encrypted_sender_policy) BETWEEN 36 AND 1048612);
