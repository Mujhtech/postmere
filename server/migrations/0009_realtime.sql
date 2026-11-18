-- Commit-time invalidation hints only. Clients recover missed hints through the
-- existing durable, scoped mailbox cursors. NOTIFY never contains message data.
CREATE FUNCTION notify_postmere_realtime() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE actor_workspace UUID; actor_user UUID;
BEGIN
    IF TG_OP='DELETE' THEN
        actor_workspace:=OLD.workspace_id; actor_user:=OLD.user_id;
    ELSE
        actor_workspace:=NEW.workspace_id; actor_user:=NEW.user_id;
    END IF;
    PERFORM pg_notify('postmere_events_v1',json_build_object(
        'workspace_id',actor_workspace,'user_id',actor_user,'kind',TG_ARGV[0]
    )::text);
    RETURN NULL;
END $$;

CREATE TRIGGER realtime_mail_insert_delete AFTER INSERT OR DELETE ON mail_messages
    FOR EACH ROW EXECUTE FUNCTION notify_postmere_realtime('mail');
CREATE TRIGGER realtime_mail_update AFTER UPDATE ON mail_messages
    FOR EACH ROW WHEN (OLD.normalized IS DISTINCT FROM NEW.normalized OR OLD.deleted_at IS DISTINCT FROM NEW.deleted_at)
    EXECUTE FUNCTION notify_postmere_realtime('mail');

CREATE TRIGGER realtime_accounts_insert_delete AFTER INSERT OR DELETE ON provider_accounts
    FOR EACH ROW EXECUTE FUNCTION notify_postmere_realtime('accounts');
CREATE TRIGGER realtime_accounts_update AFTER UPDATE ON provider_accounts
    FOR EACH ROW WHEN (
        OLD.email IS DISTINCT FROM NEW.email OR OLD.display_name IS DISTINCT FROM NEW.display_name
        OR OLD.status IS DISTINCT FROM NEW.status OR OLD.disabled_at IS DISTINCT FROM NEW.disabled_at
        OR OLD.capabilities IS DISTINCT FROM NEW.capabilities
    ) EXECUTE FUNCTION notify_postmere_realtime('accounts');

CREATE TRIGGER realtime_outbox_insert_delete AFTER INSERT OR DELETE ON mail_outbox
    FOR EACH ROW EXECUTE FUNCTION notify_postmere_realtime('outbox');
CREATE TRIGGER realtime_outbox_update AFTER UPDATE ON mail_outbox
    FOR EACH ROW WHEN (
        OLD.status IS DISTINCT FROM NEW.status OR OLD.scheduled_at IS DISTINCT FROM NEW.scheduled_at
        OR OLD.undo_until IS DISTINCT FROM NEW.undo_until OR OLD.provider_message_id IS DISTINCT FROM NEW.provider_message_id
        OR OLD.error_code IS DISTINCT FROM NEW.error_code
    ) EXECUTE FUNCTION notify_postmere_realtime('outbox');
