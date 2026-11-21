-- Per-account assistant access. Requests from MCP assistants mark their
-- transaction with postmere.assistant='on'; these restrictive policies then
-- hide a hidden account, its messages and its outbox from every query in that
-- transaction. The app's own requests never set the marker and see everything.
ALTER TABLE provider_accounts ADD COLUMN hidden_from_assistants BOOLEAN NOT NULL DEFAULT false;

CREATE POLICY assistant_visible ON provider_accounts AS RESTRICTIVE
    USING (coalesce(current_setting('postmere.assistant', true), '') <> 'on' OR NOT hidden_from_assistants);

-- The subqueries read provider_accounts under the policy above, so a hidden
-- account's rows are excluded without repeating the rule.
CREATE POLICY assistant_visible ON mail_messages AS RESTRICTIVE
    USING (coalesce(current_setting('postmere.assistant', true), '') <> 'on'
           OR EXISTS (SELECT 1 FROM provider_accounts a WHERE a.id = mail_messages.account_id));
CREATE POLICY assistant_visible ON mail_outbox AS RESTRICTIVE
    USING (coalesce(current_setting('postmere.assistant', true), '') <> 'on'
           OR EXISTS (SELECT 1 FROM provider_accounts a WHERE a.id = mail_outbox.account_id));

-- What each connected assistant did and when, for Settings. Tool names only;
-- arguments and results are never recorded. Kept for seven days.
ALTER TABLE mcp_oauth_grants ADD COLUMN last_used_at TIMESTAMPTZ;
CREATE TABLE mcp_activity (
    id BIGSERIAL PRIMARY KEY,
    grant_id UUID NOT NULL REFERENCES mcp_oauth_grants(id) ON DELETE CASCADE,
    tool TEXT NOT NULL CHECK (length(tool) BETWEEN 1 AND 64),
    at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX mcp_activity_recent ON mcp_activity(grant_id, at DESC);
