-- First-party plugins: which ones each user turned on, their settings, and a
-- seven-day log of tool calls (names and outcomes only, never content).
CREATE TABLE plugin_installs (
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    plugin_id TEXT NOT NULL CHECK (length(plugin_id) BETWEEN 1 AND 64),
    enabled BOOLEAN NOT NULL DEFAULT false,
    settings JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(settings) = 'object' AND length(settings::text) <= 4096),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, user_id, plugin_id),
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id) ON DELETE CASCADE
);
ALTER TABLE plugin_installs ENABLE ROW LEVEL SECURITY;
ALTER TABLE plugin_installs FORCE ROW LEVEL SECURITY;
CREATE POLICY plugin_installs_owner ON plugin_installs
    USING (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid)
    WITH CHECK (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid);

CREATE TABLE plugin_activity (
    id BIGSERIAL PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    plugin_id TEXT NOT NULL CHECK (length(plugin_id) BETWEEN 1 AND 64),
    tool TEXT NOT NULL CHECK (length(tool) BETWEEN 1 AND 64),
    succeeded BOOLEAN NOT NULL,
    at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id) ON DELETE CASCADE
);
ALTER TABLE plugin_activity ENABLE ROW LEVEL SECURITY;
ALTER TABLE plugin_activity FORCE ROW LEVEL SECURITY;
CREATE POLICY plugin_activity_owner ON plugin_activity
    USING (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid)
    WITH CHECK (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid);
CREATE INDEX plugin_activity_recent ON plugin_activity(workspace_id, user_id, plugin_id, at DESC);
