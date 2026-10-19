-- Migration: Heal subscription normalization drift and bound lock waits.
--
-- Problems seen in production logs (2026-10-17, project vazkmvrbshxwyodentng):
--   1. public.normalize_user_subscription (created from the untracked root
--      script create_subscription_tiers_table.sql) references
--      users.subscription_next_tier / subscription_next_starts_at /
--      subscription_next_expires_at, but no tracked migration ever adds
--      those columns. Every call failed with 42703
--      "column u.subscription_next_tier does not exist"; the Flutter client
--      then fell back to force_normalize_subscription, so the fallback chain
--      errored every minute per device.
--   2. The normalization functions take SELECT ... FOR UPDATE on the users
--      row with no lock_timeout. A concurrent normalization/update can block
--      plain single-row reads (GET /rest/v1/users, user_invisibility_rules)
--      until the statement timeout, producing 57014 timeouts for unrelated
--      requests during the 5-minute cron sweep.
--
-- Fix:
--   1. Restore the three legacy next-tier columns (idempotent) so any
--      deployed function version that references them works again.
--   2. Recreate normalize_user_subscription as an auth-checked delegate to
--      the queue-based internal worker (single source of truth; the queue
--      table user_subscription_queue supersedes the next-tier columns).
--      This also makes the function exist on environments built only from
--      tracked migrations.
--   3. Bound lock waits in the internal worker (lock_timeout) so a
--      normalization sweep can never stall unrelated requests.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Legacy next-tier columns (dead state, but referenced by deployed bodies)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'users'
  ) THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'users'
        AND column_name = 'subscription_next_tier'
    ) THEN
      ALTER TABLE public.users ADD COLUMN subscription_next_tier TEXT;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'users'
        AND column_name = 'subscription_next_starts_at'
    ) THEN
      ALTER TABLE public.users ADD COLUMN subscription_next_starts_at TIMESTAMPTZ;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'users'
        AND column_name = 'subscription_next_expires_at'
    ) THEN
      ALTER TABLE public.users ADD COLUMN subscription_next_expires_at TIMESTAMPTZ;
    END IF;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Queue-based internal worker, now with a bounded lock wait
-- ---------------------------------------------------------------------------
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

  -- Never let one locked row stall the whole request/statement window.
  -- 55P03 (lock_not_available) is a fast, retryable failure instead of an
  -- 8s block that also times out unrelated readers of the same row.
  SET LOCAL lock_timeout = '3s';

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

REVOKE ALL ON FUNCTION public._normalize_user_subscription_queue_internal(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._normalize_user_subscription_queue_internal(uuid) TO postgres, service_role;

-- ---------------------------------------------------------------------------
-- 3. normalize_user_subscription -> queue-based delegate
--    (DROP first: the deployed legacy version has a different provenance and
--    CREATE OR REPLACE cannot change an existing RETURNS TABLE shape.)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.normalize_user_subscription(uuid);

CREATE FUNCTION public.normalize_user_subscription(p_user_id uuid DEFAULT auth.uid())
RETURNS TABLE (
  subscription_tier text,
  subscription_expires_at timestamptz,
  subscription_next_tier text,
  subscription_next_starts_at timestamptz,
  subscription_next_expires_at timestamptz
)
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

  RETURN QUERY
  SELECT u.subscription_tier,
         u.subscription_expires_at,
         u.subscription_next_tier,
         u.subscription_next_starts_at,
         u.subscription_next_expires_at
  FROM public.users u
  WHERE u.id = v_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.normalize_user_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_user_subscription(uuid) TO service_role;

COMMIT;
