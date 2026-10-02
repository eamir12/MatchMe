-- Audit fixes for admin broadcast system (2026-09-22 deep dive).
-- Covers: case-insensitive matches, NULL language defaults to en,
-- user_ids exclusive + language preserved for display, DISTINCT ON one
-- device per user, frequency guard in list preview, optimized count,
-- resend/reschedule from failed/cancelled, composite idempotency key,
-- resend via scheduled+cron (no single-shot 20k timeout), stats pending,
-- health admin check, admin RLS for deliveries + queue (dashboard).
BEGIN;

-- 1) Normalize: keep ui_language(s) alongside user_ids for display,
-- deterministic 500 cap, empty stays {} (UI maps to all_users).
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
  v_user_ids text[];
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

  -- user_ids: validate UUIDs, deterministic ORDER BY, cap 500.
  IF c ? 'user_ids' AND jsonb_typeof(c->'user_ids') = 'array' THEN
    SELECT array_agg(value ORDER BY value) INTO v_user_ids
    FROM (
      SELECT DISTINCT lower(btrim(value)) AS value
      FROM jsonb_array_elements_text(c->'user_ids') AS t(value)
      WHERE lower(btrim(value)) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      ORDER BY 1
      LIMIT 500
    ) s
    WHERE value <> '';
    IF v_user_ids IS NOT NULL AND array_length(v_user_ids, 1) > 0 THEN
      out := out || jsonb_build_object('user_ids', to_jsonb(v_user_ids));
      -- Preserve language tags for display; delivery treats user_ids
      -- as exclusive (see get_users_for_broadcast).
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
        v_int := v_min; v_min := v_max; v_max := v_int;
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
    BEGIN v_int := (c->>'last_active_days')::int; EXCEPTION WHEN OTHERS THEN v_int := NULL; END;
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

-- 2) get_users_for_broadcast: exclusive user_ids, case-insensitive,
-- NULL lang -> en, DISTINCT ON one device per user (latest session).
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
  IF auth.role() = 'service_role' THEN v_is_allowed := true;
  ELSE
    SELECT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) INTO v_is_allowed;
  END IF;
  IF NOT COALESCE(v_is_allowed, false) THEN RAISE EXCEPTION 'not authorized'; END IF;

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
  SELECT t.user_id, t.fcm_token, t.platform FROM (
    SELECT DISTINCT ON (u.id)
      u.id AS user_id,
      us.metadata->>'fcm_token' AS fcm_token,
      us.platform AS platform,
      us.last_active_at AS la
    FROM public.users u
    JOIN public.user_session us ON u.id = us.user_id
    WHERE us.revoked = false
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
      AND COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) = true
      AND COALESCE(
        (u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
        (u.notification_preferences->>'enable_admin_notifications')::boolean, true) = true
      AND (
        -- Exclusive recipients mode: ignore all other filters.
        (v_user_ids IS NOT NULL AND u.id = ANY(v_user_ids))
        OR (
          v_user_ids IS NULL AND (
            COALESCE((c->>'all_users')::boolean, false) = true OR (
              (c->'gender' IS NULL OR lower(COALESCE(u.gender,'')) = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'gender')))) AND
              (c->'age_range' IS NULL OR (EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) >= (c->'age_range'->>'min')::int AND EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) <= (c->'age_range'->>'max')::int)) AND
              (v_tiers IS NULL OR lower(COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free')) = ANY(v_tiers)) AND
              (c->'verification_status' IS NULL OR lower(COALESCE(u.verification_status,'')) = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'verification_status')))) AND
              (c->'platform' IS NULL OR lower(COALESCE(us.platform,'')) = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'platform')))) AND
              (c->'last_active_days' IS NULL OR us.last_active_at >= NOW() - INTERVAL '1 day' * (c->>'last_active_days')::int) AND
              (v_status = '' OR v_status = 'all'
                OR (v_status = 'visible' AND public.is_user_truly_visible(u.id) = TRUE)
                OR (v_status = 'invisible' AND public.is_user_online(u.id) = TRUE AND public.is_user_truly_visible(u.id) = FALSE)
                OR (v_status = 'offline' AND public.is_user_online(u.id) = FALSE)) AND
              (c->'ui_language' IS NULL OR COALESCE(NULLIF(lower(btrim(COALESCE(u.preferred_language,''))),''),'en') = lower(c->>'ui_language')) AND
              (c->'ui_languages' IS NULL OR COALESCE(NULLIF(lower(btrim(COALESCE(u.preferred_language,''))),''),'en') = ANY(ARRAY(SELECT lower(jsonb_array_elements_text(c->'ui_languages')))))
            )
          )
        )
      )
    ORDER BY u.id, us.last_active_at DESC NULLS LAST
  ) t
  WHERE t.fcm_token IS NOT NULL AND btrim(t.fcm_token) <> '';
