-- Live Activities that show what a connected assistant is doing on the user's
-- iPhone, updated over APNs while the app is closed.

-- The device's push-to-start token: lets the server begin an activity when an
-- assistant starts working and no activity is showing yet.
CREATE TABLE live_activity_start_tokens (
    device_id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    token_id UUID NOT NULL,
    encrypted_token BYTEA NOT NULL,
    token_hash BYTEA NOT NULL CHECK (octet_length(token_hash)=32),
    registered_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY(workspace_id,user_id,device_id) REFERENCES push_devices(workspace_id,user_id,id) ON DELETE CASCADE
);

-- One activity per device and assistant grant. The update token arrives from
-- the device once the activity exists; until then only a start can be sent.
CREATE TABLE assistant_live_activities (
    device_id UUID NOT NULL,
    grant_id UUID NOT NULL REFERENCES mcp_oauth_grants(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    token_id UUID,
    encrypted_token BYTEA,
    token_hash BYTEA CHECK (token_hash IS NULL OR octet_length(token_hash)=32),
    tool TEXT NOT NULL CHECK (length(tool) BETWEEN 1 AND 64),
    recent TEXT[] NOT NULL DEFAULT '{}' CHECK (cardinality(recent) <= 3),
    calls INT NOT NULL DEFAULT 1 CHECK (calls > 0),
    started_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    last_event_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    last_pushed_at TIMESTAMPTZ,
    start_sent_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    PRIMARY KEY(device_id,grant_id),
    CHECK ((token_id IS NULL) = (encrypted_token IS NULL) AND (token_id IS NULL) = (token_hash IS NULL)),
    FOREIGN KEY(workspace_id,user_id,device_id) REFERENCES push_devices(workspace_id,user_id,id) ON DELETE CASCADE
);

DO $$ DECLARE table_name TEXT; BEGIN
    FOREACH table_name IN ARRAY ARRAY['live_activity_start_tokens','assistant_live_activities'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',table_name);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY',table_name);
        EXECUTE format('CREATE POLICY tenant_user_scope ON %I USING (workspace_id=nullif(current_setting(''postmere.workspace_id'',true),'''')::uuid AND user_id=nullif(current_setting(''postmere.user_id'',true),'''')::uuid) WITH CHECK (workspace_id=nullif(current_setting(''postmere.workspace_id'',true),'''')::uuid AND user_id=nullif(current_setting(''postmere.user_id'',true),'''')::uuid)',table_name);
    END LOOP;
END $$;

-- Like the other wakeup queues: identifiers only. The worker reads each
-- activity inside its owner's row-level-security scope.
CREATE TABLE assistant_live_activity_wakeups (
    device_id UUID NOT NULL,
    grant_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    due_at TIMESTAMPTZ NOT NULL,
    lease_until TIMESTAMPTZ,
    PRIMARY KEY(device_id,grant_id),
    FOREIGN KEY(device_id,grant_id) REFERENCES assistant_live_activities(device_id,grant_id) ON DELETE CASCADE
);
CREATE INDEX assistant_live_activity_due ON assistant_live_activity_wakeups(due_at,lease_until);
