-- Dry-run verification for 20262097000000_fix_profile_reminder_claim_ambiguous_columns.sql
-- Run this AFTER applying the migration (Supabase SQL Editor is fine).
--
-- What it does: executes claim_profile_reminder_candidates() inside a
-- transaction that is rolled back. Before the fix this was the exact
-- statement that blew up with:
--   42702: column reference "user_id" is ambiguous
--   details: It could refer to either a PL/pgSQL variable or a table column.
-- because the ambiguity is a parse-analysis error that only surfaces on the
-- function's first execution (plpgsql prepares statements lazily), which is
-- why CREATE OR REPLACE alone "succeeded" while the cron RPC kept failing.
--
-- The ROLLBACK discards any profile_reminder_state rows the test claims, so
-- it is side-effect free and does not consume anyone's reminder stage.
-- (Do NOT remove the BEGIN/ROLLBACK pair.)

BEGIN;

SELECT * FROM public.claim_profile_reminder_candidates(
  ARRAY[1.0, 5.0]::double precision[],  -- real intervals; may match real candidates
  24.0,                                  -- repeat hours
  0,                                     -- no max-reminder cap
  5                                      -- tiny batch: at most 5 rows touched
);

-- Expected after the fix: a result set with columns
--   user_id | fcm_token | platform | ui_language | display_name | stage | hours_closed
-- (0..5 rows, depending on who is currently due) and NO error.
--
-- Optional end-to-end check — run the cron task's queue RPC the same way.
-- Safe here: queue_fcm_notification only INSERTs into notification_queue and
-- admin_broadcast_deliveries, both of which this ROLLBACK discards (the queue
-- sender cannot see uncommitted rows).

SELECT public.queue_profile_reminder_broadcast_notifications(
  'd475207b-b42f-4b6f-bdef-9fe8e25ba134'::uuid  -- the broadcast id from the failing log
);

-- Expected: an integer count (0 on a dry database is fine — it proves the
-- whole chain parses and runs) and NO 42702 error.

ROLLBACK;
