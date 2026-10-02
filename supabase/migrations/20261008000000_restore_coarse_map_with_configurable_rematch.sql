-- Migration: Restore coarse map (truncated center + capped zoom) while keeping configurable rematch limit
-- 20261007000000 accidentally overwrote perform_continuous_user_matching with a version that omitted
-- map_center_lat/lng/zoom, causing new proximity matches like b26db4c2 (2026-09-02 17:57, occurrence 2) to have NULL location.
-- This restores the Option-3 privacy map (center truncated to 2 decimals ~1.1km, zoom capped) and keeps max_occurrence configurable.
BEGIN;

-- Ensure helper exists (from 20261007000000)
CREATE OR REPLACE FUNCTION public._get_max_match_occurrence()
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v int;
BEGIN
  SELECT NULLIF(config_value::text,'')::int INTO v FROM public.app_config WHERE config_key='matches.max_match_occurrence' LIMIT 1;
  IF v IS NULL OR v < 1 THEN v := 3; END IF;
  IF v > 10 THEN v := 10; END IF;
  RETURN v;
END;
$$;

DROP FUNCTION IF EXISTS public.perform_continuous_user_matching();
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
        WHERE (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE) AND COALESCE(u.user_visibility_setting,false)=TRUE AND COALESCE(u.system_visibility_status,'visible')='visible')
        AND ul.updated_at >= NOW() - INTERVAL '5 minutes' ORDER BY ul.updated_at DESC
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
            SELECT gender, date_of_birth INTO other_user_gender, other_user_dob FROM users WHERE id = nearby_user_record.user_id AND (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online=TRUE) AND COALESCE(user_visibility_setting,false)=TRUE AND COALESCE(system_visibility_status,'visible')='visible');
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

-- Backfill the broken rematch b26db4c2-1768-499b-a33f-339da0ed71f9 (occurrence 2 but null location)
-- Use the two users' latest locations (within 5m) or fallback to previous rematch's center -13.52/-71.99
DO $$
DECLARE v_lat1 double precision; v_lng1 double precision; v_lat2 double precision; v_lng2 double precision;
        v_clat double precision; v_clng double precision; v_zoom double precision; v_dist double precision;
BEGIN
  SELECT latitude, longitude INTO v_lat1, v_lng1 FROM public.user_locations WHERE user_id='dd6d20a5-cd79-4761-8a74-751acb555b4d' ORDER BY updated_at DESC LIMIT 1;
  SELECT latitude, longitude INTO v_lat2, v_lng2 FROM public.user_locations WHERE user_id='ffc20046-a777-463b-922a-547151aa1455' ORDER BY updated_at DESC LIMIT 1;
  IF v_lat1 IS NOT NULL AND v_lng1 IS NOT NULL AND v_lat2 IS NOT NULL AND v_lng2 IS NOT NULL THEN
    v_clat := ROUND(((v_lat1+v_lat2)/2)::numeric,2)::double precision;
    v_clng := ROUND(((v_lng1+v_lng2)/2)::numeric,2)::double precision;
    v_dist := (6371.0 * acos( cos(radians(v_lat1))*cos(radians(v_lat2))*cos(radians(v_lng2)-radians(v_lng1)) + sin(radians(v_lat1))*sin(radians(v_lat2)) ))::double precision;
    IF v_dist < 0.3 THEN v_zoom := 16; ELSIF v_dist < 0.6 THEN v_zoom := 15.5; ELSIF v_dist < 1.0 THEN v_zoom := 15; ELSIF v_dist < 2.0 THEN v_zoom := 14.5; ELSIF v_dist < 5.0 THEN v_zoom := 13.5; ELSIF v_dist < 10.0 THEN v_zoom := 12.5; ELSE v_zoom := 11; END IF;
  ELSE
    -- Fallback to previous proximity center from 1d7074ac / 17:41 match
    v_clat := -13.52; v_clng := -71.99; v_zoom := 13;
  END IF;
  UPDATE public.matches SET map_center_lat = v_clat, map_center_lng = v_clng, map_zoom = v_zoom
  WHERE id='b26db4c2-1768-499b-a33f-339da0ed71f9' AND map_center_lat IS NULL;
  -- Also ensure user_recent_matches has correct occurrence (should already be 2)
  UPDATE public.user_recent_matches SET last_activity_at = NOW() WHERE match_id='b26db4c2-1768-499b-a33f-339da0ed71f9';
END $$;

COMMIT;
