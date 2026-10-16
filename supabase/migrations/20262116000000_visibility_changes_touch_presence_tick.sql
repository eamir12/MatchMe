-- Migration: visibility changes must fire presence_tick for instant nearby map updates
-- Date: 2026-10-16
--
-- WHY: When user A flips visible -> invisible (or back), user B's Nearby map
--      kept showing (or missing) them until the 30-second fallback poll.
--
--      The map already subscribes to users / user_activity postgres_changes,
--      but those channels only deliver rows the subscriber can SELECT under
--      RLS (see 20262104000000 header): users is matched-pairs-only in the
--      client policy set, and user_activity is own-row-only, so for the
--      anonymous nearby users the map aggregates, no direct event arrives.
--
--      presence_tick exists exactly for this (20262104, extended for pins in
--      20262108): a single row, readable by every authenticated user, touched
--      by triggers whenever presence changes; every client debounces and
--      re-queries the SECURITY DEFINER RPCs. Visibility flips were the
--      missing case:
--        * is_online flips tick, but is_visible flips did not, and
--        * system_visibility_status changes (invisibility rules / admin)
--          touched nothing at all.
--
-- FIX: two triggers (mirroring the existing is_online flip pattern):
--       1. users.user_visibility_setting / system_visibility_status change
--          -> covers the manual switch and rules-based hidden_by_rule, and
--          also admin-driven status changes.
--       2. user_activity.is_visible flip -> covers the mirrored flag synced
--          by update_user_visibility() and heartbeat upserts.
--
--      A manual toggle fires both in one transaction (the users trigger calls
--      update_user_visibility()), so presence_tick is updated twice; clients
--      coalesce the duplicate ticks with their 500 ms refresh debounce.
--      Heartbeat-only writes (last_activity / updated_at, is_visible
--      unchanged) still do NOT tick.

BEGIN;

-- 1. Visibility settings change on the users row.
DROP TRIGGER IF EXISTS trg_touch_presence_tick_user_visibility ON public.users;
CREATE TRIGGER trg_touch_presence_tick_user_visibility
  AFTER UPDATE OF user_visibility_setting, system_visibility_status ON public.users
  FOR EACH ROW
  WHEN (
    OLD.user_visibility_setting IS DISTINCT FROM NEW.user_visibility_setting
    OR OLD.system_visibility_status IS DISTINCT FROM NEW.system_visibility_status
  )
  EXECUTE FUNCTION public.touch_presence_tick();

-- 2. Mirrored visibility flag on the activity row.
DROP TRIGGER IF EXISTS trg_touch_presence_tick_user_activity_visible_flip ON public.user_activity;
CREATE TRIGGER trg_touch_presence_tick_user_activity_visible_flip
  AFTER UPDATE OF is_visible ON public.user_activity
  FOR EACH ROW
  WHEN (OLD.is_visible IS DISTINCT FROM NEW.is_visible)
  EXECUTE FUNCTION public.touch_presence_tick();

COMMIT;

-- Verify
SELECT event_object_table, trigger_name
FROM information_schema.triggers
WHERE trigger_name IN (
  'trg_touch_presence_tick_user_visibility',
  'trg_touch_presence_tick_user_activity_visible_flip'
)
ORDER BY event_object_table;
