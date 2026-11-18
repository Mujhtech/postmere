-- Persistent native sessions have two NULL expiry columns. They remain bound
-- to their signed-in user/workspace and stop on sign-out or access revocation.
-- Each individual message still expires after 24 hours to avoid stale alerts.
CREATE OR REPLACE FUNCTION queue_postmere_mail_push() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.deleted_at IS NOT NULL OR NEW.normalized->>'mailbox' IS DISTINCT FROM 'inbox'
       OR NEW.normalized->>'is_read' IS DISTINCT FROM 'false'
       OR NEW.sent_at > clock_timestamp()+interval '5 minutes' THEN RETURN NEW; END IF;
    WITH inserted AS (
      INSERT INTO push_deliveries(id,workspace_id,user_id,device_id,message_id,account_id,expires_at)
      SELECT gen_random_uuid(),NEW.workspace_id,NEW.user_id,d.id,NEW.id,NEW.account_id,
             least(s.expires_at,s.absolute_expires_at,NEW.sent_at+interval '24 hours')
      FROM push_devices d
      JOIN push_preferences p ON p.device_id=d.id AND p.account_id=NEW.account_id
      JOIN provider_accounts a ON a.id=p.account_id
      JOIN sessions s ON s.id=d.session_id AND s.user_id=d.user_id AND s.workspace_id=d.workspace_id
      JOIN users u ON u.id=d.user_id
      JOIN memberships m ON m.user_id=d.user_id AND m.workspace_id=d.workspace_id
      JOIN workspaces w ON w.id=d.workspace_id
      WHERE d.workspace_id=NEW.workspace_id AND d.user_id=NEW.user_id
        AND d.enabled AND d.disabled_at IS NULL AND p.enabled
        AND a.disabled_at IS NULL AND a.status='connected'
        AND lower(NEW.normalized->'from'->>'email') <> lower(a.email)
        AND NEW.sent_at >= greatest(d.first_registered_at,p.enabled_since,a.push_connected_at)
        AND s.revoked_at IS NULL
        AND (s.expires_at IS NULL OR s.expires_at>clock_timestamp())
        AND (s.absolute_expires_at IS NULL OR s.absolute_expires_at>clock_timestamp())
        AND u.disabled_at IS NULL AND m.revoked_at IS NULL AND w.disabled_at IS NULL
        AND NEW.sent_at+interval '24 hours'>clock_timestamp()
      ON CONFLICT(device_id,message_id) DO NOTHING
      RETURNING id,workspace_id,user_id
    )
    INSERT INTO push_delivery_wakeups(job_id,workspace_id,user_id,due_at)
      SELECT id,workspace_id,user_id,clock_timestamp() FROM inserted;
    RETURN NEW;
END $$;