END;
$$;

-- 3) List preview: same matching + configurable frequency guard so
-- count == list == send.
CREATE OR REPLACE FUNCTION public.admin_list_target_users_for_broadcast(
  filter_criteria jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS TABLE (user_id uuid, name text, platform text, last_active_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_allowed boolean;
  v_limit integer; v_offset integer; c jsonb; v_status text; v_tiers text[]; v_user_ids uuid[]; v_freq_limit int;
BEGIN
  IF auth.role() = 'service_role' THEN v_is_allowed := true;
  ELSE SELECT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) INTO v_is_allowed; END IF;
  IF NOT COALESCE(v_is_allowed, false) THEN RAISE EXCEPTION 'not authorized'; END IF;
  v_limit := GREATEST(LEAST(COALESCE(p_limit, 50), 500), 1);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);
  c := public.normalize_broadcast_filter_criteria(filter_criteria);
  v_status := lower(btrim(COALESCE(c->>'status', '')));
  IF c ? 'subscription_tiers' THEN
    SELECT array_agg(lower(btrim(value))) INTO v_tiers FROM jsonb_array_elements_text(c->'subscription_tiers') AS t(value);
  END IF;
  IF c ? 'user_ids' THEN
    SELECT array_agg(DISTINCT value::uuid) INTO v_user_ids FROM jsonb_array_elements_text(c->'user_ids') AS t(value);
  END IF;
  BEGIN v_freq_limit := GREATEST(public.app_config_int('notifications.admin_broadcast_max_per_day', 10), 1);
  EXCEPTION WHEN OTHERS THEN v_freq_limit := 10; END;

  RETURN QUERY
  SELECT * FROM (
    SELECT DISTINCT ON (u.id) u.id AS user_id, u.name, us.platform, us.last_active_at
    FROM public.users u
    JOIN public.user_session us ON u.id = us.user_id
    WHERE us.revoked = false
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
      AND COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) = true
      AND COALESCE((u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
        (u.notification_preferences->>'enable_admin_notifications')::boolean, true) = true
      AND (
        SELECT COUNT(*) FROM public.notification_queue q
        WHERE q.user_id = u.id AND q.created_at >= NOW() - INTERVAL '1 day'
          AND (q.data->>'type') = 'admin_broadcast'
      ) < v_freq_limit
      AND (
        (v_user_ids IS NOT NULL AND u.id = ANY(v_user_ids)) OR
        (v_user_ids IS NULL AND (
          COALESCE((c->>'all_users')::boolean, false) = true OR (
            (c->'gender' IS NULL OR lower(COALESCE(u.gender,'')) = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'gender')))) AND
            (c->'age_range' IS NULL OR (EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) >= (c->'age_range'->>'min')::int AND EXTRACT(YEAR FROM AGE(CURRENT_DATE, u.date_of_birth)) <= (c->'age_range'->>'max')::int)) AND
            (v_tiers IS NULL OR lower(COALESCE(NULLIF(btrim(COALESCE(u.subscription_tier, '')), ''), 'free')) = ANY(v_tiers)) AND
            (c->'verification_status' IS NULL OR lower(COALESCE(u.verification_status,'')) = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'verification_status')))) AND
            (c->'platform' IS NULL OR lower(COALESCE(us.platform,'')) = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'platform')))) AND
            (c->'last_active_days' IS NULL OR us.last_active_at >= NOW() - INTERVAL '1 day' * (c->>'last_active_days')::int) AND
            (v_status = '' OR v_status = 'all'
              OR (v_status = 'visible' AND public.is_user_truly_visible(u.id) = TRUE)
              OR (v_status = 'invisible' AND public.is_user_online(u.id) = TRUE AND public.is_user_truly_visible(u.id) = FALSE)
              OR (v_status = 'offline' AND public.is_user_online(u.id) = FALSE)) AND
            (c->'ui_language' IS NULL OR COALESCE(NULLIF(lower(btrim(COALESCE(u.preferred_language,''))),''),'en') = lower(c->>'ui_language')) AND
            (c->'ui_languages' IS NULL OR COALESCE(NULLIF(lower(btrim(COALESCE(u.preferred_language,''))),''),'en') = ANY(ARRAY(SELECT lower(jsonb_array_elements_text(c->'ui_languages')))))
          )))
      )
    ORDER BY u.id, us.last_active_at DESC NULLS LAST
  ) t
  ORDER BY t.last_active_at DESC NULLS LAST, t.user_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

