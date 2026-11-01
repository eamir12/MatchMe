-- A2: rate-cap the remaining nine tick sources. Rewrites touch_admin_dashboard_tick()
-- to leave the tick untouched when it was already refreshed within 30 seconds, so the
-- published-churn rate is bounded at 2,880/day regardless of write volume or of upserts
-- firing two statement trigger sets.
-- Consequence: last_table/last_op keep the value from the firing that won the window, so
-- the admin dashboard's optimistic per-table counter increments can be skipped; the full
-- reload it already schedules on every tick, plus its 60s fallback poll, corrects them.

BEGIN;

CREATE OR REPLACE FUNCTION public.touch_admin_dashboard_tick()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.admin_dashboard_tick
  SET
    updated_at = now(),
    last_table = TG_TABLE_NAME,
    last_op = TG_OP
  WHERE id = 1
    AND updated_at < now() - interval '30 seconds';

  RETURN NULL;
END;
$$;

COMMIT;
