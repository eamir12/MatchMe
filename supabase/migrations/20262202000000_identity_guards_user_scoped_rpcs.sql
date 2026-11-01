-- Migration: identity guard inside the user-scoped SECURITY DEFINER RPCs.
-- Date: 2026-10-29
--
-- Problem: these functions take a p_user_id from the caller, run SECURITY
-- DEFINER (so RLS is bypassed), and never compare it with the authenticated
-- caller. Any signed-in account can therefore act on any other user: move
-- or pin their location, hide them, spoof their presence, read their rating
-- prompts and match list, or mint an email-change code for their account.
-- 20262201000000 closes the anonymous path; this closes the signed-in one.
--
-- Fix: one guard as the first statement of the outermost block, before any
-- table access:
--
--   IF p_user_id IS DISTINCT FROM auth.uid()
--      AND COALESCE(auth.role(), '') <> 'service_role'
--      AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
--     RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
--   END IF;
--
-- Clause by clause:
--   p_user_id = auth.uid()      the normal client path, passes
--   role = service_role         edge functions and cron-jobs, pass
--   no request.jwt.claims       a direct SQL session (psql, SQL editor, a
--                               SECURITY DEFINER caller such as
--                               upload_offline_trail -> perform_retroactive_matching).
--                               Reaching one of these requires the database
--                               credentials, which already outrank every check here.
--   otherwise                   anon (uid null) and any cross-user call raise 42501.
--
-- Bodies were generated from pg_get_functiondef() on 2026-10-29 and differ
-- from the deployed versions only by the guard block (and, for the two
-- LANGUAGE sql readers below, by RETURN QUERY so the guard can run first).
-- Signatures, defaults, return types, volatility, owner and ACL are unchanged;
-- CREATE OR REPLACE keeps the grants written by 20262201000000.
--
-- Blast radius: 15 function bodies. Reviewed callers: every client call site
-- passes auth.currentUser.id, the only internal callers re-pass the same
-- p_user_id, and no pg_cron job touches these.
--
-- IMPORTANT for future migrations: any CREATE OR REPLACE of these functions
-- must keep the guard block, or the cross-user hole reopens.
--
-- Verification (run after applying):
--   select proname, prosrc like '%not authorized%' as guarded
--   from pg_proc where proname in (
--     'update_user_location', 'update_user_activity', 'update_user_visibility',
--     'pin_current_location', 'unpin_location', 'extend_pinned_location',
--     'broadcast_user_online_event', 'get_due_match_rating_prompts',
--     'get_user_recent_matches', 'generate_email_change_code',
--     'verify_email_change_code', 'complete_email_change',
--     'force_normalize_subscription', 'perform_retroactive_matching')
--   order by 1;  -- 15 rows (update_user_location has two overloads), guarded = true

-- generated from pg_get_functiondef() on 2026-10-29


-- location writers (5)

-- extend_pinned_location(uuid,integer)
CREATE OR REPLACE FUNCTION public.extend_pinned_location(p_user_id uuid, p_extra_seconds integer)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_row RECORD;
    v_new_expiry TIMESTAMPTZ;
    v_max_expiry TIMESTAMPTZ;
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

    IF p_extra_seconds IS NULL OR p_extra_seconds < 60 OR p_extra_seconds > 2592000 THEN
        RAISE EXCEPTION 'invalid duration (must be 60s..30 days)';
    END IF;

    SELECT is_pinned, pinned_expires_at, pinned_created_at
    INTO v_row
    FROM public.user_locations
    WHERE user_id = p_user_id;

    IF v_row IS NULL OR COALESCE(v_row.is_pinned, FALSE) = FALSE
        OR v_row.pinned_expires_at IS NULL OR v_row.pinned_expires_at <= NOW() THEN
        RAISE EXCEPTION 'no active pinned location';
    END IF;

    v_new_expiry := v_row.pinned_expires_at + (p_extra_seconds || ' seconds')::INTERVAL;
    v_max_expiry := COALESCE(v_row.pinned_created_at, NOW()) + INTERVAL '30 days';

    IF v_new_expiry > v_max_expiry THEN
        RAISE EXCEPTION 'extension exceeds 30-day maximum pinned time';
    END IF;

    UPDATE public.user_locations
    SET pinned_expires_at = v_new_expiry,
        updated_at = NOW()
    WHERE user_id = p_user_id;

    RETURN v_new_expiry;
END;
$function$;

