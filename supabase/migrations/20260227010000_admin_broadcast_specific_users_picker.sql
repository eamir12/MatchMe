BEGIN;

CREATE OR REPLACE FUNCTION public.normalize_broadcast_filter_criteria(p_criteria jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c jsonb := COALESCE(p_criteria, '{}'::jsonb);
  out jsonb := '{}'::jsonb;

  v_bool boolean;
  v_int integer;
  v_min integer;
  v_max integer;
  v_text text;
  v_status text;
  arr text[];
BEGIN
  IF jsonb_typeof(c) IS DISTINCT FROM 'object' THEN
    c := '{}'::jsonb;
  END IF;

  BEGIN
    v_bool := COALESCE((c->>'all_users')::boolean, false);
  EXCEPTION WHEN OTHERS THEN
    v_bool := false;
  END;

  IF v_bool THEN
    RETURN jsonb_build_object('all_users', true);
  END IF;

  IF c ? 'user_ids' AND jsonb_typeof(c->'user_ids') = 'array' THEN
    SELECT array_agg(DISTINCT value) INTO arr
    FROM (
      SELECT lower(btrim(value)) AS value
      FROM jsonb_array_elements_text(c->'user_ids') AS t(value)
      WHERE lower(btrim(value)) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      LIMIT 500
    ) s
    WHERE value <> '';

    IF arr IS NOT NULL AND array_length(arr, 1) > 0 THEN
      RETURN jsonb_build_object('user_ids', to_jsonb(arr));
    END IF;
  END IF;

  v_status := lower(btrim(COALESCE(c->>'status', '')));
  IF v_status = '' THEN
    v_status := lower(btrim(COALESCE(c->>'visibility', '')));
  END IF;
  IF v_status = '' THEN
    BEGIN
      IF COALESCE((c->>'visible_only')::boolean, false) THEN
        v_status := 'visible';
      END IF;
    EXCEPTION WHEN OTHERS THEN
    END;
  END IF;

  IF v_status IN ('visible', 'invisible', 'offline') THEN
    out := out || jsonb_build_object('status', v_status);
  END IF;

  IF c ? 'gender' AND jsonb_typeof(c->'gender') = 'array' THEN
    SELECT array_agg(DISTINCT lower(btrim(value))) INTO arr
    FROM jsonb_array_elements_text(c->'gender') AS t(value)
    WHERE btrim(value) <> '';
    IF arr IS NOT NULL AND array_length(arr, 1) > 0 THEN
      out := out || jsonb_build_object('gender', to_jsonb(arr));
    END IF;
  END IF;

  IF c ? 'age_range' AND jsonb_typeof(c->'age_range') = 'object' THEN
    BEGIN
      v_min := (c->'age_range'->>'min')::int;
      v_max := (c->'age_range'->>'max')::int;
    EXCEPTION WHEN OTHERS THEN
      v_min := NULL;
      v_max := NULL;
    END;
    IF v_min IS NOT NULL AND v_max IS NOT NULL THEN
      v_min := GREATEST(18, LEAST(v_min, 80));
      v_max := GREATEST(18, LEAST(v_max, 80));
      IF v_min > v_max THEN
        v_int := v_min;
        v_min := v_max;
        v_max := v_int;
      END IF;
      out := out || jsonb_build_object('age_range', jsonb_build_object('min', v_min, 'max', v_max));
    END IF;
  END IF;

  IF c ? 'subscription_tiers' AND jsonb_typeof(c->'subscription_tiers') = 'array' THEN
    SELECT array_agg(DISTINCT lower(btrim(value))) INTO arr
    FROM jsonb_array_elements_text(c->'subscription_tiers') AS t(value)
    WHERE btrim(value) <> '';
    IF arr IS NOT NULL AND array_length(arr, 1) > 0 THEN
      out := out || jsonb_build_object('subscription_tiers', to_jsonb(arr));
    END IF;
  END IF;

  IF c ? 'verification_status' AND jsonb_typeof(c->'verification_status') = 'array' THEN
    SELECT array_agg(DISTINCT lower(btrim(value))) INTO arr
    FROM jsonb_array_elements_text(c->'verification_status') AS t(value)
    WHERE lower(btrim(value)) = ANY(ARRAY['unverified','analyzing','pending','approved','rejected']);
    IF arr IS NOT NULL AND array_length(arr, 1) > 0 THEN
      out := out || jsonb_build_object('verification_status', to_jsonb(arr));
    END IF;
  END IF;

  IF c ? 'platform' AND jsonb_typeof(c->'platform') = 'array' THEN
    SELECT array_agg(DISTINCT lower(btrim(value))) INTO arr
    FROM jsonb_array_elements_text(c->'platform') AS t(value)
    WHERE lower(btrim(value)) = ANY(ARRAY['android','ios','web','macos','windows','linux','unknown']);
    IF arr IS NOT NULL AND array_length(arr, 1) > 0 THEN
      out := out || jsonb_build_object('platform', to_jsonb(arr));
    END IF;
  END IF;

  IF c ? 'last_active_days' THEN
    BEGIN
      v_int := (c->>'last_active_days')::int;
    EXCEPTION WHEN OTHERS THEN
      v_int := NULL;
    END;
    IF v_int IS NOT NULL AND v_int > 0 AND v_int <= 3650 THEN
      out := out || jsonb_build_object('last_active_days', v_int);
    END IF;
  END IF;

  v_text := lower(btrim(COALESCE(c->>'ui_language', '')));
  IF v_text IN ('en','es','he') THEN
    out := out || jsonb_build_object('ui_language', v_text);
  END IF;

  IF c ? 'ui_languages' AND jsonb_typeof(c->'ui_languages') = 'array' THEN
    SELECT array_agg(DISTINCT lower(btrim(value))) INTO arr
    FROM jsonb_array_elements_text(c->'ui_languages') AS t(value)
    WHERE lower(btrim(value)) = ANY(ARRAY['en','es','he']);
    IF arr IS NOT NULL AND array_length(arr, 1) > 0 THEN
      out := out || jsonb_build_object('ui_languages', to_jsonb(arr));
    END IF;
  END IF;

  RETURN out;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_users_for_broadcast(filter_criteria jsonb)
RETURNS TABLE(user_id uuid, fcm_token text, platform text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_allowed boolean;
  c jsonb;
  v_status text;
  v_tiers text[];
  v_user_ids uuid[];
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

  c := public.normalize_broadcast_filter_criteria(filter_criteria);
  v_status := lower(btrim(COALESCE(c->>'status', '')));

  IF c ? 'subscription_tiers' THEN
    SELECT array_agg(lower(btrim(value))) INTO v_tiers
    FROM jsonb_array_elements_text(c->'subscription_tiers') AS t(value);
  END IF;

  IF c ? 'user_ids' THEN
    SELECT array_agg(DISTINCT value::uuid) INTO v_user_ids
    FROM jsonb_array_elements_text(c->'user_ids') AS t(value);
  END IF;

  RETURN QUERY
  SELECT DISTINCT u.id, us.metadata->>'fcm_token', us.platform
  FROM public.users u
  JOIN public.user_session us ON u.id = us.user_id
  WHERE us.revoked = false
    AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
    AND COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) = true
    AND COALESCE(
      (u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
      (u.notification_preferences->>'enable_admin_notifications')::boolean,
      true
    ) = true
    AND (
      (v_user_ids IS NOT NULL AND u.id = ANY(v_user_ids)) OR
      (
        COALESCE((c->>'all_users')::boolean, false) = true OR
        (
          (c->'gender' IS NULL OR
            u.gender = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'gender')))) AND
          (c->'age_range' IS NULL OR
            (EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) >= (c->'age_range'->>'min')::int AND
            EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) <= (c->'age_range'->>'max')::int)) AND
          (
            v_tiers IS NULL OR
            COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') = ANY(v_tiers)
          ) AND
          (c->'verification_status' IS NULL OR
            u.verification_status = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'verification_status')))) AND
          (c->'platform' IS NULL OR
            us.platform = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'platform')))) AND
          (c->'last_active_days' IS NULL OR
            us.last_active_at >= NOW() - INTERVAL '1 day' * (c->>'last_active_days')::int) AND
          (
            v_status = '' OR v_status = 'all' OR
            (v_status = 'visible' AND public.is_user_truly_visible(u.id) = TRUE) OR
            (v_status = 'invisible' AND public.is_user_online(u.id) = TRUE AND public.is_user_truly_visible(u.id) = FALSE) OR
            (v_status = 'offline' AND public.is_user_online(u.id) = FALSE)
          ) AND
          (
            c->'ui_language' IS NULL OR
            lower(coalesce(u.preferred_language, '')) = lower(c->>'ui_language')
          ) AND
          (
            c->'ui_languages' IS NULL OR
            lower(coalesce(u.preferred_language, '')) = ANY(
              ARRAY(
                SELECT lower(jsonb_array_elements_text(c->'ui_languages'))
              )
            )
          )
        )
      )
    );
