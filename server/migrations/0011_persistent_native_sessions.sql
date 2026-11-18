-- Native sessions last until explicit sign-out or identity revocation. Browser
-- authorization sessions retain their finite inactivity and absolute limits.
ALTER TABLE sessions
    ALTER COLUMN expires_at DROP NOT NULL,
    ALTER COLUMN absolute_expires_at DROP NOT NULL,
    DROP CONSTRAINT sessions_check,
    ADD CONSTRAINT sessions_lifetime CHECK (
        (expires_at IS NULL AND absolute_expires_at IS NULL)
        OR (expires_at IS NOT NULL AND absolute_expires_at IS NOT NULL
            AND isfinite(expires_at) AND isfinite(absolute_expires_at)
            AND expires_at <= absolute_expires_at AND expires_at > created_at)
    );

-- Upgrade only native credentials that are still valid at deployment time.
-- Expired, signed-out, replaced and browser/OAuth credentials are never revived.
UPDATE sessions s SET expires_at=NULL, absolute_expires_at=NULL
WHERE s.revoked_at IS NULL AND s.replaced_by IS NULL
    AND s.expires_at>clock_timestamp() AND s.absolute_expires_at>clock_timestamp()
    AND EXISTS (
        SELECT 1 FROM users u
        JOIN memberships m ON m.user_id=u.id
        JOIN workspaces w ON w.id=m.workspace_id
        WHERE u.id=s.user_id AND m.workspace_id=s.workspace_id
            AND u.disabled_at IS NULL AND m.revoked_at IS NULL AND w.disabled_at IS NULL
    )
    AND NOT EXISTS (SELECT 1 FROM mcp_browser_sessions b WHERE b.session_id=s.id)
    AND NOT EXISTS (SELECT 1 FROM mcp_oauth_grants g WHERE g.session_id=s.id);
