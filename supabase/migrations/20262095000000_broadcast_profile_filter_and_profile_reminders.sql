-- Migration: Broadcast profile-completion filter + automatic profile reminders
-- Date: 2026-10-05
-- Depends on: 20262035000000 (broadcast targeting functions),
--             20262094000000 (presence counts exclude incomplete profiles)
--
-- Two features:
--
-- A) Admin broadcast targeting gains a `profile_completion` filter key
--    ('complete' / 'incomplete'), so admins can target e.g. only users who
--    have NOT finished their profiles and send them a reminder broadcast
--    from the UI. Unknown criteria keys are silently dropped by
--    normalize_broadcast_filter_criteria, so this key must be added there
--    first, then honored in get_users_for_broadcast (count_target_users
--    delegates to it) and admin_list_target_users_for_broadcast (duplicates
--    the WHERE chain by design).
--
-- B) Automatic "complete your profile" reminders (mirrors the birthday
--    automation): a cron task in the cron-jobs edge function claims due
--    users through claim_profile_reminder_candidates() and queues a
--    localized push (type 'admin_broadcast', so the full existing client
--    display path — in-app overlay, OS tray, per-user prefs, Android
--    channels — applies, exactly like the birthday notification).
--
--    Schedule semantics ("X hours after app was closed"): the app's last
--    heartbeat is user_activity.last_activity; while the app runs it keeps
--    advancing, so it IS the closure clock. Defaults: reminder at 1h closed,
--    another at 5h closed, then every 24h after that (5h + 24h * k), for as
--    long as the profile stays incomplete. Reopening the app restarts the
--    cycle (a fresh closure starts over at 1h). All intervals are
--    configurable via app_config (notifications.profile_reminder.*).
--
--    Recipients must be reachable exactly like broadcasts: non-revoked
--    session with an FCM token + push prefs enabled. Admins and deleted
--    users are never reminded; users deleted by cleanup_incomplete_signup_users
--    (name IS NULL after 7 days) simply stop existing — state rows cascade.
--
-- Deliberately NOT changed: cleanup_incomplete_signup_users(), the presence
-- counters (20262094000000), or any broadcast default audience.

BEGIN;

-- =============================================================
-- A) Broadcast filter: profile_completion ('complete'/'incomplete')
-- =============================================================

-- 1) Normalizer: full def from 20262035000000 with the new key added.
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

  -- Profile completion: 'complete' and/or 'incomplete'. Selecting both is
  -- equivalent to no filter (kept, not dropped, for explicitness).
  IF c ? 'profile_completion' AND jsonb_typeof(c->'profile_completion') = 'array' THEN
    SELECT array_agg(DISTINCT lower(btrim(value))) INTO arr
    FROM jsonb_array_elements_text(c->'profile_completion') AS t(value)
    WHERE lower(btrim(value)) = ANY(ARRAY['complete','incomplete']);
    IF arr IS NOT NULL AND array_length(arr, 1) > 0 THEN
      out := out || jsonb_build_object('profile_completion', to_jsonb(arr));
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

-- 2) get_users_for_broadcast: full def from 20262035000000 with the
--    profile_completion AND-line added to the filter chain.
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
              (c->'profile_completion' IS NULL OR COALESCE(u.is_profile_complete, false) = ('complete' = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'profile_completion'))))) AND
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

-- 3) List preview: full def from 20262035000000 with the same AND-line.
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
            (c->'profile_completion' IS NULL OR COALESCE(u.is_profile_complete, false) = ('complete' = ANY(ARRAY(SELECT jsonb_array_elements_text(c->'profile_completion'))))) AND
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

-- =============================================================
-- B) Automatic profile-completion reminders
-- =============================================================

-- 4) Reminder state: one row per user; stage = index of the last reminder
--    sent within the current app-closure cycle. last_activity_at pins the
--    closure instant the stage counter is based on; when the user reopens
--    the app it advances, which resets the cycle (see claim function).
CREATE TABLE IF NOT EXISTS public.profile_reminder_state (
  user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  stage integer NOT NULL DEFAULT 0,
  last_activity_at timestamptz NOT NULL,
  last_sent_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.profile_reminder_state ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_profile_reminder_state_updated
  ON public.profile_reminder_state (updated_at);

-- Only the service role (cron edge function) touches this table; it
-- bypasses RLS, so no policies and no grants to anon/authenticated.

-- 5) Atomic claim: computes due stages and advances state rows in ONE
--    statement, so concurrent cron ticks can never double-send.
--
--    due_stage for a user closed for H hours = number of one-off offsets
--    already reached, extended by the repeat tail:
--      count(o in offsets : H >= o), or
--      n_offsets + floor((H - max_offset) / repeat)  when H >= max_offset + repeat
--    A state row is advanced only when the stage grows, or when the closure
--    is newer than the one the stored stage was based on (app was reopened:
--    cycle restarts from the first offset).
CREATE OR REPLACE FUNCTION public.claim_profile_reminder_candidates(
  p_offsets_hours double precision[] DEFAULT ARRAY[1, 5]::double precision[],
  p_repeat_hours double precision DEFAULT 24,
  p_max_reminders integer DEFAULT 0,
  p_limit integer DEFAULT 200
)
RETURNS TABLE (user_id uuid, fcm_token text, platform text, ui_language text, display_name text, stage integer, hours_closed double precision)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sorted double precision[];
  v_n integer;
  v_first double precision;
  v_last double precision;
  v_limit integer;
