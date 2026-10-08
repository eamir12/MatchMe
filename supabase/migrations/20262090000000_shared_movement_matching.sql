-- Migration: Shared movement matching (co-motion)
-- Date: 2026-10-05
--
-- Product ruling: when BOTH users have shared_movement_matching_enabled = true
-- and the system detects them moving together (similar direction AND similar
-- speed, within a train-car distance), the pair is matched even if that
-- distance sits outside one (or both) users' match_radius_default. The radius
-- is never written or changed anywhere: the matcher computes an effective
-- per-pair radius at evaluation time, so the moment co-motion ends the next
-- cron run reverts to the users' stored radii by definition.
--
-- Train-car distance (~25m, admin tunable) is the bump ceiling because it
-- also covers buses (buses are shorter than train cars).
--
-- Detection lives inside perform_continuous_user_matching (the every-minute
-- cron) as a second candidate pass, so the whole existing lifecycle keeps
-- working for free: match expiry, unmatched_pairs occurrence caps, FCM
-- new-match push, recent matches, coarse minimap viewport.
--
-- Qualification reuses the standard proximity gate (shared intent + sub-intent,
-- mutual gender/age prefs per intent, lifestyle/family/religion/height
-- filters, shared interest). Matches created via the radius bump get
-- match_type = 'co_motion', which the client already renders as
-- "Moving together" (match profile basis row, minimap, match-type filters).
-- Pairs that would have matched inside their native radii anyway stay
-- 'proximity' and are not re-processed here.
--
-- Sustainment: a pair must be seen co-moving on two consecutive cron runs
-- (first_seen >= ~45s old while last_seen stays fresh) before a match is
-- created, to reject false positives (cars at a light, brief overtakes).
-- movement_co_motion rows older than 5 minutes are purged; nothing in the
-- table outlives the journey and no coordinates are ever stored in it.
--
-- Pinned users need no special handling: pinning NULLs speed/heading, so a
-- pinned user can never look "in motion".

BEGIN;

-- =============================================================
-- 1) Admin-tunable thresholds (pattern: retro.* config rows)
-- =============================================================
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value, allowed_values) VALUES
  ('matching.movement_corridor_meters', '25', 'number', 'gps', 'Max pair distance for shared-movement matching; roughly a train car so it also covers buses (meters). This is also the temporary radius bump ceiling.', false, 10, 100, null),
  ('matching.movement_min_speed_mps', '3', 'number', 'gps', 'Minimum speed (m/s) for heading to be trusted; below this users are not considered in motion for shared-movement matching (excludes pedestrians, who are served by proximity matching).', false, 1, 10, null),
  ('matching.movement_heading_tolerance_deg', '45', 'number', 'gps', 'Max angular difference between the two users'' headings to count as moving in the same direction (degrees)', false, 10, 90, null),
  ('matching.movement_speed_tolerance_ratio', '0.3', 'number', 'gps', 'Max relative speed difference to count as moving at a similar speed (fraction of the faster speed; a 1.5 m/s absolute floor applies)', false, 0.05, 1, null)
ON CONFLICT (config_key) DO NOTHING;

-- Generic numeric config reader with clamping (pattern: _get_max_match_occurrence)
CREATE OR REPLACE FUNCTION public._get_config_numeric(
    p_key text,
    p_default numeric,
    p_min numeric,
    p_max numeric
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $_$
DECLARE
    v numeric;
BEGIN
    SELECT NULLIF(config_value::text, '')::numeric INTO v
      FROM public.app_config WHERE config_key = p_key LIMIT 1;
    IF v IS NULL THEN v := p_default; END IF;
    IF v < p_min THEN v := p_min; END IF;
    IF v > p_max THEN v := p_max; END IF;
    RETURN v;
END;
$_$;

-- =============================================================
-- 2) Co-motion sustainment staging table
--    One row per pair currently (or recently) co-moving. No coordinates.
--    RLS on with no policies: nothing can read it except the
--    SECURITY DEFINER matcher below and service_role.
-- =============================================================
CREATE TABLE IF NOT EXISTS public.movement_co_motion (
    user1_id uuid NOT NULL,
    user2_id uuid NOT NULL,
    first_seen timestamptz NOT NULL DEFAULT NOW(),
    last_seen timestamptz NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user1_id, user2_id),
    CHECK (user1_id < user2_id)
);

ALTER TABLE public.movement_co_motion ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.movement_co_motion FROM anon, authenticated;