END;
$$;

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
  c jsonb;
  v_status text;
  v_tiers text[];
  v_user_ids uuid[];
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

  c := public.normalize_broadcast_filter_criteria(filter_criteria);
  v_status := lower(btrim(COALESCE(c->>'status', '')));
  IF c ? 'subscription_tiers' THEN
    SELECT array_agg(lower(btrim(value))) INTO v_tiers
    FROM jsonb_array_elements_text(c->'subscription_tiers') AS t(value);
  END IF;

  IF c ? 'user_ids' THEN
    SELECT array_agg(DISTINCT value::uuid) INTO v_user_ids
    FROM jsonb_array_elements_text(c->'user_ids') AS t(value);
  END IF;

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
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
      AND COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) = true
      AND COALESCE(
        (u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
        (u.notification_preferences->>'enable_admin_notifications')::boolean,
        true
      ) = true
      AND (
        (v_user_ids IS NOT NULL AND u.id = ANY(v_user_ids)) OR
        (
          COALESCE((c->>'all_users')::boolean, false) = true OR
          (
            (c->'gender' IS NULL OR
              u.gender = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'gender')))) AND
            (c->'age_range' IS NULL OR
              (EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) >= (c->'age_range'->>'min')::int AND
              EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) <= (c->'age_range'->>'max')::int)) AND
            (
              v_tiers IS NULL OR
              COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free') = ANY(v_tiers)
            ) AND
            (c->'verification_status' IS NULL OR
              u.verification_status = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'verification_status')))) AND
            (c->'platform' IS NULL OR
              us.platform = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'platform')))) AND
            (c->'last_active_days' IS NULL OR
              us.last_active_at >= NOW() - INTERVAL '1 day' * (c->>'last_active_days')::int) AND
            (
              v_status = '' OR v_status = 'all' OR
              (v_status = 'visible' AND public.is_user_truly_visible(u.id) = TRUE) OR
              (v_status = 'invisible' AND public.is_user_online(u.id) = TRUE AND public.is_user_truly_visible(u.id) = FALSE) OR
              (v_status = 'offline' AND public.is_user_online(u.id) = FALSE)
            ) AND
            (
              c->'ui_language' IS NULL OR
              lower(coalesce(u.preferred_language, '')) = lower(c->>'ui_language')
            ) AND
            (
              c->'ui_languages' IS NULL OR
              lower(coalesce(u.preferred_language, '')) = ANY(
                ARRAY(
                  SELECT lower(jsonb_array_elements_text(c->'ui_languages'))
                )
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

CREATE OR REPLACE FUNCTION public.admin_search_users(
  p_query text,
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
  q text;
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

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 50), 200), 1);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);
  q := btrim(COALESCE(p_query, ''));

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
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
      AND COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) = true
      AND COALESCE(
        (u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
        (u.notification_preferences->>'enable_admin_notifications')::boolean,
        true
      ) = true
      AND (
        q = '' OR
        u.id::text ILIKE ('%' || q || '%') OR
        COALESCE(u.name, '') ILIKE ('%' || q || '%')
      )
    ORDER BY u.id, us.last_active_at DESC NULLS LAST
  ) t
  ORDER BY t.last_active_at DESC NULLS LAST, t.user_id DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_get_user_ui_languages(p_user_ids uuid[])
RETURNS TABLE (
  user_id uuid,
  ui_language text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_allowed boolean;
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

  RETURN QUERY
  SELECT
    u.id AS user_id,
    CASE lower(btrim(COALESCE(u.preferred_language, '')))
      WHEN 'es' THEN 'es'
      WHEN 'he' THEN 'he'
      ELSE 'en'
    END AS ui_language
  FROM public.users u
  WHERE p_user_ids IS NOT NULL
    AND u.id = ANY(p_user_ids);
END;
$$;

GRANT EXECUTE ON FUNCTION public.normalize_broadcast_filter_criteria(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_users_for_broadcast(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_target_users_for_broadcast(jsonb, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_search_users(text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_user_ui_languages(uuid[]) TO authenticated;

GRANT EXECUTE ON FUNCTION public.normalize_broadcast_filter_criteria(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_users_for_broadcast(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_target_users_for_broadcast(jsonb, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_search_users(text, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_user_ui_languages(uuid[]) TO service_role;

COMMIT;
