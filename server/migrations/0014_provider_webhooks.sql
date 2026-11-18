-- These pre-authentication routing/job records contain identifiers, one-way
-- mailbox/clientState hashes and an encrypted provider challenge. No mailbox
-- contents or plaintext credentials are accessible without tenant scope.
CREATE TABLE provider_webhooks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL UNIQUE,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    provider TEXT NOT NULL CHECK(provider IN ('gmail','microsoft')),
    mailbox_hash BYTEA NOT NULL CHECK(octet_length(mailbox_hash)=32),
    enabled BOOLEAN NOT NULL,
    generation BIGINT NOT NULL DEFAULT 1,
    provider_subscription TEXT CHECK(length(provider_subscription)<=512),
    encrypted_state BYTEA,
    state_hash BYTEA CHECK(state_hash IS NULL OR octet_length(state_hash)=32),
    expires_at TIMESTAMPTZ,
    renew_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    lease_until TIMESTAMPTZ,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    last_success_at TIMESTAMPTZ,
    gmail_history NUMERIC(20,0),
    recent_receipts JSONB NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(recent_receipts)='array' AND jsonb_array_length(recent_receipts)<=128),
    FOREIGN KEY(workspace_id,user_id,account_id) REFERENCES provider_accounts(workspace_id,user_id,id) ON DELETE CASCADE
);
CREATE INDEX provider_webhook_due ON provider_webhooks(renew_at,lease_until);
CREATE INDEX provider_webhook_mailbox ON provider_webhooks(provider,mailbox_hash);

-- A separate coalesced hint prevents a callback from waiting on a mailbox sync
-- transaction and prevents that transaction from overwriting a newer wakeup.
-- The sequence is observed before the provider read and consumed only afterward.
CREATE TABLE mail_sync_signals (
    account_id UUID PRIMARY KEY REFERENCES provider_accounts(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    generation BIGINT NOT NULL DEFAULT 1,
    due_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY(workspace_id,user_id,account_id) REFERENCES provider_accounts(workspace_id,user_id,id) ON DELETE CASCADE
);

CREATE FUNCTION schedule_postmere_provider_webhook() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' OR OLD.disabled_at IS DISTINCT FROM NEW.disabled_at OR OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO provider_webhooks(account_id,workspace_id,user_id,provider,mailbox_hash,enabled)
        VALUES(NEW.id,NEW.workspace_id,NEW.user_id,NEW.provider,sha256(convert_to(lower(NEW.email),'UTF8')),NEW.disabled_at IS NULL AND NEW.status='connected')
        ON CONFLICT(account_id) DO UPDATE SET enabled=excluded.enabled,
            generation=provider_webhooks.generation+1,renew_at=clock_timestamp(),lease_until=NULL,attempts=0;
        IF NEW.disabled_at IS NOT NULL OR NEW.status<>'connected' THEN
            DELETE FROM mail_sync_signals WHERE account_id=NEW.id;
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER provider_webhook_schedule AFTER INSERT OR UPDATE ON provider_accounts
    FOR EACH ROW EXECUTE FUNCTION schedule_postmere_provider_webhook();

-- Respect forced provider-account RLS while seeding existing accounts.
DO $$ DECLARE member RECORD; BEGIN
    FOR member IN SELECT workspace_id,user_id FROM memberships LOOP
        PERFORM set_config('postmere.workspace_id',member.workspace_id::text,true);
        PERFORM set_config('postmere.user_id',member.user_id::text,true);
        INSERT INTO provider_webhooks(account_id,workspace_id,user_id,provider,mailbox_hash,enabled)
        SELECT id,workspace_id,user_id,provider,sha256(convert_to(lower(email),'UTF8')),disabled_at IS NULL AND status='connected'
        FROM provider_accounts ON CONFLICT(account_id) DO NOTHING;
    END LOOP;
    PERFORM set_config('postmere.workspace_id','',true);
    PERFORM set_config('postmere.user_id','',true);
END $$;
