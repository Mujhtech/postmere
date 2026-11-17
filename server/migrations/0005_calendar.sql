-- Calendar access is an explicit second OAuth grant, never inferred from mail.
ALTER TABLE provider_accounts ADD COLUMN capabilities TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE mail_oauth_connections ADD COLUMN requested_calendar BOOLEAN NOT NULL DEFAULT false;

CREATE TABLE calendar_sharing (
    account_id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    email TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT false,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (workspace_id,user_id,account_id) REFERENCES provider_accounts(workspace_id,user_id,id) ON DELETE CASCADE
);
ALTER TABLE calendar_sharing ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_sharing FORCE ROW LEVEL SECURITY;
CREATE POLICY calendar_sharing_read ON calendar_sharing FOR SELECT USING (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
    AND (user_id = nullif(current_setting('postmere.user_id',true),'')::uuid OR enabled)
);
CREATE POLICY calendar_sharing_write ON calendar_sharing FOR ALL USING (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
    AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid
) WITH CHECK (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
    AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid
);

CREATE TABLE calendar_booking_links (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id UUID NOT NULL,
    token_hash BYTEA NOT NULL CHECK (octet_length(token_hash)=32),
    encrypted_token BYTEA NOT NULL,
    title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 160),
    description TEXT NOT NULL DEFAULT '' CHECK (length(description)<=2000),
    time_zone TEXT NOT NULL CHECK (length(time_zone)<=100),
    duration_minutes INTEGER NOT NULL CHECK (duration_minutes BETWEEN 15 AND 240),
    expires_at TIMESTAMPTZ NOT NULL,
    disabled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workspace_id,user_id,id),
    UNIQUE (workspace_id,user_id,account_id,id),
    FOREIGN KEY (workspace_id,user_id,account_id) REFERENCES provider_accounts(workspace_id,user_id,id) ON DELETE CASCADE
);
CREATE TABLE calendar_booking_slots (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id UUID NOT NULL,
    link_id UUID NOT NULL,
    starts_at TIMESTAMPTZ NOT NULL,
    ends_at TIMESTAMPTZ NOT NULL,
    UNIQUE (link_id,starts_at),
    UNIQUE (workspace_id,user_id,account_id,link_id,id),
    FOREIGN KEY (workspace_id,user_id,account_id,link_id) REFERENCES calendar_booking_links(workspace_id,user_id,account_id,id) ON DELETE CASCADE,
    CHECK (ends_at>starts_at AND ends_at<=starts_at+interval '4 hours')
);
CREATE TABLE calendar_bookings (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id UUID NOT NULL,
    link_id UUID NOT NULL,
    slot_id UUID NOT NULL,
    client_id UUID NOT NULL,
    payload_hash BYTEA NOT NULL CHECK (octet_length(payload_hash)=32),
    encrypted_guest BYTEA NOT NULL,
    starts_at TIMESTAMPTZ NOT NULL,
    ends_at TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('checking','creating','confirmed','failed','uncertain')),
    provider_event_id TEXT,
    error_code TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (link_id,client_id),
    FOREIGN KEY (workspace_id,user_id,account_id,link_id,slot_id) REFERENCES calendar_booking_slots(workspace_id,user_id,account_id,link_id,id) ON DELETE CASCADE,
    CHECK (ends_at>starts_at)
);
CREATE INDEX calendar_bookings_conflicts ON calendar_bookings(account_id,starts_at,ends_at) WHERE status<>'failed';
CREATE INDEX calendar_bookings_owner ON calendar_bookings(workspace_id,user_id,created_at DESC);

DO $$ DECLARE table_name TEXT; BEGIN
    FOREACH table_name IN ARRAY ARRAY['calendar_booking_links','calendar_booking_slots','calendar_bookings'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',table_name);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY',table_name);
        EXECUTE format('CREATE POLICY calendar_owner_scope ON %I USING (workspace_id = nullif(current_setting(''postmere.workspace_id'',true),'''')::uuid AND user_id = nullif(current_setting(''postmere.user_id'',true),'''')::uuid) WITH CHECK (workspace_id = nullif(current_setting(''postmere.workspace_id'',true),'''')::uuid AND user_id = nullif(current_setting(''postmere.user_id'',true),'''')::uuid)',table_name);
    END LOOP;
END $$;