-- 4) Optimized count: single aggregation join instead of N+1 subqueries.
CREATE OR REPLACE FUNCTION public.count_target_users(filter_criteria jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_is_allowed boolean; user_count integer; v_freq_limit int;
BEGIN
  IF auth.role() = 'service_role' THEN v_is_allowed := true;
  ELSE SELECT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) INTO v_is_allowed; END IF;
  IF NOT COALESCE(v_is_allowed, false) THEN RAISE EXCEPTION 'not authorized'; END IF;
  BEGIN v_freq_limit := GREATEST(public.app_config_int('notifications.admin_broadcast_max_per_day', 10), 1);
  EXCEPTION WHEN OTHERS THEN v_freq_limit := 10; END;
  SELECT COUNT(*) INTO user_count FROM (
    SELECT g.user_id FROM public.get_users_for_broadcast(filter_criteria) g
    LEFT JOIN LATERAL (
      SELECT COUNT(*) AS c FROM public.notification_queue q
      WHERE q.user_id = g.user_id AND q.created_at >= NOW() - INTERVAL '1 day'
        AND (q.data->>'type') = 'admin_broadcast'
    ) qc ON true
    WHERE COALESCE(qc.c, 0) < v_freq_limit
  ) t;
  RETURN COALESCE(user_count, 0);
END;
$$;

