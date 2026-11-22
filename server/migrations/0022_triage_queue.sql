-- Triage suggestions are prepared as new inbox mail arrives, so Triage is
-- ready even when the app was closed. Like the other wakeup queues, this
-- table holds only identifiers; the worker reads each message inside that
-- user's own row-level-security scope.
CREATE TABLE mail_triage_wakeups (
    message_id UUID PRIMARY KEY REFERENCES mail_messages(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    due_at TIMESTAMPTZ NOT NULL,
    lease_until TIMESTAMPTZ,
    attempts INT NOT NULL DEFAULT 0
);
CREATE INDEX mail_triage_wakeups_due ON mail_triage_wakeups(due_at, lease_until);

-- Recent incoming inbox mail only: not sent by the account itself, not old
-- history imported on first sync.
CREATE FUNCTION queue_postmere_triage() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.deleted_at IS NOT NULL OR NEW.normalized->>'mailbox' IS DISTINCT FROM 'inbox'
       OR NEW.sent_at < clock_timestamp() - interval '3 days' THEN
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT 1 FROM provider_accounts a WHERE a.id = NEW.account_id
               AND lower(a.email) = lower(NEW.normalized->'from'->>'email')) THEN
        RETURN NEW;
    END IF;
    INSERT INTO mail_triage_wakeups(message_id, workspace_id, user_id, due_at)
    VALUES (NEW.id, NEW.workspace_id, NEW.user_id, clock_timestamp() + interval '5 seconds')
    ON CONFLICT (message_id) DO NOTHING;
    RETURN NEW;
END $$;

CREATE TRIGGER queue_triage_on_arrival AFTER INSERT ON mail_messages
    FOR EACH ROW EXECUTE FUNCTION queue_postmere_triage();
