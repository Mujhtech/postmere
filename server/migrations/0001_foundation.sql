CREATE TABLE users (
    id UUID PRIMARY KEY,
    email TEXT NOT NULL UNIQUE CHECK (email = lower(email) AND length(email) BETWEEN 3 AND 254),
    password_hash TEXT NOT NULL,
    disabled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE workspaces (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
    disabled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE memberships (
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, user_id)
);

CREATE TABLE sessions (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    token_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    absolute_expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    replaced_by UUID REFERENCES sessions(id),
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id) ON DELETE CASCADE,
    CHECK (expires_at <= absolute_expires_at AND expires_at > created_at)
);
CREATE INDEX sessions_user_active ON sessions(user_id) WHERE revoked_at IS NULL;
CREATE INDEX sessions_expiry ON sessions(expires_at);

-- Counters contain keyed hashes of login identity/client IP, never raw addresses.
-- Shared by every server instance so restarting a process cannot bypass limits.
CREATE TABLE login_rate_limits (
    bucket BYTEA PRIMARY KEY CHECK (octet_length(bucket) = 32),
    window_started_at TIMESTAMPTZ NOT NULL,
    attempts INTEGER NOT NULL CHECK (attempts > 0),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX login_rate_limits_expiry ON login_rate_limits(expires_at);

CREATE TABLE provider_accounts (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    provider TEXT NOT NULL CHECK (length(provider) BETWEEN 1 AND 40),
    email TEXT NOT NULL CHECK (length(email) BETWEEN 3 AND 254),
    encrypted_credentials BYTEA NOT NULL CHECK (octet_length(encrypted_credentials) BETWEEN 32 AND 1048576),
    disabled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, user_id, provider, email),
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id) ON DELETE CASCADE
);

ALTER TABLE provider_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE provider_accounts FORCE ROW LEVEL SECURITY;
CREATE POLICY provider_accounts_tenant ON provider_accounts
    USING (
        workspace_id = nullif(current_setting('postmere.workspace_id', true), '')::uuid
        AND user_id = nullif(current_setting('postmere.user_id', true), '')::uuid
    )
    WITH CHECK (
        workspace_id = nullif(current_setting('postmere.workspace_id', true), '')::uuid
        AND user_id = nullif(current_setting('postmere.user_id', true), '')::uuid
    );