-- 5) Stats: add pending_count (backward compatible extra column).
DROP FUNCTION IF EXISTS public.get_broadcast_stats(uuid);
CREATE OR REPLACE FUNCTION public.get_broadcast_stats(p_broadcast_id uuid)
RETURNS TABLE(total_target integer, sent_count integer, delivered_count integer, failed_count integer, pending_count integer, delivery_rate numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT COUNT(*)::integer,
    COUNT(*) FILTER (WHERE abd.delivery_status = 'sent')::integer,
    COUNT(*) FILTER (WHERE abd.delivery_status = 'delivered')::integer,
    COUNT(*) FILTER (WHERE abd.delivery_status = 'failed')::integer,
    COUNT(*) FILTER (WHERE abd.delivery_status = 'pending')::integer,
    ROUND((COUNT(*) FILTER (WHERE abd.delivery_status = 'delivered')::numeric / NULLIF(COUNT(*),0) * 100),2)
  FROM public.admin_broadcast_deliveries abd WHERE abd.broadcast_id = p_broadcast_id;
END;
$$;
REVOKE ALL ON FUNCTION public.get_broadcast_stats(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broadcast_stats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_broadcast_stats(uuid) TO service_role;

-- 6) Health: require admin.
CREATE OR REPLACE FUNCTION public.get_notification_queue_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_pending int; v_processing int; v_failed_1h int; v_sent_1h int; v_oldest_pending timestamptz; v_oldest_age_sec int;
BEGIN
  IF auth.role() <> 'service_role' THEN
    IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) THEN
      RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
    END IF;
  END IF;
  SELECT COUNT(*) INTO v_pending FROM public.notification_queue WHERE status = 'pending';
  SELECT COUNT(*) INTO v_processing FROM public.notification_queue WHERE status = 'processing';
  SELECT COUNT(*) INTO v_failed_1h FROM public.notification_queue WHERE status = 'failed' AND updated_at >= NOW() - INTERVAL '1 hour';
  SELECT COUNT(*) INTO v_sent_1h FROM public.notification_queue WHERE status = 'sent' AND sent_at >= NOW() - INTERVAL '1 hour';
  SELECT MIN(created_at) INTO v_oldest_pending FROM public.notification_queue WHERE status = 'pending';
  IF v_oldest_pending IS NULL THEN v_oldest_age_sec := 0;
  ELSE v_oldest_age_sec := EXTRACT(EPOCH FROM (NOW() - v_oldest_pending))::INT; END IF;
  RETURN jsonb_build_object('pending', COALESCE(v_pending,0),'processing', COALESCE(v_processing,0),
    'failed_last_hour', COALESCE(v_failed_1h,0),'sent_last_hour', COALESCE(v_sent_1h,0),
    'oldest_pending_at', v_oldest_pending,'oldest_pending_age_sec', v_oldest_age_sec,
    'alert', (COALESCE(v_pending,0) > 1000 OR v_oldest_age_sec > 600 OR COALESCE(v_failed_1h,0) > 50));
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_notification_queue_health() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_notification_queue_health() TO service_role;

-- 7) Idempotency: composite (source, request) instead of global request.
DROP INDEX IF EXISTS idx_admin_broadcasts_resend_request_unique;
DROP INDEX IF EXISTS idx_admin_broadcasts_resend_source;
CREATE INDEX idx_admin_broadcasts_resend_source ON public.admin_broadcasts (resend_source_broadcast_id, created_at) WHERE resend_source_broadcast_id IS NOT NULL;
CREATE UNIQUE INDEX idx_admin_broadcasts_resend_request_unique ON public.admin_broadcasts (resend_source_broadcast_id, resend_request_id) WHERE resend_request_id IS NOT NULL AND resend_source_broadcast_id IS NOT NULL;

-- 8) Resend: allow sent/failed/cancelled sources, queue via scheduled+cron
-- (avoids single-shot 20k timeout). Keeps idempotency.
DROP FUNCTION IF EXISTS public.admin_resend_broadcast_now(uuid);
DROP FUNCTION IF EXISTS public.admin_resend_broadcast_now(uuid, text);
CREATE OR REPLACE FUNCTION public.admin_resend_broadcast_now(p_broadcast_id uuid, p_request_id text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_is_allowed boolean; v_new uuid; v_existing uuid; v_src public.admin_broadcasts%ROWTYPE; v_key text;
BEGIN
  IF auth.role() = 'service_role' THEN v_is_allowed := true;
  ELSE SELECT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) INTO v_is_allowed; END IF;
  IF NOT COALESCE(v_is_allowed,false) THEN RAISE EXCEPTION 'not authorized'; END IF;
  v_key := NULLIF(btrim(COALESCE(p_request_id,'')), '');
  SELECT * INTO v_src FROM public.admin_broadcasts b WHERE b.id = p_broadcast_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Broadcast not found'; END IF;
  IF COALESCE(v_src.status,'') NOT IN ('sent','failed','cancelled') THEN RAISE EXCEPTION 'broadcast must be sent, failed or cancelled'; END IF;
  IF v_key IS NOT NULL THEN
    SELECT c.id INTO v_existing FROM public.admin_broadcasts c
    WHERE c.resend_source_broadcast_id = p_broadcast_id AND c.resend_request_id = v_key;
    IF FOUND THEN RETURN v_existing; END IF;
  END IF;
  BEGIN
    INSERT INTO public.admin_broadcasts (title,message,message_type,automation_type,automation_enabled,action_url,action_url_text,scheduled_at,sent_at,status,filter_criteria,target_user_count,actual_sent_count,skipped_count,created_by,created_at,updated_at,resend_source_broadcast_id,resend_request_id)
    VALUES (v_src.title,v_src.message,v_src.message_type,v_src.automation_type,v_src.automation_enabled,v_src.action_url,v_src.action_url_text,now(),NULL,'scheduled',v_src.filter_criteria,NULL,0,0,auth.uid(),now(),now(),p_broadcast_id,v_key)
    RETURNING id INTO v_new;
  EXCEPTION WHEN unique_violation THEN
    SELECT c.id INTO v_existing FROM public.admin_broadcasts c WHERE c.resend_source_broadcast_id = p_broadcast_id AND c.resend_request_id = v_key;
    IF FOUND THEN RETURN v_existing; END IF;
    RAISE;
  END;
  RETURN v_new;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resend_broadcast_now(uuid, text) TO service_role;

