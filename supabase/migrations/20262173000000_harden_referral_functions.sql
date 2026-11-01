-- Harden referral RPCs and move pending-referral processing into SQL.
--
-- * generate_referral_code(p_user_id) let any authenticated caller set another
--   user's code (and looped 20 times then raised when the user already had one).
-- * complete_referral(p_user_id) let any authenticated caller complete someone
--   else's referral and never checked that the referee actually finished their
--   profile; the edge re-implemented that check per row (N+1).
-- * The edge also loaded every pending referral without a limit and queried
--   users one by one.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) generate_referral_code: self/service only, idempotent.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_referral_code(p_user_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prefix TEXT;
  v_code TEXT;
  v_existing TEXT;
  v_attempts INTEGER := 0;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role'
     AND (auth.uid() IS NULL OR auth.uid() <> p_user_id) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  SELECT referral_code INTO v_existing FROM public.users WHERE id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'user not found';
  END IF;
  IF v_existing IS NOT NULL AND btrim(v_existing) <> '' THEN
    RETURN v_existing;
  END IF;

  SELECT COALESCE(
    LEFT(REGEXP_REPLACE(COALESCE(name, ''), '[^a-zA-Z0-9]', '', 'g'), 4),
    'USER'
  ) INTO v_prefix FROM public.users WHERE id = p_user_id;

  IF v_prefix IS NULL OR v_prefix = '' THEN
    v_prefix := 'USER';
  END IF;

  LOOP
    v_code := UPPER(v_prefix || SUBSTR(MD5(RANDOM()::TEXT), 1, 4));
    v_attempts := v_attempts + 1;

    IF v_attempts > 20 THEN
      RAISE EXCEPTION 'Could not generate a unique referral code after 20 attempts';
    END IF;

    BEGIN
      UPDATE public.users
      SET referral_code = v_code
      WHERE id = p_user_id AND referral_code IS NULL;

      IF FOUND THEN
        RETURN v_code;
      END IF;

      -- Another session won the race; return its code.
      SELECT referral_code INTO v_existing
      FROM public.users
      WHERE id = p_user_id AND referral_code IS NOT NULL;
      IF v_existing IS NOT NULL THEN
        RETURN v_existing;
      END IF;
    EXCEPTION WHEN unique_violation THEN
      -- collision; retry with a new random suffix
    END;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.generate_referral_code(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_referral_code(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.generate_referral_code(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_referral_code(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) complete_referral: self/service only + require a completed profile.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.complete_referral(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referral RECORD;
  v_reward_amount INTEGER;
  v_profile_complete BOOLEAN;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role'
     AND (auth.uid() IS NULL OR auth.uid() <> p_user_id) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  SELECT COALESCE(is_profile_complete, false) INTO v_profile_complete
  FROM public.users
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'user_not_found');
  END IF;
  IF NOT v_profile_complete THEN
    RETURN jsonb_build_object('success', false, 'reason', 'profile_incomplete');
  END IF;

  SELECT * INTO v_referral
  FROM public.referrals
  WHERE referee_id = p_user_id AND status = 'pending'
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_pending_referral');
  END IF;

  v_reward_amount := GREATEST(
    public.app_config_int('referral.reward_amount', 10), 0
  );

  UPDATE public.users SET credits = COALESCE(credits, 0) + v_reward_amount WHERE id = v_referral.referrer_id;
  UPDATE public.users SET credits = COALESCE(credits, 0) + v_reward_amount WHERE id = p_user_id;

  UPDATE public.referrals
  SET status = 'completed', completed_at = NOW()
  WHERE id = v_referral.id;

  RETURN jsonb_build_object(
    'success', true,
    'referrer_id', v_referral.referrer_id,
    'referee_id', p_user_id,
    'reward_amount', v_reward_amount
  );
END;
$$;

REVOKE ALL ON FUNCTION public.complete_referral(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.complete_referral(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.complete_referral(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_referral(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Batch processor for the cron task (service role only).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.process_pending_referrals(p_limit INT DEFAULT 500)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
  v_result JSONB;
  v_count INTEGER := 0;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  FOR r IN
    SELECT ref.id, ref.referee_id
    FROM public.referrals ref
    JOIN public.users u ON u.id = ref.referee_id
    WHERE ref.status = 'pending'
      AND ref.created_at < NOW() - INTERVAL '1 hour'
      AND COALESCE(u.is_profile_complete, false)
    ORDER BY ref.created_at
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 500), 1), 2000)
    FOR UPDATE OF ref SKIP LOCKED
  LOOP
    BEGIN
      v_result := public.complete_referral(r.referee_id);
      IF COALESCE((v_result ->> 'success')::boolean, false) THEN
        v_count := v_count + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- A single bad referral must not block the rest of the batch.
      RAISE WARNING 'process_pending_referrals: referral % failed: %', r.id, SQLERRM;
    END;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.process_pending_referrals(INT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.process_pending_referrals(INT) FROM anon;
REVOKE ALL ON FUNCTION public.process_pending_referrals(INT) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.process_pending_referrals(INT) TO service_role;

CREATE INDEX IF NOT EXISTS idx_referrals_pending_created
  ON public.referrals (created_at)
  WHERE status = 'pending';

COMMIT;
