ALTER TABLE provider_accounts ADD COLUMN display_name TEXT;
ALTER TABLE provider_accounts ADD COLUMN status TEXT NOT NULL DEFAULT 'connected'
    CHECK (status IN ('connected', 'reconnect_required'));
ALTER TABLE provider_accounts ADD COLUMN last_synced_at TIMESTAMPTZ;
ALTER TABLE provider_accounts ADD COLUMN sync_cursor TEXT;
ALTER TABLE provider_accounts ADD CONSTRAINT provider_accounts_user_identity UNIQUE (workspace_id,user_id,id);

CREATE TABLE mail_oauth_connections (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    provider TEXT NOT NULL CHECK (provider IN ('gmail', 'microsoft')),
    state_hash BYTEA NOT NULL CHECK (octet_length(state_hash) = 32),
    encrypted_verifier BYTEA NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'exchanging', 'connected', 'failed')),
    account_id UUID,
    error_code TEXT,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id, user_id, account_id) REFERENCES provider_accounts(workspace_id, user_id, id) ON DELETE CASCADE
);

CREATE TABLE mail_messages (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id UUID NOT NULL,
    provider_message_id TEXT NOT NULL,
    provider_thread_id TEXT NOT NULL,
    sent_at TIMESTAMPTZ NOT NULL,
    normalized JSONB NOT NULL,
    search_text TEXT NOT NULL,
    deleted_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, account_id, provider_message_id),
    FOREIGN KEY (workspace_id, user_id, account_id) REFERENCES provider_accounts(workspace_id, user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id) ON DELETE CASCADE
);
CREATE INDEX mail_messages_page ON mail_messages(workspace_id, user_id, sent_at DESC, id DESC) WHERE deleted_at IS NULL;
CREATE INDEX mail_messages_account_page ON mail_messages(workspace_id, account_id, sent_at DESC, id DESC) WHERE deleted_at IS NULL;

CREATE TABLE mail_outbox (
    id UUID PRIMARY KEY,
    client_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id UUID NOT NULL,
    encrypted_payload BYTEA NOT NULL,
    payload_hash BYTEA NOT NULL CHECK (octet_length(payload_hash) = 32),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'delivering', 'sent', 'failed', 'uncertain', 'cancelled')),
    scheduled_at TIMESTAMPTZ NOT NULL,
    undo_until TIMESTAMPTZ NOT NULL,
    claimed_at TIMESTAMPTZ,
    provider_message_id TEXT,
    error_code TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, user_id, id),
    UNIQUE (workspace_id, user_id, client_id),
    FOREIGN KEY (workspace_id, user_id, account_id) REFERENCES provider_accounts(workspace_id, user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id) ON DELETE CASCADE,
    CHECK (scheduled_at >= undo_until)
);
CREATE INDEX mail_outbox_tenant ON mail_outbox(workspace_id,user_id,created_at DESC);

-- Contains scheduling identifiers only, never credentials, recipients or body.
-- The worker claims this index then opens an RLS-scoped transaction and verifies
-- the active membership/account before reading or delivering a message.
CREATE TABLE mail_delivery_wakeups (
    job_id UUID PRIMARY KEY REFERENCES mail_outbox(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    due_at TIMESTAMPTZ NOT NULL,
    lease_until TIMESTAMPTZ
);
CREATE INDEX mail_delivery_due ON mail_delivery_wakeups(due_at,lease_until);

CREATE TABLE mail_tracking_links (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    outbox_id UUID NOT NULL,
    token_hash BYTEA NOT NULL CHECK (octet_length(token_hash) = 32),
    kind TEXT NOT NULL CHECK (kind IN ('open', 'click')),
    destination TEXT,
    recipient TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (workspace_id, user_id, outbox_id) REFERENCES mail_outbox(workspace_id,user_id,id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id,user_id) ON DELETE CASCADE
);
CREATE TABLE mail_tracking_events (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    outbox_id UUID NOT NULL,
    link_id UUID NOT NULL REFERENCES mail_tracking_links(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('open', 'click')),
    recipient TEXT,
    device TEXT NOT NULL,
    is_proxy_or_bot BOOLEAN NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (workspace_id, user_id, outbox_id) REFERENCES mail_outbox(workspace_id,user_id,id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id,user_id) ON DELETE CASCADE
);
CREATE INDEX mail_tracking_activity ON mail_tracking_events(workspace_id,user_id,outbox_id,occurred_at DESC);

DO $$ DECLARE table_name TEXT; BEGIN
    FOREACH table_name IN ARRAY ARRAY['mail_oauth_connections','mail_messages','mail_outbox','mail_tracking_links','mail_tracking_events'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', table_name);
        EXECUTE format('CREATE POLICY tenant_user_scope ON %I USING (workspace_id = nullif(current_setting(''postmere.workspace_id'',true),'''')::uuid AND user_id = nullif(current_setting(''postmere.user_id'',true),'''')::uuid) WITH CHECK (workspace_id = nullif(current_setting(''postmere.workspace_id'',true),'''')::uuid AND user_id = nullif(current_setting(''postmere.user_id'',true),'''')::uuid)',table_name);
    END LOOP;
END $$;
