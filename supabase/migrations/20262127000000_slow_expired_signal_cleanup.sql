-- Migration: relax the expired-location-signal cleanup cadence.
--
-- `delete-expired-location-signals` ran every minute: 1,440 wake-ups and
-- pg_cron log lines per day for a DELETE that almost always removes zero
-- rows. The signal-expiry UX does not depend on that precision:
--   - every client query filters on `expires_at.gt.now()` already, so an
--     expired-but-not-yet-deleted row is never served as active (e.g.
--     LocationShareHelper.kt and location_share_provider.dart);
--   - receivers run a 10s staleness timer (`location_sharing.
--     inactive_timeout_seconds`, default 30s) that flips the peer to
--     "unknown" when position updates stop — which happens at expiry
--     regardless of the DELETE, and
--   - the row's DELETE event only converges the session teardown.
-- A 5-minute cadence (288 runs/day, 5x fewer) still deletes each expired
-- signal promptly in wall-clock terms.
--
-- cron.schedule with an existing job name replaces its schedule.

SELECT cron.schedule(
  'delete-expired-location-signals',
  '*/5 * * * *',
  $$
    DELETE FROM location_share_signals
    WHERE expires_at IS NOT NULL AND expires_at < now();
  $$
);