-- pin_current_location(uuid,double precision,double precision,text,integer)
CREATE OR REPLACE FUNCTION public.pin_current_location(p_user_id uuid, p_latitude double precision, p_longitude double precision, p_label text DEFAULT NULL::text, p_duration_seconds integer DEFAULT 86400)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_expires TIMESTAMPTZ;
    v_label TEXT;
    v_observed_lat DOUBLE PRECISION;
    v_observed_lng DOUBLE PRECISION;
    v_observed_at TIMESTAMPTZ;
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'user not found';
    END IF;

    -- p_latitude / p_longitude are accepted for signature compatibility but
    -- deliberately IGNORED: pinning is only allowed at a position the server
    -- has observed from live GPS (anti-fraud — see migration header).

    -- Min 60s (allows testing), max 30 days.
    IF p_duration_seconds IS NULL OR p_duration_seconds < 60 OR p_duration_seconds > 2592000 THEN
        RAISE EXCEPTION 'invalid duration (must be 60s..30 days)';
    END IF;

    v_label := NULLIF(TRIM(COALESCE(p_label, '')), '');
    IF v_label IS NOT NULL AND LENGTH(v_label) > 120 THEN
        v_label := LEFT(v_label, 120);
    END IF;

    -- The pin freezes the server-observed position, never a client claim.
    SELECT latitude, longitude, updated_at
    INTO v_observed_lat, v_observed_lng, v_observed_at
    FROM public.user_locations
    WHERE user_id = p_user_id;

    IF v_observed_lat IS NULL OR v_observed_lng IS NULL OR v_observed_at IS NULL THEN
        RAISE EXCEPTION 'no observed location to pin';
    END IF;

    IF v_observed_at < NOW() - INTERVAL '15 minutes' THEN
        RAISE EXCEPTION 'observed location too old to pin';
    END IF;

    v_expires := NOW() + (p_duration_seconds || ' seconds')::INTERVAL;

    INSERT INTO public.user_locations (
        user_id, latitude, longitude, speed, heading, updated_at,
        is_pinned, pinned_expires_at, pinned_created_at, pinned_label
    )
    VALUES (
        p_user_id, v_observed_lat, v_observed_lng, NULL, NULL, NOW(),
        TRUE, v_expires, NOW(), v_label
    )
    ON CONFLICT (user_id)
    DO UPDATE SET
        latitude = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude,
        speed = NULL,
        heading = NULL,
        updated_at = NOW(),
        is_pinned = TRUE,
        pinned_expires_at = EXCLUDED.pinned_expires_at,
        pinned_created_at = NOW(),
        pinned_label = EXCLUDED.pinned_label;

    -- Keep the user online; this does NOT touch coordinates.
    PERFORM public.update_user_activity(p_user_id);

    RETURN v_expires;
END;
$function$;

