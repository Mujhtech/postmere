-- Triage suggestions: one stored suggestion per message, so opening Triage is
-- instant, and the decisions each person made, by sender, so their own habits
-- can answer before any AI is asked. Decisions keep the sender address and
-- action only, never message content, and are kept for 180 days.
CREATE TABLE mail_triage_suggestions (
    message_id UUID PRIMARY KEY REFERENCES mail_messages(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('reply','needs_reply','archive','snooze','unsubscribe','none')),
    priority TEXT NOT NULL CHECK (priority IN ('needs_you','people','fyi','bulk')),
    reason TEXT NOT NULL CHECK (length(reason) BETWEEN 1 AND 200),
    deadline DATE,
    snooze_until DATE,
    source TEXT NOT NULL CHECK (source IN ('history','rules','ai')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id) ON DELETE CASCADE
);
ALTER TABLE mail_triage_suggestions ENABLE ROW LEVEL SECURITY;
ALTER TABLE mail_triage_suggestions FORCE ROW LEVEL SECURITY;
CREATE POLICY mail_triage_suggestions_owner ON mail_triage_suggestions
    USING (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid)
    WITH CHECK (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid);

CREATE TABLE mail_triage_decisions (
    id BIGSERIAL PRIMARY KEY,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    sender TEXT NOT NULL CHECK (length(sender) BETWEEN 3 AND 320),
    action TEXT NOT NULL CHECK (action IN ('reply','needs_reply','archive','trash','snooze','skip')),
    decided_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id) ON DELETE CASCADE
);
ALTER TABLE mail_triage_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE mail_triage_decisions FORCE ROW LEVEL SECURITY;
CREATE POLICY mail_triage_decisions_owner ON mail_triage_decisions
    USING (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid)
    WITH CHECK (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid);
CREATE INDEX mail_triage_decisions_sender ON mail_triage_decisions(workspace_id, user_id, sender, decided_at DESC);