-- =============================================================
-- 3) Continuous matcher: add the co-motion pass
-- =============================================================
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
    move_rec RECORD;
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
    other_radius_meters INTEGER;
    v_center_lat double precision;
    v_center_lng double precision;
    v_dist_km double precision;
    v_zoom double precision;
    -- shared movement (co-motion) pass
    v_corridor_m numeric;
    v_min_speed numeric;
    v_head_tol numeric;
    v_speed_ratio numeric;
    v_head_diff double precision;
    v_cm_first timestamptz;
    v_cm_last timestamptz;
    v_sustained boolean;
BEGIN
    v_max_occ := public._get_max_match_occurrence();
    SET search_path = 'public';

    v_corridor_m := public._get_config_numeric('matching.movement_corridor_meters', 25, 10, 100);
    v_min_speed := public._get_config_numeric('matching.movement_min_speed_mps', 3, 1, 10);
    v_head_tol := public._get_config_numeric('matching.movement_heading_tolerance_deg', 45, 10, 90);
    v_speed_ratio := public._get_config_numeric('matching.movement_speed_tolerance_ratio', 0.3, 0.05, 1);

    -- Co-motion is over once rows go stale; nothing outlives the journey.
    DELETE FROM public.movement_co_motion WHERE last_seen < NOW() - INTERVAL '5 minutes';

    FOR user_record IN
        SELECT ul.user_id, ul.latitude, ul.longitude, ul.speed, ul.heading,
               u.match_radius_default, COALESCE(u.shared_movement_matching_enabled, FALSE) AS movement_enabled,
               COALESCE(u.user_visibility_setting,false) AS user_visibility_setting, COALESCE(u.system_visibility_status,'visible') AS system_visibility_status
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
            SELECT gender, date_of_birth, match_radius_default INTO other_user_gender, other_user_dob, other_radius_meters FROM users WHERE id = nearby_user_record.user_id AND ((EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online=TRUE) OR public.is_pinned_location_active(users.id)) AND COALESCE(user_visibility_setting,false)=TRUE AND COALESCE(system_visibility_status,'visible')='visible');
            IF other_user_gender IS NULL THEN CONTINUE; END IF;
            -- Mutual radius: the pair distance must also sit inside the OTHER
            -- user's chosen radius. find_nearby_users already enforced the
            -- initiator's; without this check user B could be matched with
            -- someone outside B's setting whenever A's radius covered the pair.
            IF nearby_user_record.distance_km * 1000.0 > other_radius_meters THEN CONTINUE; END IF;
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

        -- =========================================================
        -- Shared movement (co-motion) pass.
        -- Candidates within the corridor (~train car) regardless of the
        -- users' radii: their radii would otherwise never surface this
        -- pair, which is exactly the point of the bump.
        -- =========================================================
        IF COALESCE(user_record.movement_enabled, FALSE)
           AND user_record.speed IS NOT NULL AND user_record.speed >= v_min_speed
           AND user_record.heading IS NOT NULL THEN
            FOR move_rec IN
                SELECT n.user_id, n.latitude, n.longitude, n.distance_km,
                       mloc.speed AS m_speed, mloc.heading AS m_heading,
                       mu.match_radius_default AS m_radius
                FROM find_nearby_users(user_record.user_id, user_record.latitude, user_record.longitude, (v_corridor_m / 1000.0)::double precision) n
                JOIN user_locations mloc ON mloc.user_id = n.user_id
                JOIN users mu ON mu.id = n.user_id
                WHERE COALESCE(mu.shared_movement_matching_enabled, FALSE) = TRUE
                  AND mloc.speed IS NOT NULL AND mloc.speed >= v_min_speed
                  AND mloc.heading IS NOT NULL
            LOOP
                v_a := LEAST(user_record.user_id, move_rec.user_id);
                v_b := GREATEST(user_record.user_id, move_rec.user_id);
                -- Similar direction: wrap-aware heading difference.
                v_head_diff := LEAST(ABS(user_record.heading - move_rec.m_heading), 360.0 - ABS(user_record.heading - move_rec.m_heading));
                IF v_head_diff > v_head_tol THEN CONTINUE; END IF;
                -- Similar speed: relative tolerance with an absolute floor.
                IF ABS(user_record.speed - move_rec.m_speed) > GREATEST(v_speed_ratio * GREATEST(user_record.speed, move_rec.m_speed), 1.5) THEN CONTINUE; END IF;
                -- Pairs already inside BOTH native radii are the proximity
                -- loop's job; the bump only applies when it is actually needed.
                IF move_rec.distance_km * 1000.0 <= LEAST(user_record.match_radius_default, move_rec.m_radius) THEN CONTINUE; END IF;
                IF EXISTS (SELECT 1 FROM matches WHERE (user1_id = v_a AND user2_id = v_b)) THEN CONTINUE; END IF;
                SELECT expiry_count, is_permanent INTO v_hist FROM public.unmatched_pairs WHERE user1_id = v_a AND user2_id = v_b;
                IF FOUND AND COALESCE(v_hist.is_permanent, false)=true THEN CONTINUE; END IF;
                IF FOUND AND COALESCE(v_hist.expiry_count,0) >= v_max_occ THEN CONTINUE; END IF;
                v_next_occurrence := COALESCE(v_hist.expiry_count, 0) + 1; IF v_next_occurrence > v_max_occ THEN CONTINUE; END IF;
                -- Sustainment: confirmed co-motion across two consecutive
                -- runs (~45s apart with the 1-minute cron) before matching.
                v_sustained := FALSE;
                SELECT first_seen, last_seen INTO v_cm_first, v_cm_last FROM public.movement_co_motion WHERE user1_id = v_a AND user2_id = v_b;
                IF FOUND THEN
                    IF v_cm_last >= NOW() - INTERVAL '120 seconds' AND v_cm_first <= NOW() - INTERVAL '45 seconds' THEN
                        v_sustained := TRUE;
                        UPDATE public.movement_co_motion SET last_seen = NOW() WHERE user1_id = v_a AND user2_id = v_b;
                    ELSIF v_cm_last >= NOW() - INTERVAL '120 seconds' THEN
                        -- Still co-moving, but not yet sustained: keep first_seen.
                        UPDATE public.movement_co_motion SET last_seen = NOW() WHERE user1_id = v_a AND user2_id = v_b;
                    ELSE
                        -- Stale (co-motion broke and restarted): restart the window.
                        UPDATE public.movement_co_motion SET last_seen = NOW(), first_seen = NOW() WHERE user1_id = v_a AND user2_id = v_b;
                    END IF;
                ELSE
                    INSERT INTO public.movement_co_motion (user1_id, user2_id) VALUES (v_a, v_b);
                END IF;
                IF NOT v_sustained THEN CONTINUE; END IF;
                -- Standard qualification gate (identical to proximity).
                SELECT gender, date_of_birth INTO other_user_gender, other_user_dob FROM users WHERE id = move_rec.user_id;
                IF other_user_gender IS NULL THEN CONTINUE; END IF;
                IF other_user_dob IS NOT NULL THEN other_user_age := EXTRACT(YEAR FROM AGE(other_user_dob)); ELSE other_user_age := NULL; END IF;
                SELECT lifestyle, family, religion, height, ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)), public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb)), intent_preferences
                INTO other_user_lifestyle, other_user_family, other_user_religion, other_user_height, other_user_intents, other_user_interests, other_user_prefs FROM user_profiles WHERE user_id = move_rec.user_id;
                IF other_user_intents IS NULL OR array_length(other_user_intents,1)=0 THEN CONTINUE; END IF;
                SELECT ARRAY(SELECT intent FROM unnest(current_user_intents) as t(intent) WHERE intent = ANY(other_user_intents)) INTO shared_intents;
                IF array_length(shared_intents,1) IS NULL OR array_length(shared_intents,1)=0 THEN CONTINUE; END IF;
                matched_intent_result := NULL;
                <<comotion_intent_loop>> FOREACH shared_intent IN ARRAY shared_intents LOOP
                    current_sub_intents_arr := ARRAY(SELECT jsonb_array_elements_text(COALESCE((SELECT up.sub_intents -> shared_intent FROM user_profiles up WHERE up.user_id = user_record.user_id), '[]'::jsonb)));
                    other_sub_intents_arr := ARRAY(SELECT jsonb_array_elements_text(COALESCE((SELECT up.sub_intents -> shared_intent FROM user_profiles up WHERE up.user_id = move_rec.user_id), '[]'::jsonb)));
                    IF array_length(current_sub_intents_arr,1) IS NULL OR array_length(other_sub_intents_arr,1) IS NULL THEN CONTINUE comotion_intent_loop; END IF;
                    IF NOT (current_sub_intents_arr && other_sub_intents_arr) THEN CONTINUE comotion_intent_loop; END IF;
                    a_gender_ok := (NOT ((other_user_prefs -> 'gender_preferences') ? shared_intent) OR ((other_user_prefs -> 'gender_preferences') -> shared_intent) ? current_user_gender);
                    b_gender_ok := (NOT ((current_user_prefs -> 'gender_preferences') ? shared_intent) OR ((current_user_prefs -> 'gender_preferences') -> shared_intent) ? other_user_gender);
                    IF NOT a_gender_ok OR NOT b_gender_ok THEN CONTINUE comotion_intent_loop; END IF;
                    a_age_ok := (NOT ((other_user_prefs -> 'age_preferences') ? shared_intent) OR current_user_age IS NULL OR (jsonb_array_length((other_user_prefs -> 'age_preferences') -> shared_intent) >=2 AND current_user_age >= ((other_user_prefs -> 'age_preferences') -> shared_intent ->> 0)::numeric AND current_user_age <= ((other_user_prefs -> 'age_preferences') -> shared_intent ->> 1)::numeric));
                    b_age_ok := (NOT ((current_user_prefs -> 'age_preferences') ? shared_intent) OR other_user_age IS NULL OR (jsonb_array_length((current_user_prefs -> 'age_preferences') -> shared_intent) >=2 AND other_user_age >= ((current_user_prefs -> 'age_preferences') -> shared_intent ->> 0)::numeric AND other_user_age <= ((current_user_prefs -> 'age_preferences') -> shared_intent ->> 1)::numeric));
                    IF NOT a_age_ok OR NOT b_age_ok THEN CONTINUE comotion_intent_loop; END IF;
                    filters_compatible := public.are_filters_compatible(current_user_lifestyle, current_user_family, current_user_religion, current_user_height, other_user_lifestyle, other_user_family, other_user_religion, other_user_height, (other_user_prefs -> 'lifestyle_filters'), (other_user_prefs -> 'family_filters'), (other_user_prefs -> 'religion_filters'), (other_user_prefs -> 'height_preferences'), (current_user_prefs -> 'lifestyle_filters'), (current_user_prefs -> 'family_filters'), (current_user_prefs -> 'religion_filters'), (current_user_prefs -> 'height_preferences'), shared_intent);
                    IF NOT filters_compatible THEN CONTINUE comotion_intent_loop; END IF;
                    IF current_user_interests IS NULL OR other_user_interests IS NULL OR current_user_interests = '{}'::jsonb OR other_user_interests = '{}'::jsonb THEN CONTINUE comotion_intent_loop; END IF;
                    IF NOT EXISTS (SELECT 1 FROM jsonb_object_keys(current_user_interests) AS cat WHERE current_user_interests ? cat AND other_user_interests ? cat AND jsonb_array_length(current_user_interests->cat) >0 AND jsonb_array_length(other_user_interests->cat) >0 AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(current_user_interests->cat) AS sub WHERE sub = ANY(SELECT jsonb_array_elements_text(other_user_interests->cat)))) THEN CONTINUE comotion_intent_loop; END IF;
                    matched_intent_result := shared_intent; EXIT comotion_intent_loop;
                END LOOP comotion_intent_loop;
                IF matched_intent_result IS NOT NULL THEN
                    v_center_lat := ROUND(((user_record.latitude + move_rec.latitude)/2)::numeric, 2)::double precision;
                    v_center_lng := ROUND(((user_record.longitude + move_rec.longitude)/2)::numeric, 2)::double precision;
                    v_dist_km := move_rec.distance_km;
                    IF v_dist_km < 0.3 THEN v_zoom := 16;
                    ELSIF v_dist_km < 0.6 THEN v_zoom := 15.5;
                    ELSIF v_dist_km < 1.0 THEN v_zoom := 15;
                    ELSE v_zoom := 14.5;
                    END IF;
                    INSERT INTO matches (user1_id, user2_id, matched_intent, match_type, created_at, match_occurrence, map_center_lat, map_center_lng, map_zoom)
                    VALUES (v_a, v_b, matched_intent_result, 'co_motion', NOW(), v_next_occurrence, v_center_lat, v_center_lng, v_zoom);
                    total_matches_created := total_matches_created + 1;
                END IF;
            END LOOP;
        END IF;
    END LOOP;
    RETURN QUERY SELECT total_users_processed, total_matches_created, 'completed'::TEXT;
END;
$_$;
GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO anon;

COMMIT;