-- 9) Reschedule: allow sent/failed/cancelled sources.
CREATE OR REPLACE FUNCTION public.admin_reschedule_broadcast(p_broadcast_id uuid, p_scheduled_at timestamptz)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_is_allowed boolean; v_new uuid; v_src public.admin_broadcasts%ROWTYPE; v_sched timestamptz;
BEGIN
  IF auth.role() = 'service_role' THEN v_is_allowed := true;
  ELSE SELECT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) INTO v_is_allowed; END IF;
  IF NOT COALESCE(v_is_allowed,false) THEN RAISE EXCEPTION 'not authorized'; END IF;
  v_sched := p_scheduled_at;
  IF v_sched IS NULL THEN RAISE EXCEPTION 'p_scheduled_at is required'; END IF;
  IF v_sched <= now() THEN RAISE EXCEPTION 'p_scheduled_at must be in the future'; END IF;
  SELECT * INTO v_src FROM public.admin_broadcasts b WHERE b.id = p_broadcast_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Broadcast not found'; END IF;
  IF COALESCE(v_src.status,'') NOT IN ('sent','failed','cancelled') THEN RAISE EXCEPTION 'broadcast must be sent, failed or cancelled'; END IF;
  INSERT INTO public.admin_broadcasts (title,message,message_type,automation_type,automation_enabled,action_url,action_url_text,scheduled_at,sent_at,status,filter_criteria,target_user_count,actual_sent_count,skipped_count,created_by,created_at,updated_at)
  VALUES (v_src.title,v_src.message,v_src.message_type,v_src.automation_type,v_src.automation_enabled,v_src.action_url,v_src.action_url_text,v_sched,NULL,'scheduled',v_src.filter_criteria,NULL,0,0,auth.uid(),now(),now())
  RETURNING id INTO v_new;
  RETURN v_new;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_reschedule_broadcast(uuid, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reschedule_broadcast(uuid, timestamptz) TO service_role;

-- 10) RLS: admins can read deliveries + queue for dashboards; users keep own.
DROP POLICY IF EXISTS "Admins can view all deliveries" ON public.admin_broadcast_deliveries;
CREATE POLICY "Admins can view all deliveries" ON public.admin_broadcast_deliveries FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true)
);
DROP POLICY IF EXISTS "Admins can view notification queue" ON public.notification_queue;
CREATE POLICY "Admins can view notification queue" ON public.notification_queue FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true)
);

GRANT EXECUTE ON FUNCTION public.normalize_broadcast_filter_criteria(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_users_for_broadcast(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.count_target_users(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_target_users_for_broadcast(jsonb, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_broadcast_filter_criteria(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_users_for_broadcast(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.count_target_users(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_target_users_for_broadcast(jsonb, integer, integer) TO service_role;

COMMIT;
