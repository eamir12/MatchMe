-- Retire the legacy RRULE invisibility scheduler.
--
-- The app no longer writes user_visibility_schedules; rules are stored in
-- user_invisibility_rules and evaluated + synced by the client
-- (system_visibility_status = 'hidden_by_rule'). The cron task was therefore
-- dead work, and its "reset everyone to visible, then look for an occurrence
-- within the next 60 seconds" model was wrong for any duration beyond one
-- minute: it flipped users visible before checking, and it reset again on the
-- next tick even when a scheduled invisible period was still running.
--
-- One-time repair: clear the legacy 'invisible' system status that the old
-- scheduler left behind on manually-visible users. The per-minute reset (and
-- the RRULE dependency) is removed from the edge cron function.

BEGIN;

UPDATE public.users
SET system_visibility_status = 'visible'
WHERE user_visibility_setting IS TRUE
  AND system_visibility_status = 'invisible';

COMMIT;
