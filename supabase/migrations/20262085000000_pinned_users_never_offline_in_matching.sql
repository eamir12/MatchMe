-- Migration: Pinned users are never considered offline for matching/visibility
-- Date: 2026-10-05
-- Depends on: 20262013000000 (pin columns + is_pinned_location_active RPC),
--             20262014000000 (freshness exemptions + touch/expire cron)
--
-- Problem: a pin means the client deliberately stops transmitting GPS
-- (PinnedLocationGate / native isPinnedLocationActive()), so the ONLY thing
-- keeping user_activity.is_online=true is a heartbeat from a live process.
-- cleanup_stale_online_users() (cron, every minute) flips is_online=false
-- after 61s of silence. Consequences for a visible user with an ACTIVE pin:
--   - iOS app suspended / Android force-stop / device offline > 61s  ->
--     excluded from the matching pool, find_nearby_users() candidates and
--     is_user_truly_visible() (nearby count, map cells) for the whole pin.
--   - Matching also depended on the cron touch (4-min bump vs 5-min gate,
--     ~1 min margin) for location freshness; a delayed cron tick dropped a
--     fully-online pinned user out of the pool anyway.
-- A pin lasting 24h-30 days is pointless if it stops matching 2 minutes
-- after the app closes. Online/offline (process liveness) is irrelevant
-- while no GPS is being transmitted, by design.
--
-- Fix: an ACTIVE pin (is_pinned = TRUE AND pinned_expires_at > NOW()) is
-- itself a liveness/visibility signal. Every gate that requires
-- user_activity.is_online gains an OR is_pinned_location_active(...) branch,
-- and the matching pool's 5-minute freshness gate gains the same direct pin
-- exemption the cleanup/visibility/map functions already have.
--
-- Deliberately NOT changed:
--   - update_user_activity() / cleanup_stale_online_users(): is_online stays
--     an honest "a client process is alive" signal for non-pinned semantics
--     (logout tombstone + banned gates keep working). Pinned visibility is
--     computed at read time via the OR branches below.
--   - expire_pinned_locations(): an expired pin removes the exemption
--     automatically (is_pinned=false), so stale pins never leak visibility.
--   - Banned / system-invisible / visibility-off users: all gates below keep
--     requiring those checks unconditionally; the pin only bypasses liveness
--     and location freshness, never consent or moderation.

