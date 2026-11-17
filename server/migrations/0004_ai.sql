CREATE TABLE ai_preferences (
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT false,
    style_guide TEXT NOT NULL DEFAULT '' CHECK (length(style_guide) <= 1000),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, user_id),
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id) ON DELETE CASCADE
);
ALTER TABLE ai_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_preferences FORCE ROW LEVEL SECURITY;
CREATE POLICY ai_preferences_owner ON ai_preferences
    USING (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid)
    WITH CHECK (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid);
CREATE INDEX mail_messages_search ON mail_messages USING GIN (to_tsvector('simple', search_text)) WHERE deleted_at IS NULL;
