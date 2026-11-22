-- A name the person gives an account ("Work", "Personal"). Kept apart from
-- display_name, which reconnecting refreshes from the provider.
ALTER TABLE provider_accounts ADD COLUMN name TEXT
    CHECK (name IS NULL OR (length(name) BETWEEN 1 AND 64 AND name !~ '[[:cntrl:]]'));

DROP TRIGGER realtime_accounts_update ON provider_accounts;
CREATE TRIGGER realtime_accounts_update AFTER UPDATE ON provider_accounts
    FOR EACH ROW WHEN (
        OLD.email IS DISTINCT FROM NEW.email OR OLD.display_name IS DISTINCT FROM NEW.display_name
        OR OLD.name IS DISTINCT FROM NEW.name
        OR OLD.status IS DISTINCT FROM NEW.status OR OLD.disabled_at IS DISTINCT FROM NEW.disabled_at
        OR OLD.capabilities IS DISTINCT FROM NEW.capabilities
    ) EXECUTE FUNCTION notify_postmere_realtime('accounts');