-- ---------------------------------------------------------------------------
-- 1. Truly-visible: an active pin replaces the heartbeat requirement.
--    (Same shape as 20262014000000 section 2; only the is_online EXISTS gains
--    an OR branch. Nearby count / map cells / any caller inherit this.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_user_truly_visible(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
SELECT COALESCE((
  SELECT
    (
      (
        EXISTS (
          SELECT 1
          FROM public.user_activity ua
          WHERE ua.user_id = p_user_id
            AND ua.is_online = TRUE
            AND ua.last_activity > NOW() - INTERVAL '61 seconds'
        )
        OR public.is_pinned_location_active(p_user_id)
      )
      AND COALESCE(u.user_visibility_setting, false) = TRUE
      AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
      AND (
        EXISTS (
          SELECT 1
          FROM public.user_locations ul
          WHERE ul.user_id = p_user_id
            AND ul.updated_at >= NOW() - INTERVAL '15 minutes'
        )
        OR EXISTS (
          SELECT 1
          FROM public.user_locations ul
          WHERE ul.user_id = p_user_id
            AND COALESCE(ul.is_pinned, FALSE)
            AND ul.pinned_expires_at > NOW()
        )
      )
    )
  FROM public.users u
  WHERE u.id = p_user_id
), FALSE);
$$;

GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_user_truly_visible(UUID) TO anon;

-- ---------------------------------------------------------------------------
-- 2. find_nearby_users: a pinned candidate no longer needs a live heartbeat.
--    (Byte-identical to 20260101180000 except the is_online EXISTS gains an
--    OR branch. No location-recency filter exists here by design, so the
--    pin's coordinates are always eligible — the matching pool's own gate
--    decides freshness.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.find_nearby_users(
    current_user_id uuid,
    current_lat double precision,
    current_lng double precision,
    radius_km double precision
)
RETURNS TABLE(user_id uuid, latitude double precision, longitude double precision, distance_km double precision, updated_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  earth_km CONSTANT DOUBLE PRECISION := 6371.0;
BEGIN
  RETURN QUERY
  SELECT
    ul.user_id,
    ul.latitude,
    ul.longitude,
    (earth_km * acos(
      cos(radians(current_lat)) * cos(radians(ul.latitude)) * cos(radians(ul.longitude) - radians(current_lng))
      + sin(radians(current_lat)) * sin(radians(ul.latitude))
    ))::DOUBLE PRECISION AS distance_km,
    ul.updated_at
  FROM public.user_locations ul
  JOIN public.users u ON u.id = ul.user_id
  WHERE ul.user_id IS NOT NULL
    AND ul.user_id <> current_user_id
    AND COALESCE(u.user_visibility_setting, FALSE) = TRUE
    AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
    AND (
      EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE)
      OR public.is_pinned_location_active(u.id)
    )
    AND (earth_km * acos(
      cos(radians(current_lat)) * cos(radians(ul.latitude)) * cos(radians(ul.longitude) - radians(current_lng))
      + sin(radians(current_lat)) * sin(radians(ul.latitude))
    )) <= radius_km
  ORDER BY distance_km ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.find_nearby_users(uuid, double precision, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.find_nearby_users(uuid, double precision, double precision, double precision) TO anon;

-- ---------------------------------------------------------------------------
-- 3. Matching engine: pinned users stay in the pool with no heartbeat AND no
--    dependency on the cron touch tick.
--    (Byte-identical to 20261008000000 except:
--      a) pool gate: is_online EXISTS gains OR is_pinned_location_active(u.id)
--      b) pool gate: 5-minute freshness gains OR active-pin row (direct
--         exemption, so a missed cron touch can no longer drop a pinned user)
--      c) other-user SELECT (candidate gate) gains the same OR pin branch
--    The pool processes pinned users with the same visibility/system-status
--    requirements as everyone else — the pin never bypasses those.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.perform_continuous_user_matching()
RETURNS TABLE (users_processed INTEGER, matches_created INTEGER, status TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $_$
DECLARE
    user_record RECORD;
    nearby_user_record RECORD;
    total_users_processed INTEGER := 0;
    total_matches_created INTEGER := 0;
    matched_intent_result TEXT;
    shared_intent TEXT;
    shared_intents TEXT[];
    current_user_intents TEXT[];
    other_user_intents TEXT[];
    current_sub_intents_arr TEXT[];
    other_sub_intents_arr TEXT[];
    current_user_gender TEXT;
    current_user_dob DATE;
    current_user_age INTEGER;
    current_user_interests JSONB;
    current_user_lifestyle JSONB;
    current_user_family JSONB;
    current_user_religion JSONB;
    current_user_height INTEGER;
    current_user_prefs JSONB;
    other_user_gender TEXT;
    other_user_dob DATE;
    other_user_age INTEGER;
    other_user_interests JSONB;
    other_user_lifestyle JSONB;
    other_user_family JSONB;
    other_user_religion JSONB;
    other_user_height INTEGER;
    other_user_prefs JSONB;
    a_gender_ok BOOLEAN;
    a_age_ok BOOLEAN;
    b_gender_ok BOOLEAN;
    b_age_ok BOOLEAN;
    filters_compatible BOOLEAN;
    v_a uuid;
    v_b uuid;
    v_hist RECORD;
    v_next_occurrence int;
    v_max_occ int;
    v_center_lat double precision;
    v_center_lng double precision;
    v_dist_km double precision;
    v_zoom double precision;
BEGIN
    v_max_occ := public._get_max_match_occurrence();
    SET search_path = 'public';
    FOR user_record IN
        SELECT ul.user_id, ul.latitude, ul.longitude, u.match_radius_default, COALESCE(u.user_visibility_setting,false) AS user_visibility_setting, COALESCE(u.system_visibility_status,'visible') AS system_visibility_status
        FROM user_locations ul INNER JOIN users u ON ul.user_id = u.id
        WHERE ((EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE) OR public.is_pinned_location_active(u.id)) AND COALESCE(u.user_visibility_setting,false)=TRUE AND COALESCE(u.system_visibility_status,'visible')='visible')
        AND (ul.updated_at >= NOW() - INTERVAL '5 minutes' OR (COALESCE(ul.is_pinned, FALSE) AND ul.pinned_expires_at > NOW())) ORDER BY ul.updated_at DESC
    LOOP
        total_users_processed := total_users_processed + 1;
        SELECT gender, date_of_birth INTO current_user_gender, current_user_dob FROM users WHERE id = user_record.user_id;
        IF current_user_dob IS NOT NULL THEN current_user_age := EXTRACT(YEAR FROM AGE(current_user_dob)); ELSE current_user_age := NULL; END IF;
        SELECT lifestyle, family, religion, height, ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)), public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb)), intent_preferences
        INTO current_user_lifestyle, current_user_family, current_user_religion, current_user_height, current_user_intents, current_user_interests, current_user_prefs FROM user_profiles WHERE user_id = user_record.user_id;
        IF current_user_intents IS NULL THEN CONTINUE; END IF;
        FOR nearby_user_record IN SELECT * FROM find_nearby_users(user_record.user_id, user_record.latitude, user_record.longitude, (user_record.match_radius_default / 1000.0)::DOUBLE PRECISION) LOOP
            IF EXISTS (SELECT 1 FROM matches WHERE (user1_id = user_record.user_id AND user2_id = nearby_user_record.user_id) OR (user1_id = nearby_user_record.user_id AND user2_id = user_record.user_id)) THEN CONTINUE; END IF;
            v_a := LEAST(user_record.user_id, nearby_user_record.user_id);
            v_b := GREATEST(user_record.user_id, nearby_user_record.user_id);
            SELECT expiry_count, is_permanent INTO v_hist FROM public.unmatched_pairs WHERE user1_id = v_a AND user2_id = v_b;
            IF FOUND AND COALESCE(v_hist.is_permanent, false)=true THEN CONTINUE; END IF;
            IF FOUND AND COALESCE(v_hist.expiry_count,0) >= v_max_occ THEN CONTINUE; END IF;
            v_next_occurrence := COALESCE(v_hist.expiry_count, 0) + 1; IF v_next_occurrence > v_max_occ THEN CONTINUE; END IF;
            SELECT gender, date_of_birth INTO other_user_gender, other_user_dob FROM users WHERE id = nearby_user_record.user_id AND ((EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online=TRUE) OR public.is_pinned_location_active(users.id)) AND COALESCE(user_visibility_setting,false)=TRUE AND COALESCE(system_visibility_status,'visible')='visible');
            IF other_user_gender IS NULL THEN CONTINUE; END IF;
            IF other_user_dob IS NOT NULL THEN other_user_age := EXTRACT(YEAR FROM AGE(other_user_dob)); ELSE other_user_age := NULL; END IF;
            SELECT lifestyle, family, religion, height, ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)), public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb)), intent_preferences
            INTO other_user_lifestyle, other_user_family, other_user_religion, other_user_height, other_user_intents, other_user_interests, other_user_prefs FROM user_profiles WHERE user_id = nearby_user_record.user_id;
            IF other_user_intents IS NULL OR array_length(other_user_intents,1)=0 THEN CONTINUE; END IF;
            SELECT ARRAY(SELECT intent FROM unnest(current_user_intents) as t(intent) WHERE intent = ANY(other_user_intents)) INTO shared_intents;
            IF array_length(shared_intents,1) IS NULL OR array_length(shared_intents,1)=0 THEN CONTINUE; END IF;
            matched_intent_result := NULL;
            <<intent_loop>> FOREACH shared_intent IN ARRAY shared_intents LOOP
                current_sub_intents_arr := ARRAY(SELECT jsonb_array_elements_text(COALESCE((SELECT up.sub_intents -> shared_intent FROM user_profiles up WHERE up.user_id = user_record.user_id), '[]'::jsonb)));
                other_sub_intents_arr := ARRAY(SELECT jsonb_array_elements_text(COALESCE((SELECT up.sub_intents -> shared_intent FROM user_profiles up WHERE up.user_id = nearby_user_record.user_id), '[]'::jsonb)));
                IF array_length(current_sub_intents_arr,1) IS NULL OR array_length(other_sub_intents_arr,1) IS NULL THEN CONTINUE intent_loop; END IF;
                IF NOT (current_sub_intents_arr && other_sub_intents_arr) THEN CONTINUE intent_loop; END IF;
                a_gender_ok := (NOT ((other_user_prefs -> 'gender_preferences') ? shared_intent) OR ((other_user_prefs -> 'gender_preferences') -> shared_intent) ? current_user_gender);
                b_gender_ok := (NOT ((current_user_prefs -> 'gender_preferences') ? shared_intent) OR ((current_user_prefs -> 'gender_preferences') -> shared_intent) ? other_user_gender);
                IF NOT a_gender_ok OR NOT b_gender_ok THEN CONTINUE intent_loop; END IF;
                a_age_ok := (NOT ((other_user_prefs -> 'age_preferences') ? shared_intent) OR current_user_age IS NULL OR (jsonb_array_length((other_user_prefs -> 'age_preferences') -> shared_intent) >=2 AND current_user_age >= ((other_user_prefs -> 'age_preferences') -> shared_intent ->> 0)::numeric AND current_user_age <= ((other_user_prefs -> 'age_preferences') -> shared_intent ->> 1)::numeric));
                b_age_ok := (NOT ((current_user_prefs -> 'age_preferences') ? shared_intent) OR other_user_age IS NULL OR (jsonb_array_length((current_user_prefs -> 'age_preferences') -> shared_intent) >=2 AND other_user_age >= ((current_user_prefs -> 'age_preferences') -> shared_intent ->> 0)::numeric AND other_user_age <= ((current_user_prefs -> 'age_preferences') -> shared_intent ->> 1)::numeric));
                IF NOT a_age_ok OR NOT b_age_ok THEN CONTINUE intent_loop; END IF;
                filters_compatible := public.are_filters_compatible(current_user_lifestyle, current_user_family, current_user_religion, current_user_height, other_user_lifestyle, other_user_family, other_user_religion, other_user_height, (other_user_prefs -> 'lifestyle_filters'), (other_user_prefs -> 'family_filters'), (other_user_prefs -> 'religion_filters'), (other_user_prefs -> 'height_preferences'), (current_user_prefs -> 'lifestyle_filters'), (current_user_prefs -> 'family_filters'), (current_user_prefs -> 'religion_filters'), (current_user_prefs -> 'height_preferences'), shared_intent);
                IF NOT filters_compatible THEN CONTINUE intent_loop; END IF;
                IF current_user_interests IS NULL OR other_user_interests IS NULL OR current_user_interests = '{}'::jsonb OR other_user_interests = '{}'::jsonb THEN CONTINUE intent_loop; END IF;
                IF NOT EXISTS (SELECT 1 FROM jsonb_object_keys(current_user_interests) AS cat WHERE current_user_interests ? cat AND other_user_interests ? cat AND jsonb_array_length(current_user_interests->cat) >0 AND jsonb_array_length(other_user_interests->cat) >0 AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(current_user_interests->cat) AS sub WHERE sub = ANY(SELECT jsonb_array_elements_text(other_user_interests->cat)))) THEN CONTINUE intent_loop; END IF;
                matched_intent_result := shared_intent; EXIT intent_loop;
            END LOOP intent_loop;
            IF matched_intent_result IS NOT NULL THEN
                -- Coarse viewport: truncated center (~1.1km) + zoom capped
                v_center_lat := ROUND(((user_record.latitude + nearby_user_record.latitude)/2)::numeric, 2)::double precision;
                v_center_lng := ROUND(((user_record.longitude + nearby_user_record.longitude)/2)::numeric, 2)::double precision;
                v_dist_km := (6371.0 * acos( cos(radians(user_record.latitude)) * cos(radians(nearby_user_record.latitude)) * cos(radians(nearby_user_record.longitude) - radians(user_record.longitude)) + sin(radians(user_record.latitude)) * sin(radians(nearby_user_record.latitude)) ))::double precision;
                IF v_dist_km < 0.3 THEN v_zoom := 16;
                ELSIF v_dist_km < 0.6 THEN v_zoom := 15.5;
                ELSIF v_dist_km < 1.0 THEN v_zoom := 15;
                ELSIF v_dist_km < 2.0 THEN v_zoom := 14.5;
                ELSIF v_dist_km < 5.0 THEN v_zoom := 13.5;
                ELSIF v_dist_km < 10.0 THEN v_zoom := 12.5;
                ELSE v_zoom := 11;
                END IF;
                IF v_zoom > 16 THEN v_zoom := 16; END IF;
                INSERT INTO matches (user1_id, user2_id, matched_intent, match_type, created_at, match_occurrence, map_center_lat, map_center_lng, map_zoom)
                VALUES (v_a, v_b, matched_intent_result, 'proximity', NOW(), v_next_occurrence, v_center_lat, v_center_lng, v_zoom);
                total_matches_created := total_matches_created + 1;
            END IF;
        END LOOP;
    END LOOP;
    RETURN QUERY SELECT total_users_processed, total_matches_created, 'completed'::TEXT;
END;
$_$;
GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO anon;
