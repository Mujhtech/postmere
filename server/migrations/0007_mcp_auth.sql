-- Authentication records, like sessions, must be readable before a tenant is
-- known. They contain token hashes and identity bindings, never mailbox data.
-- All authenticated lookups join the live session/membership/workspace state.
CREATE TABLE mcp_oauth_clients (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
    redirect_uris TEXT[] NOT NULL CHECK (cardinality(redirect_uris) BETWEEN 1 AND 8),
    auth_method TEXT NOT NULL CHECK (auth_method IN ('none','client_secret_basic')),
    secret_hash BYTEA CHECK (secret_hash IS NULL OR octet_length(secret_hash)=32),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((auth_method='none' AND secret_hash IS NULL) OR (auth_method='client_secret_basic' AND secret_hash IS NOT NULL))
);

CREATE TABLE mcp_browser_sessions (
    token_hash BYTEA PRIMARY KEY CHECK (octet_length(token_hash)=32),
    session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    csrf_token TEXT NOT NULL CHECK (length(csrf_token)=43),
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX mcp_browser_expiry ON mcp_browser_sessions(expires_at);

CREATE TABLE mcp_oauth_requests (
    id UUID PRIMARY KEY,
    client_id TEXT NOT NULL REFERENCES mcp_oauth_clients(id) ON DELETE CASCADE,
    redirect_uri TEXT NOT NULL,
    resource TEXT NOT NULL,
    scopes TEXT[] NOT NULL,
    state TEXT NOT NULL,
    code_challenge TEXT NOT NULL CHECK (length(code_challenge)=43),
    session_id UUID REFERENCES sessions(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX mcp_oauth_requests_expiry ON mcp_oauth_requests(expires_at);

CREATE TABLE mcp_oauth_grants (
    id UUID PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    client_id TEXT NOT NULL REFERENCES mcp_oauth_clients(id) ON DELETE CASCADE,
    resource TEXT NOT NULL,
    scopes TEXT[] NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX mcp_oauth_grants_session ON mcp_oauth_grants(session_id);
CREATE TABLE mcp_oauth_codes (
    token_hash BYTEA PRIMARY KEY CHECK (octet_length(token_hash)=32),
    grant_id UUID NOT NULL REFERENCES mcp_oauth_grants(id) ON DELETE CASCADE,
    redirect_uri TEXT NOT NULL,
    code_challenge TEXT NOT NULL CHECK (length(code_challenge)=43),
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ
);
CREATE TABLE mcp_access_tokens (
    token_hash BYTEA PRIMARY KEY CHECK (octet_length(token_hash)=32),
    grant_id UUID NOT NULL REFERENCES mcp_oauth_grants(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX mcp_access_grant ON mcp_access_tokens(grant_id);
CREATE TABLE mcp_refresh_tokens (
    token_hash BYTEA PRIMARY KEY CHECK (octet_length(token_hash)=32),
    grant_id UUID NOT NULL REFERENCES mcp_oauth_grants(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ
);
CREATE INDEX mcp_refresh_grant ON mcp_refresh_tokens(grant_id);
