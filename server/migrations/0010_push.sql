-- Alert pushes are session-bound, opt-in per device/account, and never a mail
-- transport. Tokens use the existing credential AEAD; wakeups contain IDs only.
ALTER TABLE provider_accounts ADD COLUMN push_connected_at TIMESTAMPTZ NOT NULL DEFAULT now();
CREATE FUNCTION reset_postmere_push_cutoff() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (OLD.disabled_at IS NOT NULL AND NEW.disabled_at IS NULL)
       OR (OLD.status <> 'connected' AND NEW.status = 'connected') THEN
        NEW.push_connected_at := clock_timestamp();
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER provider_push_cutoff BEFORE UPDATE ON provider_accounts
    FOR EACH ROW EXECUTE FUNCTION reset_postmere_push_cutoff();

CREATE TABLE push_devices (
    id UUID PRIMARY KEY,
    installation_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    encrypted_token BYTEA NOT NULL,
    token_hash BYTEA NOT NULL CHECK (octet_length(token_hash)=32),
    environment TEXT NOT NULL CHECK (environment IN ('sandbox','production')),
    enabled BOOLEAN NOT NULL,
    first_registered_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    registered_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    disabled_at TIMESTAMPTZ,
    UNIQUE(workspace_id,user_id,installation_id),
    UNIQUE(workspace_id,user_id,id),
    FOREIGN KEY(workspace_id,user_id) REFERENCES memberships(workspace_id,user_id) ON DELETE CASCADE
);
CREATE TABLE push_preferences (
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    account_id UUID NOT NULL,
    enabled BOOLEAN NOT NULL,
    enabled_since TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    settings JSONB NOT NULL,
    PRIMARY KEY(device_id,account_id),
    FOREIGN KEY(workspace_id,user_id,device_id) REFERENCES push_devices(workspace_id,user_id,id) ON DELETE CASCADE,
    FOREIGN KEY(workspace_id,user_id,account_id) REFERENCES provider_accounts(workspace_id,user_id,id) ON DELETE CASCADE
);
-- A physical APNs token has one latest installation binding across workspaces.
-- This table has no token, mail content or readable user identity. It prevents
-- a failed old-session DELETE from leaking alerts after an account switch.
CREATE TABLE push_token_bindings (
    token_hash BYTEA NOT NULL CHECK(octet_length(token_hash)=32),
    environment TEXT NOT NULL CHECK(environment IN ('sandbox','production')),
    device_id UUID NOT NULL REFERENCES push_devices(id) ON DELETE CASCADE,
    PRIMARY KEY(token_hash,environment)
);
CREATE TABLE push_deliveries (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    message_id UUID NOT NULL REFERENCES mail_messages(id) ON DELETE CASCADE,
    account_id UUID NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','sending','accepted','rejected','uncertain','cancelled')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    expires_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(device_id,message_id),
    FOREIGN KEY(workspace_id,user_id,device_id) REFERENCES push_devices(workspace_id,user_id,id) ON DELETE CASCADE,
    FOREIGN KEY(workspace_id,user_id,account_id) REFERENCES provider_accounts(workspace_id,user_id,id) ON DELETE CASCADE
);
CREATE TABLE push_delivery_wakeups (
    job_id UUID PRIMARY KEY REFERENCES push_deliveries(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    due_at TIMESTAMPTZ NOT NULL,
    lease_until TIMESTAMPTZ
);
CREATE INDEX push_delivery_due ON push_delivery_wakeups(due_at,lease_until);
DO $$ DECLARE table_name TEXT; BEGIN
    FOREACH table_name IN ARRAY ARRAY['push_devices','push_preferences','push_deliveries'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',table_name);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY',table_name);
        EXECUTE format('CREATE POLICY tenant_user_scope ON %I USING (workspace_id=nullif(current_setting(''postmere.workspace_id'',true),'''')::uuid AND user_id=nullif(current_setting(''postmere.user_id'',true),'''')::uuid) WITH CHECK (workspace_id=nullif(current_setting(''postmere.workspace_id'',true),'''')::uuid AND user_id=nullif(current_setting(''postmere.user_id'',true),'''')::uuid)',table_name);
    END LOOP;
END $$;

CREATE FUNCTION queue_postmere_mail_push() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Only a new incoming unread Inbox row can cause an alert. Updates, search
    -- replays, draft/Sent imports and messages predating consent are silent.
    IF NEW.deleted_at IS NOT NULL OR NEW.normalized->>'mailbox' IS DISTINCT FROM 'inbox'
       OR NEW.normalized->>'is_read' IS DISTINCT FROM 'false'
       OR NEW.sent_at > clock_timestamp()+interval '5 minutes' THEN RETURN NEW; END IF;
    WITH inserted AS (
      INSERT INTO push_deliveries(id,workspace_id,user_id,device_id,message_id,account_id,expires_at)
      SELECT gen_random_uuid(),NEW.workspace_id,NEW.user_id,d.id,NEW.id,NEW.account_id,
             least(s.expires_at,s.absolute_expires_at,NEW.sent_at+interval '24 hours')
      FROM push_devices d
      JOIN push_preferences p ON p.device_id=d.id AND p.account_id=NEW.account_id
      JOIN provider_accounts a ON a.id=p.account_id
      JOIN sessions s ON s.id=d.session_id AND s.user_id=d.user_id AND s.workspace_id=d.workspace_id
      JOIN users u ON u.id=d.user_id
      JOIN memberships m ON m.user_id=d.user_id AND m.workspace_id=d.workspace_id
      JOIN workspaces w ON w.id=d.workspace_id
      WHERE d.workspace_id=NEW.workspace_id AND d.user_id=NEW.user_id
        AND d.enabled AND d.disabled_at IS NULL AND p.enabled
        AND a.disabled_at IS NULL AND a.status='connected'
        AND lower(NEW.normalized->'from'->>'email') <> lower(a.email)
        AND NEW.sent_at >= greatest(d.first_registered_at,p.enabled_since,a.push_connected_at)
        AND s.revoked_at IS NULL AND s.expires_at>clock_timestamp() AND s.absolute_expires_at>clock_timestamp()
        AND u.disabled_at IS NULL AND m.revoked_at IS NULL AND w.disabled_at IS NULL
        AND NEW.sent_at+interval '24 hours'>clock_timestamp()
      ON CONFLICT(device_id,message_id) DO NOTHING
      RETURNING id,workspace_id,user_id
    )
    INSERT INTO push_delivery_wakeups(job_id,workspace_id,user_id,due_at)
      SELECT id,workspace_id,user_id,clock_timestamp() FROM inserted;
    RETURN NEW;
END $$;
CREATE TRIGGER mail_push_insert AFTER INSERT ON mail_messages
    FOR EACH ROW EXECUTE FUNCTION queue_postmere_mail_push();
