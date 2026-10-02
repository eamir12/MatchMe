-- Enable pg_cron if not already enabled
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Delete expired location share signals every minute.
-- This is the authoritative expiry mechanism — the app is purely reactive.
-- The DELETE event propagates via Postgres Changes to notify the receiver.
SELECT cron.schedule(
  'delete-expired-location-signals',
  '* * * * *',
  $$
    DELETE FROM location_share_signals
    WHERE expires_at IS NOT NULL AND expires_at < now();
  $$
);
