-- Fix: redeem_promo_code now actually applies the promotional benefit.
--
-- Previously the function only recorded a row in promo_code_usages. For
-- code_type = 'free_days' this meant the user only ever saw the duration of
-- the plan they purchased (e.g. 1 day for a Plus daily plan) and never
-- received the bonus days promised by the promo code (e.g. 5 extra days).
--
-- This migration updates redeem_promo_code so that, when the code is a
-- 'free_days' code, the function inserts an additional entry into
-- user_subscription_queue that extends the user's current (or next)
-- subscription by the configured number of days. Other code types keep
-- their previous behaviour (recording the redemption only).
--
-- For 'tier_upgrade' codes the user's subscription_tier is bumped to the
-- upgrade tier while preserving the current expiry, which matches the
-- existing intent of that code type.

BEGIN;

DROP FUNCTION IF EXISTS public.redeem_promo_code(TEXT, UUID, UUID, INT);

CREATE OR REPLACE FUNCTION public.redeem_promo_code(
  p_code TEXT,
  p_user_id UUID DEFAULT auth.uid(),
  p_subscription_queue_id UUID DEFAULT NULL,
  p_discount_value_cents INT DEFAULT NULL
)
RETURNS TABLE (success BOOLEAN, error_message TEXT, usage_id UUID, message TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_user_id UUID;
  v_code_id UUID;
  v_code_type TEXT;
  v_amount INT;
  v_upgrade_tier TEXT;
  v_usage_id UUID;
  v_max_uses_per_user INT;
  v_user_uses INT := 0;
  v_max_uses INT;
  v_total_uses INT := 0;
  v_current_tier TEXT;
  v_current_expires_at TIMESTAMPTZ;
  v_last_queued_expires_at TIMESTAMPTZ;
  v_new_starts_at TIMESTAMPTZ;
  v_new_expires_at TIMESTAMPTZ;
  v_new_queue_id UUID;
  v_now TIMESTAMPTZ := now();
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  IF v_user_id IS NULL THEN
    RETURN QUERY
    SELECT false, 'Not authenticated'::TEXT, NULL::UUID, 'User not authenticated'::TEXT;
    RETURN;
  END IF;

  p_code := UPPER(TRIM(p_code));

  SELECT
    pc.id,
    pc.code_type,
    pc.amount,
    pc.upgrade_tier,
    pc.max_uses_per_user,
    pc.max_uses
  INTO
    v_code_id,
    v_code_type,
    v_amount,
    v_upgrade_tier,
    v_max_uses_per_user,
    v_max_uses
  FROM public.promo_codes AS pc
  WHERE UPPER(pc.code) = p_code
    AND pc.is_active = true;

  IF v_code_id IS NULL THEN
    RETURN QUERY
    SELECT false, 'Invalid or inactive promo code'::TEXT, NULL::UUID, 'The promo code could not be found'::TEXT;
    RETURN;
  END IF;

  SELECT COUNT(*)::INT
  INTO v_user_uses
  FROM public.promo_code_usages AS pcu
  WHERE pcu.promo_code_id = v_code_id
    AND pcu.user_id = v_user_id;

  IF v_user_uses >= v_max_uses_per_user THEN
    RETURN QUERY
    SELECT false, 'Usage limit exceeded'::TEXT, NULL::UUID, 'You have already used this code the maximum number of times'::TEXT;
    RETURN;
  END IF;

  SELECT COUNT(*)::INT
  INTO v_total_uses
  FROM public.promo_code_usages AS pcu
  WHERE pcu.promo_code_id = v_code_id;

  IF v_max_uses IS NOT NULL AND v_total_uses >= v_max_uses THEN
    RETURN QUERY
    SELECT false, 'Code limit reached'::TEXT, NULL::UUID, 'This promo code has reached its usage limit'::TEXT;
    RETURN;
  END IF;

  -- Apply the promotional benefit.
  IF v_code_type = 'free_days' AND v_amount IS NOT NULL AND v_amount > 0 THEN
    PERFORM pg_advisory_xact_lock(hashtext(v_user_id::text));

    PERFORM public.normalize_user_subscription_queue(v_user_id);

    SELECT u.subscription_tier, u.subscription_expires_at
    INTO v_current_tier, v_current_expires_at
    FROM public.users AS u
    WHERE u.id = v_user_id;

    SELECT MAX(sq.expires_at)
    INTO v_last_queued_expires_at
    FROM public.user_subscription_queue AS sq
    WHERE sq.user_id = v_user_id
      AND sq.status IN ('pending', 'active')
      AND sq.expires_at > v_now;

    v_new_starts_at := v_now;
    IF v_current_expires_at IS NOT NULL AND v_current_expires_at > v_new_starts_at THEN
      v_new_starts_at := v_current_expires_at;
    END IF;
    IF v_last_queued_expires_at IS NOT NULL AND v_last_queued_expires_at > v_new_starts_at THEN
      v_new_starts_at := v_last_queued_expires_at;
    END IF;

    v_new_expires_at := v_new_starts_at + (v_amount || ' days')::interval;

    INSERT INTO public.user_subscription_queue (
      user_id,
      tier,
      status,
      starts_at,
      expires_at,
      payment_provider,
      transaction_id,
      purchase_metadata,
      created_at,
      updated_at
    ) VALUES (
      v_user_id,
      COALESCE(NULLIF(v_current_tier, ''), 'free'),
      'pending',
      v_new_starts_at,
      v_new_expires_at,
      'promo_code',
      v_code_id::text,
      jsonb_build_object(
        'source', 'promo_code',
        'promo_code_id', v_code_id,
        'free_days', v_amount
      ),
      v_now,
      v_now
    )
    RETURNING id INTO v_new_queue_id;

    PERFORM public.normalize_user_subscription_queue(v_user_id);

    -- If a queue entry id was passed in by the client, associate it with
    -- this new entry so the usage row still references the original purchase.
    p_subscription_queue_id := COALESCE(p_subscription_queue_id, v_new_queue_id);
  ELSIF v_code_type = 'tier_upgrade' AND v_upgrade_tier IS NOT NULL THEN
    -- For tier upgrades, the user keeps their current expiry but is moved
    -- to the upgraded tier if they are not already on it.
    PERFORM pg_advisory_xact_lock(hashtext(v_user_id::text));

    PERFORM public.normalize_user_subscription_queue(v_user_id);

    UPDATE public.users AS u
    SET subscription_tier = v_upgrade_tier,
        updated_at = v_now
    WHERE u.id = v_user_id
      AND (u.subscription_tier IS NULL OR u.subscription_tier = '' OR u.subscription_tier = 'free');
  END IF;

  INSERT INTO public.promo_code_usages (
    promo_code_id,
    user_id,
    subscription_queue_id,
    discount_value_cents,
    applied_tier
  )
  VALUES (
    v_code_id,
    v_user_id,
    p_subscription_queue_id,
    p_discount_value_cents,
    (
      SELECT u.subscription_tier
      FROM public.users AS u
      WHERE u.id = v_user_id
    )
  )
  RETURNING id INTO v_usage_id;

  RETURN QUERY
  SELECT true, NULL::TEXT, v_usage_id, 'Promo code redeemed successfully'::TEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.redeem_promo_code(TEXT, UUID, UUID, INT) TO authenticated;

COMMENT ON FUNCTION public.redeem_promo_code(TEXT, UUID, UUID, INT) IS
  'Records a promo code redemption and applies its benefit (free_days or tier_upgrade) to the user''s subscription';

COMMIT;
