ALTER TABLE mail_messages ADD COLUMN last_verified_at TIMESTAMPTZ NOT NULL DEFAULT now();
CREATE INDEX mail_messages_verification ON mail_messages(workspace_id,user_id,account_id,last_verified_at) WHERE deleted_at IS NULL;
CREATE INDEX mail_messages_changes ON mail_messages(workspace_id,user_id,account_id,updated_at,id);

CREATE TABLE mail_sync_state (
    account_id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    checkpoint JSONB NOT NULL DEFAULT '{}',
    last_error TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (workspace_id,user_id,account_id) REFERENCES provider_accounts(workspace_id,user_id,id) ON DELETE CASCADE
);
ALTER TABLE mail_sync_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE mail_sync_state FORCE ROW LEVEL SECURITY;
CREATE POLICY sync_state_scope ON mail_sync_state
    USING(workspace_id=nullif(current_setting('postmere.workspace_id',true),'')::uuid AND user_id=nullif(current_setting('postmere.user_id',true),'')::uuid)
    WITH CHECK(workspace_id=nullif(current_setting('postmere.workspace_id',true),'')::uuid AND user_id=nullif(current_setting('postmere.user_id',true),'')::uuid);

-- Identifier-only queue. Every read of credentials or mail still requires a
-- scoped transaction and a fresh active-membership/account check.
CREATE TABLE mail_sync_wakeups (
    account_id UUID PRIMARY KEY REFERENCES provider_accounts(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    due_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    lease_until TIMESTAMPTZ,
    FOREIGN KEY (workspace_id,user_id,account_id) REFERENCES provider_accounts(workspace_id,user_id,id) ON DELETE CASCADE
);
CREATE INDEX mail_sync_due ON mail_sync_wakeups(due_at,lease_until);
