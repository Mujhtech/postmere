-- A browser sign-in and an assistant authorization have separate lifetimes.
-- Each grant owns a session so revocation can use the normal identity locks,
-- without deadlocking a tool which already holds a grant lock.
ALTER TABLE sessions ADD COLUMN kind TEXT NOT NULL DEFAULT 'native'
    CHECK (kind IN ('native','mcp_browser','mcp_grant'));
UPDATE sessions s SET kind='mcp_browser'
WHERE EXISTS (SELECT 1 FROM mcp_browser_sessions b WHERE b.session_id=s.id)
   OR EXISTS (SELECT 1 FROM mcp_oauth_grants g WHERE g.session_id=s.id);
ALTER TABLE mcp_oauth_grants ALTER COLUMN expires_at DROP NOT NULL;
ALTER TABLE mcp_refresh_tokens ALTER COLUMN expires_at DROP NOT NULL;

-- Upgrade active authorizations only. Expired/revoked credentials stay invalid.
DO $$
DECLARE item RECORD; grant_session UUID;
BEGIN
    FOR item IN
        SELECT g.id, s.workspace_id, s.user_id, g.created_at
        FROM mcp_oauth_grants g
        JOIN sessions s ON s.id=g.session_id
        JOIN memberships m ON m.workspace_id=s.workspace_id AND m.user_id=s.user_id
        JOIN users u ON u.id=s.user_id JOIN workspaces w ON w.id=s.workspace_id
        WHERE g.revoked_at IS NULL AND g.expires_at>clock_timestamp()
          AND s.revoked_at IS NULL AND s.replaced_by IS NULL
          AND (s.expires_at IS NULL OR s.expires_at>clock_timestamp())
          AND (s.absolute_expires_at IS NULL OR s.absolute_expires_at>clock_timestamp())
          AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL
    LOOP
        grant_session := gen_random_uuid();
        INSERT INTO sessions(id,workspace_id,user_id,token_hash,created_at,expires_at,absolute_expires_at,kind)
        VALUES(grant_session,item.workspace_id,item.user_id,
            decode(replace(gen_random_uuid()::text || gen_random_uuid()::text,'-',''),'hex'),
            item.created_at,NULL,NULL,'mcp_grant');
        UPDATE mcp_oauth_grants SET session_id=grant_session,expires_at=NULL WHERE id=item.id;
        UPDATE mcp_refresh_tokens SET expires_at=NULL
        WHERE grant_id=item.id AND used_at IS NULL AND expires_at>clock_timestamp();
    END LOOP;
END $$;
CREATE INDEX sessions_mcp_signout ON sessions(user_id,workspace_id,created_at)
    WHERE kind IN ('mcp_browser','mcp_grant') AND revoked_at IS NULL;