-- unpin_location(uuid)
CREATE OR REPLACE FUNCTION public.unpin_location(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

    UPDATE public.user_locations
    SET is_pinned = FALSE,
        pinned_expires_at = NULL,
        pinned_created_at = NULL,
        pinned_label = NULL,
        updated_at = NOW() - INTERVAL '16 minutes'
    WHERE user_id = p_user_id;

    PERFORM public.update_user_activity(p_user_id);
END;
$function$;

-- update_user_location(uuid,double precision,double precision,double precision,double precision)
CREATE OR REPLACE FUNCTION public.update_user_location(p_user_id uuid, p_latitude double precision, p_longitude double precision, p_speed double precision DEFAULT NULL::double precision, p_heading double precision DEFAULT NULL::double precision)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    user_exists BOOLEAN;
    pinned_active BOOLEAN;
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

    -- Deleted users: silently return (see 20260413000000).
    SELECT EXISTS(SELECT 1 FROM public.users WHERE id = p_user_id)
    INTO user_exists;

    IF NOT user_exists THEN
        RETURN;
    END IF;

    -- Active pin: keep heartbeat only, never touch coordinates.
    SELECT COALESCE(
        (SELECT (ul.is_pinned = TRUE AND ul.pinned_expires_at > NOW())
         FROM public.user_locations ul
         WHERE ul.user_id = p_user_id),
        FALSE
    )
    INTO pinned_active;

    IF pinned_active THEN
        PERFORM public.update_user_activity(p_user_id);
        RETURN;
    END IF;

    -- No active pin (or pin already expired): normal live write.
    -- An expired pin flag is cleared here so the row returns to live mode
    -- even if the client never calls unpin_location().
    INSERT INTO public.user_locations (user_id, latitude, longitude, speed, heading, updated_at)
    VALUES (p_user_id, p_latitude, p_longitude, p_speed, p_heading, NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET
        latitude = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude,
        speed = EXCLUDED.speed,
        heading = EXCLUDED.heading,
        updated_at = NOW(),
        is_pinned = FALSE,
        pinned_expires_at = NULL,
        pinned_created_at = NULL,
        pinned_label = NULL;

    PERFORM public.update_user_activity(p_user_id);
END;
$function$;

-- update_user_location(uuid,double precision,double precision)
CREATE OR REPLACE FUNCTION public.update_user_location(p_user_id uuid, p_lat double precision, p_lng double precision)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions'
AS $function$
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

  UPDATE public.users 
  SET last_location = point(p_lng, p_lat),
      location_updated_at = NOW()
  WHERE id = p_user_id;
END;
$function$;


-- presence and visibility writers (3)

-- broadcast_user_online_event(uuid)
CREATE OR REPLACE FUNCTION public.broadcast_user_online_event(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

    -- Only insert if we haven't broadcasted recently (throttle to every 5 seconds)
    IF NOT EXISTS (
        SELECT 1 FROM public.presence_events pe
        WHERE pe.user_id = p_user_id
          AND pe.event_type = 'online'
          AND pe.created_at > NOW() - INTERVAL '5 seconds'
    ) THEN
        INSERT INTO public.presence_events (user_id, event_type, created_at, expires_at)
        VALUES (p_user_id, 'online', NOW(), NOW() + INTERVAL '1 minute');
    END IF;
END;
$function$;

-- update_user_activity(uuid)
CREATE OR REPLACE FUNCTION public.update_user_activity(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    is_visible BOOLEAN;
    is_banned BOOLEAN;
    user_exists BOOLEAN;
    has_active_session BOOLEAN;
    has_revoked_session BOOLEAN;
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

    SET search_path = 'public';

    -- Check if user exists in the users table
    SELECT EXISTS(SELECT 1 FROM users WHERE id = p_user_id)
    INTO user_exists;

    -- If user doesn't exist (has been deleted), return early silently
    -- This prevents NULL constraint violations on is_visible
    IF NOT user_exists THEN
        RETURN;
    END IF;

    -- Get current visibility and ban status
    SELECT
        COALESCE(user_visibility_setting, false),
        COALESCE(system_visibility_status, 'visible') = 'banned'
    INTO is_visible, is_banned
    FROM users
    WHERE id = p_user_id;

    -- If user is banned, force offline
    IF is_banned THEN
        UPDATE user_activity
        SET is_online = false,
            last_activity = NOW(),
            updated_at = NOW()
        WHERE user_id = p_user_id;
    ELSE
        -- Session-state gate: a revoked session (logout) must never be
        -- resurrected by a stale heartbeat, but a logged-in user whose
        -- registration was skipped (no GPS country) has no rows at all
        -- and must stay online.
        SELECT EXISTS (
            SELECT 1 FROM user_session
            WHERE user_id = p_user_id AND revoked = false
        )
        INTO has_active_session;

        SELECT EXISTS (
            SELECT 1 FROM user_session
            WHERE user_id = p_user_id AND revoked = true
        )
        INTO has_revoked_session;

        IF (NOT COALESCE(has_active_session, false))
           AND COALESCE(has_revoked_session, false) THEN
            -- Logged out: keep the user offline. Also refresh last_activity
            -- so the 61s online-count window keeps excluding them.
            UPDATE user_activity
            SET is_online = false,
                last_activity = NOW(),
                updated_at = NOW()
            WHERE user_id = p_user_id;
        ELSE
            -- Update activity with current visibility status
            INSERT INTO user_activity (
                user_id,
                last_activity,
                is_online,
                is_visible,
                updated_at
            )
            VALUES (
                p_user_id,
                NOW(),
                true,
                is_visible,
                NOW()
            )
            ON CONFLICT (user_id)
            DO UPDATE SET
                last_activity = NOW(),
                is_online = true,
                is_visible = EXCLUDED.is_visible,
                updated_at = NOW();
        END IF;
    END IF;
END;
$function$;

-- update_user_visibility(uuid)
CREATE OR REPLACE FUNCTION public.update_user_visibility(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  visibility_value BOOLEAN;
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

  BEGIN
    SELECT COALESCE(u.user_visibility_setting, false)
    INTO visibility_value
    FROM public.users u
    WHERE u.id = p_user_id;

    IF NOT FOUND THEN
      RETURN;
    END IF;

    UPDATE public.user_activity
    SET is_visible = visibility_value,
        updated_at = NOW()
    WHERE user_id = p_user_id;

    IF NOT FOUND THEN
      INSERT INTO public.user_activity (user_id, last_activity, is_online, is_visible, updated_at)
      VALUES (p_user_id, NOW(), false, visibility_value, NOW())
      ON CONFLICT (user_id) DO UPDATE SET
        is_visible = EXCLUDED.is_visible,
        updated_at = NOW();
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Persist with user_id so it is queryable even if log drains drop WARNINGs.
    BEGIN
      PERFORM public.log_app_error(
        'update_user_visibility', p_user_id, SQLERRM,
        jsonb_build_object('sqlstate', SQLSTATE)
      );
    EXCEPTION WHEN OTHERS THEN
      NULL; -- logging must never mask the original error
    END;
    RAISE WARNING 'Error updating visibility for user %: %', p_user_id, SQLERRM;
  END;
END;
$function$;


-- match rating and matching (3)

-- get_due_match_rating_prompts(uuid,integer,integer)
CREATE OR REPLACE FUNCTION public.get_due_match_rating_prompts(p_user_id uuid, p_initial_delay_seconds integer, p_limit integer DEFAULT 1)
 RETURNS TABLE(match_id uuid, other_user_id uuid, other_name text, match_created_at timestamp with time zone, other_user_met_confirmed boolean, self_met_confirmed boolean, next_prompt_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
WITH user_matches AS (
  SELECT m.id AS match_id,
         m.created_at AS match_created_at,
         m AS match_row,
         CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END AS other_user_id
  FROM public.matches m
  WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
    AND EXISTS (
      SELECT 1 FROM public.chat_messages cm
      WHERE cm.match_id = m.id
      LIMIT 1
    )
),
due_missing_rows AS (
  SELECT um.match_id AS match_id,
         p_user_id AS user_id,
         public._match_rating_prompt_due_at(um.match_row, p_initial_delay_seconds) AS next_prompt_at
  FROM user_matches um
  LEFT JOIN public.match_rating_prompts mrp
    ON mrp.match_id = um.match_id AND mrp.user_id = p_user_id
  WHERE mrp.match_id IS NULL
    AND public._match_rating_prompt_due_at(um.match_row, p_initial_delay_seconds) <= now()
),
inserted AS (
  INSERT INTO public.match_rating_prompts (match_id, user_id, next_prompt_at)
  SELECT match_id, user_id, next_prompt_at
  FROM due_missing_rows
  ON CONFLICT (match_id, user_id) DO NOTHING
  RETURNING match_id
),
due_prompts AS (
  SELECT mrp.match_id,
         mrp.user_id,
         mrp.next_prompt_at,
         mrp.met_confirmed AS self_met_confirmed
  FROM public.match_rating_prompts mrp
  WHERE mrp.user_id = p_user_id
    AND mrp.rating_submitted_at IS NULL
    AND mrp.next_prompt_at IS NOT NULL
    AND mrp.next_prompt_at <= now()
    AND EXISTS (
      SELECT 1 FROM public.chat_messages cm
      WHERE cm.match_id = mrp.match_id
      LIMIT 1
    )
)
SELECT dp.match_id,
       um.other_user_id,
       public.mask_full_name(u.name) AS other_name,
       um.match_created_at AS match_created_at,
       COALESCE(otherp.met_confirmed, false) AS other_user_met_confirmed,
       dp.self_met_confirmed,
       dp.next_prompt_at
FROM due_prompts dp
JOIN user_matches um ON um.match_id = dp.match_id
LEFT JOIN public.users u ON u.id = um.other_user_id
LEFT JOIN public.match_rating_prompts otherp
  ON otherp.match_id = dp.match_id AND otherp.user_id = um.other_user_id
ORDER BY dp.next_prompt_at ASC
LIMIT p_limit;
END;
$function$;

-- get_user_recent_matches(uuid,integer)
CREATE OR REPLACE FUNCTION public.get_user_recent_matches(p_user_id uuid, p_limit integer DEFAULT 20)
 RETURNS TABLE(match_id uuid, other_user_id uuid, other_name text, other_photos text[], match_type text, matched_intent text, last_activity_at timestamp with time zone, created_at timestamp with time zone, chat_start_window_seconds integer, chat_start_extension_seconds integer, chat_start_extension_count integer, expires_at timestamp with time zone, has_extended boolean, extension_seconds integer, match_occurrence integer, map_center_lat double precision, map_center_lng double precision, map_zoom double precision, previous_locations jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
  SELECT
    m.id as match_id,
    CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END as other_user_id,
    public.mask_full_name(u.name) as other_name,
    ARRAY(SELECT jsonb_array_elements_text(up.photos)) as other_photos,
    m.match_type,
    m.matched_intent,
    m.created_at as last_activity_at,
    m.created_at,
    m.chat_start_window_seconds,
    COALESCE(m.chat_start_extension_seconds, 0) as chat_start_extension_seconds,
    COALESCE(m.chat_start_extension_count, 0) as chat_start_extension_count,
    m.created_at + make_interval(secs => COALESCE(m.chat_start_window_seconds, 86400) + COALESCE(m.chat_start_extension_seconds,0)) as expires_at,
    CASE WHEN p_user_id = m.user1_id THEN COALESCE(m.chat_start_user1_extension_seconds, 0) > 0 ELSE COALESCE(m.chat_start_user2_extension_seconds, 0) > 0 END as has_extended,
    CASE WHEN p_user_id = m.user1_id THEN COALESCE(m.chat_start_user1_extension_seconds, 0) ELSE COALESCE(m.chat_start_user2_extension_seconds, 0) END as extension_seconds,
    COALESCE(m.match_occurrence, 1) as match_occurrence,
    m.map_center_lat,
    m.map_center_lng,
    m.map_zoom,
    COALESCE(up_hist.locations_history, '[]'::jsonb) as previous_locations
  FROM public.matches m
  LEFT JOIN public.users u ON u.id = CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END
  LEFT JOIN public.user_profiles up ON up.user_id = CASE WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END
  LEFT JOIN public.unmatched_pairs up_hist ON up_hist.user1_id = LEAST(m.user1_id, m.user2_id) AND up_hist.user2_id = GREATEST(m.user1_id, m.user2_id)
  WHERE m.user1_id = p_user_id OR m.user2_id = p_user_id
  ORDER BY m.created_at DESC, m.id
  LIMIT p_limit;
END;
$function$;

-- perform_retroactive_matching(uuid)
CREATE OR REPLACE FUNCTION public.perform_retroactive_matching(p_user_id uuid)
 RETURNS TABLE(matches_created integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_dist_m double precision := 100;
  v_time_s int := 180;
  v_max_occ int := 3;
  v_my_radius int;
  v_other_radius int;
  v_created int := 0;
  r RECORD;
  v_a uuid; v_b uuid;
  v_hist RECORD;
  v_next_occurrence int;
  v_center_lat double precision;
  v_center_lng double precision;
  v_zoom double precision := 14.5;
  v_dist_km double precision;
  v_my_ret int; v_other_ret int;
  v_my_enabled boolean; v_other_enabled boolean;
  my_intents TEXT[]; other_intents TEXT[];
  shared TEXT[];
  my_interests jsonb; other_interests jsonb;
  my_prefs jsonb; other_prefs jsonb;
  my_gender text; my_dob date; my_age int;
  other_gender text; other_dob date; other_age int;
  my_life jsonb; my_fam jsonb; my_rel jsonb; my_h int;
  other_life jsonb; other_fam jsonb; other_rel jsonb; other_h int;
  s text; ok boolean;
  cur_sub TEXT[]; oth_sub TEXT[];
  a_g boolean; b_g boolean; a_a boolean; b_a boolean;
  v_intent text;
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

  SELECT NULLIF(config_value::text,'')::int INTO v_dist_m FROM public.app_config WHERE config_key='retro.distance_meters' LIMIT 1;
  IF v_dist_m IS NULL OR v_dist_m <= 0 THEN v_dist_m := 100; END IF;
  IF v_dist_m > 1000 THEN v_dist_m := 1000; END IF;
  SELECT NULLIF(config_value::text,'')::int INTO v_time_s FROM public.app_config WHERE config_key='retro.time_window_seconds' LIMIT 1;
  IF v_time_s IS NULL OR v_time_s <= 0 THEN v_time_s := 180; END IF;
  IF v_time_s > 900 THEN v_time_s := 900; END IF;
  v_max_occ := public._get_max_match_occurrence();

  SELECT retro_matching_enabled, retro_retention_hours, match_radius_default
    INTO v_my_enabled, v_my_ret, v_my_radius
    FROM public.users WHERE id = p_user_id;
  IF NOT FOUND OR COALESCE(v_my_enabled,false) = false THEN
    RETURN QUERY SELECT 0; RETURN;
  END IF;
  SELECT gender, date_of_birth INTO my_gender, my_dob FROM public.users WHERE id = p_user_id;
  IF my_dob IS NOT NULL THEN my_age := EXTRACT(YEAR FROM AGE(my_dob)); END IF;
  SELECT lifestyle, family, religion, height,
         ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)),
         public.merge_interest_maps(COALESCE(personal_interests,'{}'::jsonb), COALESCE(business_interests,'{}'::jsonb)),
         intent_preferences
    INTO my_life, my_fam, my_rel, my_h, my_intents, my_interests, my_prefs
    FROM public.user_profiles WHERE user_id = p_user_id;
  IF my_intents IS NULL OR array_length(my_intents,1) IS NULL THEN
    RETURN QUERY SELECT 0; RETURN;
  END IF;

  FOR r IN
    SELECT h1.recorded_at AS t1, h1.latitude AS lat1, h1.longitude AS lng1,
           h2.user_id AS other_id, h2.recorded_at AS t2, h2.latitude AS lat2, h2.longitude AS lng2,
           (6371.0 * acos(LEAST(1.0, GREATEST(-1.0,
               cos(radians(h1.latitude)) * cos(radians(h2.latitude))
               * cos(radians(h2.longitude) - radians(h1.longitude))
               + sin(radians(h1.latitude)) * sin(radians(h2.latitude)))))) * 1000.0 AS pair_dist_m
    FROM public.offline_location_history h1
    JOIN public.offline_location_history h2
      ON h2.user_id <> p_user_id
     AND abs(extract(epoch from (h1.recorded_at - h2.recorded_at))) <= v_time_s
    WHERE h1.user_id = p_user_id
      AND h1.recorded_at >= now() - make_interval(hours => v_my_ret)
      AND h2.recorded_at >= h1.recorded_at - make_interval(secs => v_time_s)
      AND h2.recorded_at <= h1.recorded_at + make_interval(secs => v_time_s)
      AND (6371.0 * acos(LEAST(1.0, GREATEST(-1.0,
          cos(radians(h1.latitude)) * cos(radians(h2.latitude))
          * cos(radians(h2.longitude) - radians(h1.longitude))
          + sin(radians(h1.latitude)) * sin(radians(h2.latitude)))))) * 1000.0 <= v_dist_m
    LIMIT 2000
  LOOP
    -- Other user opted in?
    SELECT retro_matching_enabled, retro_retention_hours, gender, date_of_birth, match_radius_default
      INTO v_other_enabled, v_other_ret, other_gender, other_dob, v_other_radius
      FROM public.users WHERE id = r.other_id;
    IF COALESCE(v_other_enabled,false) = false THEN CONTINUE; END IF;
    IF r.t2 < now() - make_interval(hours => v_other_ret) THEN CONTINUE; END IF;
    -- Mutual radius: a retro pair must also sit inside BOTH users' live
    -- match-radius settings, not just the admin co-presence window
    -- (retro.distance_meters). Trail points prove real co-presence; the
    -- radius settings decide whether that co-presence is matchable for
    -- these two users.
    IF r.pair_dist_m > LEAST(COALESCE(v_my_radius, 50), COALESCE(v_other_radius, 50)) THEN CONTINUE; END IF;

    -- Already matched / permanently unmatched?
    IF EXISTS (SELECT 1 FROM public.matches
                WHERE (user1_id = p_user_id AND user2_id = r.other_id)
                   OR (user1_id = r.other_id AND user2_id = p_user_id)) THEN CONTINUE; END IF;
    v_a := LEAST(p_user_id, r.other_id); v_b := GREATEST(p_user_id, r.other_id);
    SELECT expiry_count, is_permanent INTO v_hist FROM public.unmatched_pairs WHERE user1_id = v_a AND user2_id = v_b;
    IF FOUND AND COALESCE(v_hist.is_permanent,false) = true THEN CONTINUE; END IF;
    IF FOUND AND COALESCE(v_hist.expiry_count,0) >= v_max_occ THEN CONTINUE; END IF;
    v_next_occurrence := COALESCE(v_hist.expiry_count,0) + 1;
    IF v_next_occurrence > v_max_occ THEN CONTINUE; END IF;

    SELECT lifestyle, family, religion, height,
           ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)),
           public.merge_interest_maps(COALESCE(personal_interests,'{}'::jsonb), COALESCE(business_interests,'{}'::jsonb)),
           intent_preferences
      INTO other_life, other_fam, other_rel, other_h, other_intents, other_interests, other_prefs
      FROM public.user_profiles WHERE user_id = r.other_id;
    IF other_intents IS NULL OR array_length(other_intents,1) IS NULL THEN CONTINUE; END IF;
    SELECT ARRAY(SELECT i FROM unnest(my_intents) AS t(i) WHERE i = ANY(other_intents)) INTO shared;
    IF shared IS NULL OR array_length(shared,1) IS NULL THEN CONTINUE; END IF;

    v_intent := NULL;
    <<intent_loop>> FOREACH s IN ARRAY shared LOOP
      cur_sub := ARRAY(SELECT jsonb_array_elements_text(COALESCE((SELECT up.sub_intents -> s FROM public.user_profiles up WHERE up.user_id = p_user_id), '[]'::jsonb)));
      oth_sub := ARRAY(SELECT jsonb_array_elements_text(COALESCE((SELECT up.sub_intents -> s FROM public.user_profiles up WHERE up.user_id = r.other_id), '[]'::jsonb)));
      IF cur_sub IS NULL OR oth_sub IS NULL OR array_length(cur_sub,1) IS NULL OR array_length(oth_sub,1) IS NULL THEN CONTINUE intent_loop; END IF;
      IF NOT (cur_sub && oth_sub) THEN CONTINUE intent_loop; END IF;
      IF other_dob IS NOT NULL THEN other_age := EXTRACT(YEAR FROM AGE(other_dob)); ELSE other_age := NULL; END IF;
      a_g := (NOT ((other_prefs -> 'gender_preferences') ? s) OR ((other_prefs -> 'gender_preferences') -> s) ? my_gender);
      b_g := (NOT ((my_prefs -> 'gender_preferences') ? s) OR ((my_prefs -> 'gender_preferences') -> s) ? other_gender);
      IF NOT a_g OR NOT b_g THEN CONTINUE intent_loop; END IF;
      a_a := (NOT ((other_prefs -> 'age_preferences') ? s) OR my_age IS NULL OR (jsonb_array_length((other_prefs -> 'age_preferences') -> s) >= 2 AND my_age >= (((other_prefs -> 'age_preferences') -> s ->> 0)::numeric) AND my_age <= (((other_prefs -> 'age_preferences') -> s ->> 1)::numeric)));
      b_a := (NOT ((my_prefs -> 'age_preferences') ? s) OR other_age IS NULL OR (jsonb_array_length((my_prefs -> 'age_preferences') -> s) >= 2 AND other_age >= (((my_prefs -> 'age_preferences') -> s ->> 0)::numeric) AND other_age <= (((my_prefs -> 'age_preferences') -> s ->> 1)::numeric)));
      IF NOT a_a OR NOT b_a THEN CONTINUE intent_loop; END IF;
      ok := public.are_filters_compatible(my_life, my_fam, my_rel, my_h, other_life, other_fam, other_rel, other_h,
        (other_prefs -> 'lifestyle_filters'), (other_prefs -> 'family_filters'), (other_prefs -> 'religion_filters'), (other_prefs -> 'height_preferences'),
        (my_prefs -> 'lifestyle_filters'), (my_prefs -> 'family_filters'), (my_prefs -> 'religion_filters'), (my_prefs -> 'height_preferences'), s);
      IF NOT COALESCE(ok,false) THEN CONTINUE intent_loop; END IF;
      IF my_interests IS NULL OR other_interests IS NULL OR my_interests = '{}'::jsonb OR other_interests = '{}'::jsonb THEN CONTINUE intent_loop; END IF;
      IF NOT EXISTS (SELECT 1 FROM jsonb_object_keys(my_interests) AS cat
                     WHERE my_interests ? cat AND other_interests ? cat
                       AND jsonb_array_length(my_interests->cat) > 0 AND jsonb_array_length(other_interests->cat) > 0
                       AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(my_interests->cat) AS sub
                                   WHERE sub = ANY(SELECT jsonb_array_elements_text(other_interests->cat)))) THEN CONTINUE intent_loop; END IF;
      v_intent := s; EXIT intent_loop;
    END LOOP intent_loop;
    IF v_intent IS NULL THEN CONTINUE; END IF;

    -- Coarse center (~1.1km truncation) like live matching; never store exact trail in matches
    v_center_lat := ROUND(((r.lat1 + r.lat2)/2)::numeric, 2)::double precision;
    v_center_lng := ROUND(((r.lng1 + r.lng2)/2)::numeric, 2)::double precision;
    v_dist_km := (6371.0 * acos(LEAST(1.0, GREATEST(-1.0,
        cos(radians(r.lat1)) * cos(radians(r.lat2)) * cos(radians(r.lng2) - radians(r.lng1))
        + sin(radians(r.lat1)) * sin(radians(r.lat2))))))::double precision;
    IF v_dist_km < 0.3 THEN v_zoom := 16;
    ELSIF v_dist_km < 0.6 THEN v_zoom := 15.5;
    ELSIF v_dist_km < 1.0 THEN v_zoom := 15;
    ELSIF v_dist_km < 2.0 THEN v_zoom := 14.5;
    ELSIF v_dist_km < 5.0 THEN v_zoom := 13.5;
    ELSIF v_dist_km < 10.0 THEN v_zoom := 12.5;
    ELSE v_zoom := 11; END IF;

    BEGIN
      INSERT INTO public.matches (user1_id, user2_id, matched_intent, match_type, created_at, match_occurrence, map_center_lat, map_center_lng, map_zoom, is_retroactive)
      VALUES (v_a, v_b, v_intent, 'proximity', NOW(), v_next_occurrence, v_center_lat, v_center_lng, v_zoom, true);
      v_created := v_created + 1;
    EXCEPTION WHEN unique_violation THEN
      -- already matched concurrently; skip
      CONTINUE;
    END;
    -- No EXIT: keep scanning — the EXISTS check above skips pairs already
    -- matched earlier in this run, so one trail can match several people.
  END LOOP;

  RETURN QUERY SELECT v_created;
END;
$function$;


-- email change codes (3)

-- complete_email_change(uuid,text)
CREATE OR REPLACE FUNCTION public.complete_email_change(p_user_id uuid, p_code text)
 RETURNS TABLE(success boolean, message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_record public.pending_email_changes;
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

  SELECT * INTO v_record
  FROM public.pending_email_changes
  WHERE user_id = p_user_id
    AND code = p_code
    AND verified_at IS NOT NULL
    AND completed_at IS NULL
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'No verified email change found for this code';
    RETURN;
  END IF;

  IF v_record.expires_at < now() THEN
    RETURN QUERY SELECT false, 'Verification has expired';
    RETURN;
  END IF;

  -- Mark as completed
  UPDATE public.pending_email_changes
  SET completed_at = now()
  WHERE id = v_record.id;

  RETURN QUERY SELECT true, 'Email change completed successfully';
END;
$function$;

-- generate_email_change_code(uuid,text)
CREATE OR REPLACE FUNCTION public.generate_email_change_code(p_user_id uuid, p_new_email text)
 RETURNS TABLE(code text, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_code text;
  v_expires_at timestamp with time zone;
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

  -- Generate a 6-digit code
  v_code := lpad(floor(random() * 1000000)::text, 6, '0');
  v_expires_at := now() + interval '10 minutes';

  -- Insert the pending email change
  INSERT INTO public.pending_email_changes (user_id, new_email, code, expires_at)
  VALUES (p_user_id, p_new_email, v_code, v_expires_at);

  RETURN QUERY SELECT v_code, v_expires_at;
END;
$function$;

-- verify_email_change_code(uuid,text)
CREATE OR REPLACE FUNCTION public.verify_email_change_code(p_user_id uuid, p_code text)
 RETURNS TABLE(success boolean, message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_code text;
  v_record public.pending_email_changes;
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

  v_code := regexp_replace(COALESCE(TRIM(p_code), ''), '[[:space:]\-_]+', '', 'g');

  SELECT * INTO v_record
  FROM public.pending_email_changes
  WHERE user_id = p_user_id
    AND regexp_replace(COALESCE(code, ''), '[[:space:]\-_]+', '', 'g') = v_code
    AND verified_at IS NULL
    AND completed_at IS NULL
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'Invalid or expired verification code';
    RETURN;
  END IF;

  IF v_record.expires_at < now() THEN
    RETURN QUERY SELECT false, 'Verification code has expired';
    RETURN;
  END IF;

  UPDATE public.pending_email_changes
  SET verified_at = now()
  WHERE id = v_record.id;

  RETURN QUERY SELECT true, 'Code verified successfully';
END;
$function$;


-- subscription state (1)

-- force_normalize_subscription(uuid)
CREATE OR REPLACE FUNCTION public.force_normalize_subscription(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_before TEXT;
  v_after TEXT;
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid()
        AND COALESCE(auth.role(), '') <> 'service_role'
        AND COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
        RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;

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
$function$;

NOTIFY pgrst, 'reload schema';

-- Verification notes:
--
--   * Cross-user call must raise 42501 before touching any table. As a
--     signed-in user (JWT sub = A), call one of these with B:
--       select public.update_user_activity('<user-B-uuid>');
--       -- ERROR:  not authorized  (SQLSTATE 42501)
--   * Own id must still work, service_role must still work, and a direct
--     psql session with no request.jwt.claims must still work.