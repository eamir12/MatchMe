-- Migration: Fix subscription normalization for pg_cron (postgres, no JWT)
--
-- Problem:
--   pg_cron runs `SELECT scheduled_subscription_normalization()` as postgres
--   every 5 minutes. In that context auth.uid() IS NULL and auth.jwt() IS NULL,
--   so the guard in normalize_user_subscription_queue():
--     IF v_user_id IS DISTINCT FROM auth.uid()
--        AND COALESCE(auth.jwt() ->> 'role','') <> 'service_role' THEN RAISE 'not authorized'
--   always fires for any real user_id passed from trigger_subscription_normalization().
--   SECURITY DEFINER does not populate auth.uid()/auth.jwt().
--   Same failure happens when an authenticated Flutter client calls
--   trigger_subscription_normalization() (it loops over ALL expired users).
--
-- Fix:
--   1. Move core logic to internal worker _normalize_user_subscription_queue_internal()
--      with NO auth check (SECURITY DEFINER).
--   2. Keep public normalize_user_subscription_queue() as auth-checked wrapper for
--      direct client calls (own user_id or service_role only).
--   3. Make trigger_subscription_normalization() call the internal worker so both
--      cron (postgres) and client-triggered global runs work.
--   4. Lock down internal worker: REVOKE from anon/authenticated, GRANT to
--      postgres/service_role. Clients must go through wrapper/trigger.
--
-- Callers that already validate auth then call normalize() with the SAME user
-- (add_subscription_to_queue, check_and_normalize_user_subscription,
-- force_normalize_subscription) keep calling the public wrapper and stay secure.

-- 1. Internal worker: no auth check, SECURITY DEFINER
CREATE OR REPLACE FUNCTION public._normalize_user_subscription_queue_internal(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := p_user_id;
  v_now timestamptz := now();
  v_current_tier text;
  v_current_expires_at timestamptz;
  v_next record;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.user_subscription_queue
  SET status = 'completed',
      updated_at = v_now
  WHERE user_id = v_user_id
    AND status = 'active'
    AND expires_at <= v_now;

  SELECT u.subscription_tier, u.subscription_expires_at
  INTO v_current_tier, v_current_expires_at
  FROM public.users u
  WHERE u.id = v_user_id
  FOR UPDATE;

  IF v_current_tier IS NULL OR btrim(v_current_tier) = '' THEN
    v_current_tier := 'free';
  END IF;

  IF v_current_tier <> 'free'
     AND v_current_expires_at IS NOT NULL
     AND v_current_expires_at > v_now THEN
    RETURN;
  END IF;

  SELECT sq.*
  INTO v_next
  FROM public.user_subscription_queue sq
  WHERE sq.user_id = v_user_id
    AND sq.status = 'pending'
    AND sq.starts_at <= v_now
  ORDER BY sq.starts_at ASC
  LIMIT 1;

  IF FOUND THEN
    UPDATE public.user_subscription_queue
    SET status = 'active',
        activated_at = COALESCE(activated_at, v_now),
        updated_at = v_now
    WHERE id = v_next.id;

    UPDATE public.users
    SET subscription_tier = v_next.tier,
        subscription_expires_at = v_next.expires_at,
        updated_at = v_now
    WHERE id = v_user_id;
  ELSE
    UPDATE public.users
    SET subscription_tier = 'free',
        subscription_expires_at = NULL,
        updated_at = v_now
    WHERE id = v_user_id;
  END IF;
END;
$$;

-- 2. Public wrapper: keeps per-user auth check for direct client calls
CREATE OR REPLACE FUNCTION public.normalize_user_subscription_queue(p_user_id uuid DEFAULT auth.uid())
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  IF v_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  PERFORM public._normalize_user_subscription_queue_internal(v_user_id);
END;
$$;

-- 3. Batch trigger: calls internal worker so cron + client-triggered runs work
CREATE OR REPLACE FUNCTION public.trigger_subscription_normalization()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT u.id AS user_id
    FROM public.users u
    LEFT JOIN public.user_subscription_queue sq
      ON sq.user_id = u.id
      AND sq.status = 'pending'
      AND sq.starts_at <= now()
    WHERE (u.subscription_tier IS NOT NULL AND u.subscription_tier <> 'free' AND u.subscription_expires_at IS NOT NULL AND u.subscription_expires_at <= now())
       OR sq.id IS NOT NULL
  LOOP
    PERFORM public._normalize_user_subscription_queue_internal(r.user_id);
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.scheduled_subscription_normalization()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.trigger_subscription_normalization();
END;
$$;

-- 4. Permissions: internal worker is privileged, clients use wrapper/trigger
REVOKE ALL ON FUNCTION public._normalize_user_subscription_queue_internal(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._normalize_user_subscription_queue_internal(uuid) TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.normalize_user_subscription_queue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.trigger_subscription_normalization() TO authenticated;
GRANT EXECUTE ON FUNCTION public.scheduled_subscription_normalization() TO postgres, service_role;
