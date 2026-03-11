BEGIN;

DROP FUNCTION IF EXISTS public.admin_list_target_users_for_broadcast(jsonb, integer, integer);

CREATE OR REPLACE FUNCTION public.admin_list_target_users_for_broadcast(
  filter_criteria jsonb,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  user_id uuid,
  name text,
  platform text,
  last_active_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_allowed boolean;
  v_limit integer;
  v_offset integer;
BEGIN
  IF auth.role() = 'service_role' THEN
    v_is_allowed := true;
  ELSE
    SELECT EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = true
    ) INTO v_is_allowed;
  END IF;

  IF NOT COALESCE(v_is_allowed, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 50), 500), 1);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);

  RETURN QUERY
  SELECT *
  FROM (
    SELECT DISTINCT ON (u.id)
      u.id AS user_id,
      u.name,
      us.platform,
      us.last_active_at
    FROM public.users u
    JOIN public.user_session us ON u.id = us.user_id
    WHERE us.revoked = false
      AND us.metadata->>'fcm_token' IS NOT NULL
      AND (
        (filter_criteria->>'all_users')::boolean = true OR
        (
          (filter_criteria->'gender' IS NULL OR
            u.gender = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'gender')))) AND
          (filter_criteria->'age_range' IS NULL OR
            (EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) >= (filter_criteria->'age_range'->>'min')::int AND
            EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) <= (filter_criteria->'age_range'->>'max')::int)) AND
          (filter_criteria->'subscription_tiers' IS NULL OR
            u.subscription_tier = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'subscription_tiers')))) AND
          (filter_criteria->'verification_status' IS NULL OR
            u.verification_status = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'verification_status')))) AND
          (filter_criteria->'platform' IS NULL OR
            us.platform = ANY(ARRAY(SELECT jsonb_array_elements_text(filter_criteria->'platform')))) AND
          (filter_criteria->'last_active_days' IS NULL OR
            us.last_active_at >= NOW() - INTERVAL '1 day' * (filter_criteria->>'last_active_days')::int) AND
          (filter_criteria->'visible_only' IS NULL OR
            (filter_criteria->>'visible_only')::boolean = false OR
            u.system_visibility_status = 'visible') AND
          (
            filter_criteria->'ui_language' IS NULL OR
            lower(coalesce(u.preferred_language, '')) = lower(filter_criteria->>'ui_language')
          ) AND
          (
            filter_criteria->'ui_languages' IS NULL OR
            lower(coalesce(u.preferred_language, '')) = ANY(
              ARRAY(
                SELECT lower(jsonb_array_elements_text(filter_criteria->'ui_languages'))
              )
            )
          )
        )
      )
    ORDER BY u.id, us.last_active_at DESC NULLS LAST
  ) t
  ORDER BY t.last_active_at DESC NULLS LAST, t.user_id DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_list_target_users_for_broadcast(jsonb, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_target_users_for_broadcast(jsonb, integer, integer) TO service_role;

COMMIT;

