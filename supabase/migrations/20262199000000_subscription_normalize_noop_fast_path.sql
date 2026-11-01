-- Migration: make check_and_normalize_user_subscription() a read when nothing is due.
-- Date: 2026-10-29
--
-- Problem (measured 2026-10-29):
--   The RPC took `SELECT ... FOR UPDATE` on the caller's users row on every
--   call and then always ran an UPDATE, even when the row already held the
--   values being written. For the common case (free tier, no due queue rows)
--   that meant: a row lock on public.users, four BEFORE UPDATE
--   row triggers, the statement-level dashboard tick trigger and a WAL flush --
--   all for a write that changes nothing.
--
--   The client calls this on app open (subscription_service.dart), so bursts of
--   concurrent calls for the same user serialize on that row lock. On
--   2026-10-29 07:23:28Z two such calls overlapped, one held the lock, and the
--   other hit _normalize_user_subscription_queue_internal()'s 3s lock_timeout
--   -> SQLSTATE 55P03 -> PostgREST 500 (visible in edge logs).
--
-- Fix:
--   Return early -- before normalize_user_subscription_queue() and therefore
--   before the FOR UPDATE -- when the stored tier is already in its terminal
--   state and no queue row is due. The returned row is identical to what the
--   old code produced in that case (previous_tier = new_tier, normalized =
--   false), and no lock is taken, so concurrent calls no longer queue up.
--
-- Behavior is unchanged whenever there is real work: a due pending row, an
-- expired active row, an expired paid tier, a NULL/blank tier, or a 'free'
-- tier with a stale expiry all fall through to the existing path.
--
-- Blast radius: one function body. CREATE OR REPLACE preserves the existing
-- owner and ACL, so the EXECUTE grants from the security-advisor passes stay
-- in force. No table, index or trigger changes.

CREATE OR REPLACE FUNCTION public.check_and_normalize_user_subscription(p_user_id uuid DEFAULT auth.uid())
RETURNS TABLE(previous_tier character varying, new_tier character varying, normalized boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_before text;
  v_after text;
  v_before_exp timestamptz;
  v_after_exp timestamptz;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  IF v_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  SELECT subscription_tier, subscription_expires_at
  INTO v_before, v_before_exp
  FROM public.users
  WHERE id = v_user_id;

  -- Fast path. Mirrors exactly what _normalize_user_subscription_queue_internal()
  -- would decide: it early-returns when the tier is non-free and unexpired, and
  -- otherwise writes 'free'/NULL when no pending row is due. If the row already
  -- holds that outcome and no queue row is due, the call is a pure read.
  IF (
       (v_before = 'free' AND v_before_exp IS NULL)
       OR (v_before IS NOT NULL AND btrim(v_before) <> '' AND v_before <> 'free'
           AND v_before_exp IS NOT NULL AND v_before_exp > now())
     )
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_subscription_queue sq
       WHERE sq.user_id = v_user_id
         AND (
           (sq.status = 'pending' AND sq.starts_at <= now())
           OR (sq.status = 'active' AND sq.expires_at <= now())
         )
     )
  THEN
    RETURN QUERY SELECT v_before::varchar, v_before::varchar, false;
    RETURN;
  END IF;

  PERFORM public.normalize_user_subscription_queue(v_user_id);

  SELECT subscription_tier, subscription_expires_at
  INTO v_after, v_after_exp
  FROM public.users
  WHERE id = v_user_id;

  RETURN QUERY SELECT
    v_before::varchar,
    v_after::varchar,
    (v_before IS DISTINCT FROM v_after) OR (v_before_exp IS DISTINCT FROM v_after_exp);
END;
$function$;

-- Verification (run after applying):
--
--   -- Fast path must not write and must not take a lock.
--   select updated_at from public.users where id = '<free-user-uuid>';
--   select * from public.check_and_normalize_user_subscription('<free-user-uuid>');
--   select updated_at from public.users where id = '<free-user-uuid>';  -- unchanged
--
--   -- Real work still happens.
--   select * from public.check_and_normalize_user_subscription('<user-with-due-pending-row>');
--
--   -- Lock behaviour: hold the row in another session
--   --   begin; select * from public.users where id = '<uuid>' for update; select pg_sleep(6); commit;
--   -- then the fast-path call returns immediately instead of raising 55P03.
