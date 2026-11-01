-- A1: stop the heartbeat from fanning into the admin dashboard tick.
-- An upsert fires BOTH the statement-level INSERT and UPDATE trigger sets, so every
-- update_user_activity() call ticked admin_dashboard_tick twice (72,391 of 111,410
-- published changes in the 2026-10-26 window) and queued on that table's single row.
-- No consumer needs it: the admin dashboard subscribes to user_activity directly
-- (matchme_admin/lib/main.dart:3379) and polls every 60s (:3823).

BEGIN;

DROP TRIGGER IF EXISTS trg_touch_admin_dashboard_tick_user_activity ON public.user_activity;

COMMIT;
