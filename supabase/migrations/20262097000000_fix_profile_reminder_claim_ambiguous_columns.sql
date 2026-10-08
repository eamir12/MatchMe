-- Migration: Fix 42702 "column reference \"user_id\" is ambiguous" and
-- 42804 "Returned type numeric does not match expected type double precision
-- in column 7" in claim_profile_reminder_candidates (cron profile-reminder
-- automation)
-- Date: 2026-10-07
-- Depends on: 20262095000000 (creates the function), 20262096000000 (queue RPC)
--
-- Root cause 1 (42702): the function's RETURNS TABLE clause turns every output
-- column into a PL/pgSQL variable: (user_id, fcm_token, platform, ui_language,
-- display_name, stage, hours_closed). The claimed CTE then inserts into
-- profile_reminder_state with ON CONFLICT (user_id) ... RETURNING user_id,
-- stage — where "user_id" and "stage" are BOTH profile_reminder_state columns
-- AND PL/pgSQL variables. At first execution the cron's queue RPC
-- (queue_profile_reminder_broadcast_notifications) failed with:
--   42702: column reference "user_id" is ambiguous
--   details: It could refer to either a PL/pgSQL variable or a table column.
--
-- Root cause 2 (42804, masked by 42702 and surfaced right after it was fixed):
-- hours_closed comes from EXTRACT(EPOCH FROM ...)/3600.0, and EXTRACT returns
-- NUMERIC on PostgreSQL 14+, while the function promises double precision in
-- column 7. Fixed with an explicit ::double precision cast.
--
-- Fix 1: #variable_conflict use_column makes every bare name that matches both
-- a variable and a query column resolve to the COLUMN. That is correct for
-- this function: the OUT parameters are never read inside the body (they are
-- only assigned by RETURN QUERY), while user_id/stage in the claimed CTE
-- always mean profile_reminder_state columns. No other local variable
-- (p_*/v_*) shares a name with any column in the queries, so nothing else
-- changes resolution. Function signature, output column names and privileges
-- are unchanged (CREATE OR REPLACE with the same argument types).

CREATE OR REPLACE FUNCTION public.claim_profile_reminder_candidates(
  p_offsets_hours double precision[] DEFAULT ARRAY[1, 5]::double precision[],
  p_repeat_hours double precision DEFAULT 24,
  p_max_reminders integer DEFAULT 0,
  p_limit integer DEFAULT 200
)
RETURNS TABLE (user_id uuid, fcm_token text, platform text, ui_language text, display_name text, stage integer, hours_closed double precision)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
-- OUT params (user_id, stage, ...) share names with profile_reminder_state
-- columns; bare names in this body always mean table columns.
#variable_conflict use_column
DECLARE
  v_sorted double precision[];
  v_n integer;
  v_first double precision;
  v_last double precision;
  v_limit integer;
BEGIN
  SELECT COALESCE(array_agg(DISTINCT o ORDER BY o), ARRAY[]::double precision[])
  INTO v_sorted
  FROM unnest(COALESCE(p_offsets_hours, ARRAY[1, 5]::double precision[])) AS o
  WHERE o IS NOT NULL AND o > 0;
  IF v_sorted IS NULL OR array_length(v_sorted, 1) = 0 THEN
    v_sorted := ARRAY[1.0, 5.0]::double precision[];
  END IF;
  v_n := array_length(v_sorted, 1);
  v_first := v_sorted[1];
  v_last := v_sorted[v_n];
  v_limit := GREATEST(LEAST(COALESCE(p_limit, 200), 2000), 1);

  RETURN QUERY
  WITH cand AS (
    SELECT DISTINCT ON (u.id)
      u.id AS user_id,
      ua.last_activity AS closed_at,
      us.metadata->>'fcm_token' AS fcm_token,
      us.platform AS platform,
      COALESCE(NULLIF(lower(btrim(COALESCE(u.preferred_language, ''))), ''), 'en') AS ui_language,
      COALESCE(u.name, '') AS display_name
    FROM public.users u
    JOIN public.user_activity ua ON ua.user_id = u.id
    JOIN public.user_session us ON us.user_id = u.id
    WHERE us.revoked = false
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
      AND COALESCE(u.is_profile_complete, false) = false
      AND COALESCE(u.is_admin, false) = false
      AND COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) = true
      AND COALESCE(
            (u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
            (u.notification_preferences->>'enable_admin_notifications')::boolean, true) = true
    ORDER BY u.id, us.last_active_at DESC NULLS LAST
  ),
  due AS (
    SELECT
      c.*,
      (EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0)::double precision AS hours_closed,
      GREATEST(
        (SELECT COUNT(*)::int FROM unnest(v_sorted) AS o
          WHERE (EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) >= o),
        CASE
          WHEN p_repeat_hours > 0
            AND (EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) >= v_last + p_repeat_hours
          THEN v_n + FLOOR(((EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) - v_last) / p_repeat_hours)::int
          ELSE 0
        END
      ) AS due_stage
    FROM cand c
    WHERE (EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) >= v_first
  ),
  batch AS (
    SELECT * FROM due
    ORDER BY closed_at DESC
    LIMIT v_limit
  ),
  eligible AS (
    SELECT * FROM batch
    WHERE due_stage >= 1
      AND (COALESCE(p_max_reminders, 0) <= 0 OR due_stage <= p_max_reminders)
  ),
  claimed AS (
    INSERT INTO public.profile_reminder_state
      (user_id, stage, last_activity_at, last_sent_at, updated_at)
    SELECT e.user_id, e.due_stage, e.closed_at, now(), now()
    FROM eligible e
    ON CONFLICT (user_id) DO UPDATE
      SET stage = EXCLUDED.stage,
          last_activity_at = EXCLUDED.last_activity_at,
          last_sent_at = now(),
          updated_at = now()
      WHERE profile_reminder_state.stage < EXCLUDED.stage
         OR profile_reminder_state.last_activity_at < EXCLUDED.last_activity_at
    RETURNING user_id AS claimed_user_id, stage AS claimed_stage
  )
  SELECT cl.claimed_user_id, e.fcm_token, e.platform, e.ui_language, e.display_name,
         cl.claimed_stage, e.hours_closed
  FROM claimed cl
  JOIN eligible e ON e.user_id = cl.claimed_user_id;
END;
$$;

-- Privileges are preserved by CREATE OR REPLACE, but re-assert for safety.
REVOKE ALL ON FUNCTION public.claim_profile_reminder_candidates(double precision[], double precision, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_profile_reminder_candidates(double precision[], double precision, integer, integer) TO service_role;
