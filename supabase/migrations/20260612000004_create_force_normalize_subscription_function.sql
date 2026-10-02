-- Migration: Create force_normalize_subscription function
-- Phase 7: Replace client-side subscription fallback direct write with a safe RPC.
-- The client calls this RPC instead of directly writing to users table.
-- The function always respects server-side expiration logic.

CREATE OR REPLACE FUNCTION public.force_normalize_subscription(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before TEXT;
  v_after TEXT;
BEGIN
  SELECT subscription_tier INTO v_before FROM users WHERE id = p_user_id;

  -- Delegate to the existing normalization logic
  PERFORM normalize_user_subscription_queue(p_user_id);

  SELECT subscription_tier INTO v_after FROM users WHERE id = p_user_id;

  RETURN jsonb_build_object(
    'before', v_before,
    'after', v_after,
    'normalized', (v_before IS DISTINCT FROM v_after)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.force_normalize_subscription(UUID) TO authenticated;
