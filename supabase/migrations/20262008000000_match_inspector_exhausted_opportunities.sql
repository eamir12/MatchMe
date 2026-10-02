-- Surface exhausted no-chat match opportunities in the admin Match Inspector.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_match_pair_status(
  p_user_a uuid,
  p_user_b uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_expiry_count integer := 0;
  v_is_permanent boolean := false;
  v_max_occurrence integer := 3;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.is_admin = true
  ) INTO v_is_admin;
  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_user_a IS NULL OR p_user_b IS NULL OR p_user_a = p_user_b THEN
    RAISE EXCEPTION 'two different user ids are required';
  END IF;

  BEGIN
    SELECT public._get_max_match_occurrence() INTO v_max_occurrence;
  EXCEPTION WHEN undefined_function THEN
    v_max_occurrence := 3;
  END;

  SELECT COALESCE(up.expiry_count, 0), COALESCE(up.is_permanent, false)
    INTO v_expiry_count, v_is_permanent
  FROM public.unmatched_pairs up
  WHERE (up.user1_id = LEAST(p_user_a, p_user_b)
      AND up.user2_id = GREATEST(p_user_a, p_user_b));

  RETURN jsonb_build_object(
    'match_opportunity_count', v_expiry_count,
    'match_opportunities_exhausted', v_expiry_count >= v_max_occurrence,
    'match_opportunities_permanent', v_is_permanent,
    'match_opportunity_limit', v_max_occurrence
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_match_pair_status(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_match_pair_status(uuid, uuid) TO service_role;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchInspectorOpportunitiesExhausted', 'No chat after {count} match opportunities; will not match again'),
  ('es', 'matchInspectorOpportunitiesExhausted', 'Sin chat después de {count} oportunidades de match; no volverán a coincidir'),
  ('he', 'matchInspectorOpportunitiesExhausted', 'לא היה צ׳אט לאחר {count} הזדמנויות התאמה; הם לא יותאמו שוב')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
