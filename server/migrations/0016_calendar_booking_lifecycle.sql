-- Existing links retain their primary-calendar behavior. Recurrence is bounded
-- and materialized into slots; no request can expand an unbounded recurrence.
ALTER TABLE calendar_booking_links
    ADD COLUMN calendar_id TEXT NOT NULL DEFAULT 'primary' CHECK (length(calendar_id) BETWEEN 1 AND 1024),
    ADD COLUMN conflict_calendar_ids TEXT[] NOT NULL DEFAULT ARRAY['primary']::TEXT[] CHECK (cardinality(conflict_calendar_ids) BETWEEN 1 AND 8),
    ADD COLUMN availability JSONB;
ALTER TABLE calendar_sharing
    ADD COLUMN calendar_ids TEXT[] NOT NULL DEFAULT ARRAY['primary']::TEXT[] CHECK (cardinality(calendar_ids) BETWEEN 1 AND 8);
ALTER TABLE calendar_bookings DROP CONSTRAINT calendar_bookings_status_check;
ALTER TABLE calendar_bookings ADD CONSTRAINT calendar_bookings_status_check
    CHECK (status IN ('checking','creating','confirmed','failed','uncertain','cancelling','cancel_uncertain','cancelled'));
DROP INDEX calendar_bookings_conflicts;
CREATE INDEX calendar_bookings_conflicts ON calendar_bookings(account_id,starts_at,ends_at)
    WHERE status NOT IN ('failed','cancelled');
