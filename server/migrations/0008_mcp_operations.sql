-- Mail drafts and exact, actor-bound browser approvals for remote assistants.
-- Content is encrypted; only bounded scheduling/identity metadata is indexed.
CREATE TABLE mcp_mail_drafts (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    request_id UUID NOT NULL,
    creation_hash BYTEA NOT NULL CHECK (octet_length(creation_hash)=32),
    encrypted_content BYTEA NOT NULL,
    version BIGINT NOT NULL DEFAULT 1 CHECK (version>0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(workspace_id,user_id,request_id),
    FOREIGN KEY(workspace_id,user_id) REFERENCES memberships(workspace_id,user_id) ON DELETE CASCADE
);
CREATE INDEX mcp_drafts_page ON mcp_mail_drafts(workspace_id,user_id,updated_at DESC,id);

CREATE TABLE mcp_mail_approvals (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    request_id UUID NOT NULL,
    request_hash BYTEA NOT NULL CHECK(octet_length(request_hash)=32),
    kind TEXT NOT NULL CHECK(kind IN ('send_draft','trash_message','disconnect_account')),
    encrypted_payload BYTEA NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','executing','completed','cancelled','expired','failed','uncertain')),
    result JSONB,
    error_code TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(workspace_id,user_id,request_id),
    FOREIGN KEY(workspace_id,user_id) REFERENCES memberships(workspace_id,user_id) ON DELETE CASCADE,
    CHECK(expires_at>created_at)
);
CREATE INDEX mcp_approvals_page ON mcp_mail_approvals(workspace_id,user_id,created_at DESC,id);

DO $$ DECLARE table_name TEXT; BEGIN
    FOREACH table_name IN ARRAY ARRAY['mcp_mail_drafts','mcp_mail_approvals'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',table_name);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY',table_name);
        EXECUTE format('CREATE POLICY tenant_user_scope ON %I USING (workspace_id=nullif(current_setting(''postmere.workspace_id'',true),'''')::uuid AND user_id=nullif(current_setting(''postmere.user_id'',true),'''')::uuid) WITH CHECK (workspace_id=nullif(current_setting(''postmere.workspace_id'',true),'''')::uuid AND user_id=nullif(current_setting(''postmere.user_id'',true),'''')::uuid)',table_name);
    END LOOP;
END $$;