BEGIN
  SELECT COALESCE(array_agg(DISTINCT o ORDER BY o), ARRAY[]::double precision[])
  INTO v_sorted
  FROM unnest(COALESCE(p_offsets_hours, ARRAY[1, 5]::double precision[])) AS o
  WHERE o IS NOT NULL AND o > 0;
  IF v_sorted IS NULL OR array_length(v_sorted, 1) = 0 THEN
    v_sorted := ARRAY[1.0, 5.0]::double precision[];
  END IF;
  v_n := array_length(v_sorted, 1);
  v_first := v_sorted[1];
  v_last := v_sorted[v_n];
  v_limit := GREATEST(LEAST(COALESCE(p_limit, 200), 2000), 1);

  RETURN QUERY
  WITH cand AS (
    SELECT DISTINCT ON (u.id)
      u.id AS user_id,
      ua.last_activity AS closed_at,
      us.metadata->>'fcm_token' AS fcm_token,
      us.platform AS platform,
      COALESCE(NULLIF(lower(btrim(COALESCE(u.preferred_language, ''))), ''), 'en') AS ui_language,
      COALESCE(u.name, '') AS display_name
    FROM public.users u
    JOIN public.user_activity ua ON ua.user_id = u.id
    JOIN public.user_session us ON us.user_id = u.id
    WHERE us.revoked = false
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
      AND COALESCE(u.is_profile_complete, false) = false
      AND COALESCE(u.is_admin, false) = false
      AND COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) = true
      AND COALESCE(
            (u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
            (u.notification_preferences->>'enable_admin_notifications')::boolean, true) = true
    ORDER BY u.id, us.last_active_at DESC NULLS LAST
  ),
  due AS (
    SELECT
      c.*,
      EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0 AS hours_closed,
      GREATEST(
        (SELECT COUNT(*)::int FROM unnest(v_sorted) AS o
          WHERE (EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) >= o),
        CASE
          WHEN p_repeat_hours > 0
            AND (EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) >= v_last + p_repeat_hours
          THEN v_n + FLOOR(((EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) - v_last) / p_repeat_hours)::int
          ELSE 0
        END
      ) AS due_stage
    FROM cand c
    WHERE (EXTRACT(EPOCH FROM (now() - c.closed_at)) / 3600.0) >= v_first
  ),
  batch AS (
    SELECT * FROM due
    ORDER BY closed_at DESC
    LIMIT v_limit
  ),
  eligible AS (
    SELECT * FROM batch
    WHERE due_stage >= 1
      AND (COALESCE(p_max_reminders, 0) <= 0 OR due_stage <= p_max_reminders)
  ),
  claimed AS (
    INSERT INTO public.profile_reminder_state
      (user_id, stage, last_activity_at, last_sent_at, updated_at)
    SELECT e.user_id, e.due_stage, e.closed_at, now(), now()
    FROM eligible e
    ON CONFLICT (user_id) DO UPDATE
      SET stage = EXCLUDED.stage,
          last_activity_at = EXCLUDED.last_activity_at,
          last_sent_at = now(),
          updated_at = now()
      WHERE profile_reminder_state.stage < EXCLUDED.stage
         OR profile_reminder_state.last_activity_at < EXCLUDED.last_activity_at
    RETURNING user_id AS claimed_user_id, stage AS claimed_stage
  )
  SELECT cl.claimed_user_id, e.fcm_token, e.platform, e.ui_language, e.display_name,
         cl.claimed_stage, e.hours_closed
  FROM claimed cl
  JOIN eligible e ON e.user_id = cl.claimed_user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_profile_reminder_candidates(double precision[], double precision, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_profile_reminder_candidates(double precision[], double precision, integer, integer) TO service_role;

-- 6) Config defaults (idempotent). Values are read by the cron task with
--    hard-coded fallbacks, so a missing row never breaks the feature.
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable)
VALUES
  ('notifications.profile_reminder.enabled', 'true'::jsonb, 'boolean', 'notification',
   'Master switch for the automatic "complete your profile" reminder pushes.', false),
  ('notifications.profile_reminder.offsets_hours', '[1, 5]'::jsonb, 'array', 'notification',
   'Hours after the app was closed at which a reminder is sent (once per value, ascending).', false),
  ('notifications.profile_reminder.repeat_hours', '24'::jsonb, 'number', 'notification',
   'After the last offset, repeat every N hours while the profile stays incomplete (0 disables the repeat tail).', false),
  ('notifications.profile_reminder.max_reminders', '0'::jsonb, 'number', 'notification',
   'Safety cap on reminders per closure cycle; 0 = unlimited.', false),
  ('notifications.profile_reminder.batch_limit', '200'::jsonb, 'number', 'notification',
   'Maximum users claimed per cron tick (remainder waits for the next tick).', false)
ON CONFLICT (config_key) DO NOTHING;

-- 7) Reminder text (server-side localized, mirrors cron fallback keys).
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileReminderTitle', 'Finish your profile'),
  ('en', 'profileReminderBody', 'Hi {name}! Your profile is almost ready — finish it now so people can find you and match with you.'),
  ('es', 'profileReminderTitle', 'Termina tu perfil'),
  ('es', 'profileReminderBody', '¡Hola {name}! Tu perfil casi está listo: termínalo ahora para que las personas puedan encontrarte y coincidir contigo.'),
  ('he', 'profileReminderTitle', 'השלימו את הפרופיל שלכם'),
  ('he', 'profileReminderBody', 'היי {name}! כמעט סיימתם — השלימו את הפרופיל עכשיו כדי שאנשים יוכלו למצוא אתכם ולהתאים איתכם.')
ON CONFLICT (locale, key) DO NOTHING;

COMMIT;
