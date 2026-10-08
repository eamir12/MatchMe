-- Migration: Mutual match radius everywhere + meters-only units hygiene
-- Date: 2026-10-05
-- Depends on: 20262085000000 / 20262086000000 (pin exemptions)
--
-- Product ruling: MatchMe is short-distance matching — units are meters
-- (displayed as feet for imperial users), and EVERY matching algorithm must
-- respect BOTH users' requested match radius (match_radius_default, meters,
-- options [5, 10, 20, 100]).
--
-- What this fixes:
--
--   1. Live proximity matcher (perform_continuous_user_matching): was
--      one-sided — only the processing user's radius gated the pair, so
--      user B could be matched with someone outside B's radius whenever
--      A's radius covered it. Now the pair distance must also be inside
--      the OTHER user's radius.
--
--   2. Retro matcher (perform_retroactive_matching): used a fixed 100m
--      co-presence window (retro.distance_meters) and ignored both users'
--      radii. The co-presence window stays (it is what defines "same place
--      at the same time"), but a pair now also has to sit inside BOTH
--      users' match_radius_default, so small-radius users no longer get
--      retro matches outside their setting.
--
--   3. Browse lists (get_potential_matches / _by_intents): now also respect
--      the CANDIDATE's radius — a candidate whose own radius excludes the
--      viewer can never actually match, so showing them was misleading.
--
--   4. Units hygiene (meters-only ruling):
--      - app_config profile.match_radius_default_meters was 50000 (50 km) —
--        a leftover from the 20260713 km->meters rename (which converted the
--        old km default '20' incorrectly and out of the options range). It
--        is the fallback radius in _fetchLiveDashboardStats when a user row
--        cannot be read. Now 100 (the max option), bounds 5..100.
--      - users.match_radius_default: NULLs backfilled to 50 (the column
--        default), values clamped into the options range, SET NOT NULL with
--        a 1..1000 CHECK so a future km-scale accident cannot happen. This
--        also makes the stale 10000m COALESCE fallbacks in the admin match
--        inspector dead code.
--
-- find_nearby_users() is unchanged: it is a generic "candidates within a
-- given radius" search; the mutual rule lives in the callers that create
-- matches.

-- =============================================================
-- (1) Units hygiene: app_config default + users column invariants
-- =============================================================
UPDATE public.app_config
SET config_value = '100',
    min_value = 5,
    max_value = 100
WHERE config_key = 'profile.match_radius_default_meters'
  AND (config_value <> '100' OR min_value <> 5 OR max_value <> 100);

UPDATE public.users SET match_radius_default = 50 WHERE match_radius_default IS NULL;
UPDATE public.users SET match_radius_default = 100 WHERE match_radius_default > 100;
UPDATE public.users SET match_radius_default = 5 WHERE match_radius_default < 5;

ALTER TABLE public.users ALTER COLUMN match_radius_default SET DEFAULT 50;
ALTER TABLE public.users ALTER COLUMN match_radius_default SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'users_match_radius_default_chk'
  ) THEN
    -- Generous bounds: wide enough for future admin-added options, tight
    -- enough that a km-scale value can never slip in again.
    ALTER TABLE public.users
      ADD CONSTRAINT users_match_radius_default_chk
      CHECK (match_radius_default BETWEEN 1 AND 1000);
  END IF;
END $$;

-- =============================================================
-- (2)
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
    other_radius_meters INTEGER;
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
    END LOOP;
    RETURN QUERY SELECT total_users_processed, total_matches_created, 'completed'::TEXT;
END;
$_$;
GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO anon;

-- =============================================================
-- (3)
CREATE OR REPLACE FUNCTION public.perform_retroactive_matching(p_user_id uuid)
RETURNS TABLE (matches_created integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;
GRANT EXECUTE ON FUNCTION public.perform_retroactive_matching(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_retroactive_matching(uuid) TO service_role;

-- =============================================================
-- (4)
CREATE OR REPLACE FUNCTION public.get_potential_matches(
  p_user_id UUID,
  p_latitude DOUBLE PRECISION,
  p_longitude DOUBLE PRECISION,
  p_radius_km DOUBLE PRECISION DEFAULT 50
)
RETURNS TABLE(
  user_id UUID,
  distance_km DOUBLE PRECISION,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  display_name TEXT,
  profile_data JSONB
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  earth_km CONSTANT DOUBLE PRECISION := 6371.0;
BEGIN
  RETURN QUERY
  SELECT
    ul.user_id,
    (earth_km * acos(
      cos(radians(p_latitude)) * cos(radians(ul.latitude)) *
      cos(radians(ul.longitude) - radians(p_longitude)) +
      sin(radians(p_latitude)) * sin(radians(ul.latitude))
    ))::DOUBLE PRECISION AS distance_km,
    ul.latitude,
    ul.longitude,
    public.mask_full_name(u.name) AS display_name,
    jsonb_build_object(
      'name', public.mask_full_name(u.name),
      'photos', COALESCE(up.photos, '[]'::jsonb),
      'gender', u.gender,
      'date_of_birth', u.date_of_birth,
      'bio', up.bio,
      'height', up.height,
      'occupation', up.occupation,
      'education', up.education,
      'zodiac_sign', up.zodiac_sign,
      'lifestyle', up.lifestyle,
      'family', up.family,
      'religion', up.religion,
      'active_modes', COALESCE(up.active_modes, '[]'::jsonb),
      'personal_interests', COALESCE(up.personal_interests, '{}'::jsonb),
      'business_interests', COALESCE(up.business_interests, '{}'::jsonb)
    ) AS profile_data
  FROM public.user_locations ul
  INNER JOIN public.users u ON u.id = ul.user_id
  LEFT JOIN public.user_profiles up ON up.user_id = u.id
  WHERE ul.user_id != p_user_id
    AND COALESCE(u.user_visibility_setting, false) = true
    AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
    AND ul.latitude IS NOT NULL
    AND ul.longitude IS NOT NULL
    AND ul.updated_at >= NOW() - INTERVAL '30 minutes'
    AND NOT EXISTS (
      SELECT 1 FROM public.matches m
      WHERE (m.user1_id = p_user_id AND m.user2_id = ul.user_id)
         OR (m.user1_id = ul.user_id AND m.user2_id = p_user_id)
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.unmatched_pairs up2
      WHERE (up2.user1_id = p_user_id AND up2.user2_id = ul.user_id)
         OR (up2.user1_id = ul.user_id AND up2.user2_id = p_user_id)
    )
    AND (earth_km * acos(
      cos(radians(p_latitude)) * cos(radians(ul.latitude)) *
      cos(radians(ul.longitude) - radians(p_longitude)) +
      sin(radians(p_latitude)) * sin(radians(ul.latitude))
    )) <= p_radius_km
    -- Mutual radius: also respect the CANDIDATE's own match radius so the
    -- browse list only shows pairs the matchers could actually create.
    AND (earth_km * acos(
      cos(radians(p_latitude)) * cos(radians(ul.latitude)) *
      cos(radians(ul.longitude) - radians(p_longitude)) +
      sin(radians(p_latitude)) * sin(radians(ul.latitude))
    )) * 1000.0 <= COALESCE(u.match_radius_default, 50)
  ORDER BY distance_km ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_potential_matches(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_potential_matches(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO anon;

-- =============================================================
-- (5)
CREATE OR REPLACE FUNCTION public.get_potential_matches_by_intents(
  p_user_id UUID,
  p_latitude DOUBLE PRECISION,
  p_longitude DOUBLE PRECISION,
  p_radius_km DOUBLE PRECISION DEFAULT 50,
  p_intents TEXT[] DEFAULT NULL
)
RETURNS TABLE(
  user_id UUID,
  distance_km DOUBLE PRECISION,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  display_name TEXT,
  profile_data JSONB,
  shared_intents TEXT[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  earth_km CONSTANT DOUBLE PRECISION := 6371.0;
  current_active TEXT[];
BEGIN
  -- Get requesting user's active intents
  SELECT ARRAY(SELECT jsonb_array_elements_text(up.active_modes::jsonb))
  INTO current_active
  FROM user_profiles up WHERE up.user_id = p_user_id;

  IF current_active IS NULL THEN current_active := ARRAY[]::text[]; END IF;

  RETURN QUERY
  WITH nearby AS (
    SELECT
      ul.user_id,
      (earth_km * acos(
        cos(radians(p_latitude)) * cos(radians(ul.latitude)) *
        cos(radians(ul.longitude) - radians(p_longitude)) +
        sin(radians(p_latitude)) * sin(radians(ul.latitude))
      ))::DOUBLE PRECISION AS dist,
      ul.latitude,
      ul.longitude
    FROM public.user_locations ul
    INNER JOIN public.users u ON u.id = ul.user_id
    WHERE ul.user_id != p_user_id
      AND COALESCE(u.user_visibility_setting, false) = true
      AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
      AND ul.latitude IS NOT NULL
      AND ul.longitude IS NOT NULL
      AND ul.updated_at >= NOW() - INTERVAL '30 minutes'
      AND (earth_km * acos(
        cos(radians(p_latitude)) * cos(radians(ul.latitude)) *
        cos(radians(ul.longitude) - radians(p_longitude)) +
        sin(radians(p_latitude)) * sin(radians(ul.latitude))
      )) <= p_radius_km
      -- Mutual radius: also respect the CANDIDATE's own match radius.
      AND (earth_km * acos(
        cos(radians(p_latitude)) * cos(radians(ul.latitude)) *
        cos(radians(ul.longitude) - radians(p_longitude)) +
        sin(radians(p_latitude)) * sin(radians(ul.latitude))
      )) * 1000.0 <= COALESCE(u.match_radius_default, 50)
  ),
  other_intents AS (
    SELECT n.user_id,
           ARRAY(SELECT jsonb_array_elements_text(up.active_modes::jsonb)) AS intents
    FROM nearby n
    INNER JOIN user_profiles up ON up.user_id = n.user_id
  )
  SELECT
    n.user_id,
    n.dist,
    n.latitude,
    n.longitude,
    public.mask_full_name(u.name) AS display_name,
    jsonb_build_object(
      'name', public.mask_full_name(u.name),
      'photos', COALESCE(up.photos, '[]'::jsonb),
      'gender', u.gender,
      'date_of_birth', u.date_of_birth,
      'bio', up.bio,
      'height', up.height,
      'occupation', up.occupation,
      'education', up.education,
      'zodiac_sign', up.zodiac_sign,
      'lifestyle', up.lifestyle,
      'family', up.family,
      'religion', up.religion,
      'active_modes', COALESCE(up.active_modes, '[]'::jsonb),
      'personal_interests', COALESCE(up.personal_interests, '{}'::jsonb),
      'business_interests', COALESCE(up.business_interests, '{}'::jsonb)
    ) AS profile_data,
    ARRAY(
      SELECT intent FROM unnest(current_active) AS t(intent)
      WHERE intent = ANY(oi.intents)
    ) AS shared_intents
  FROM nearby n
  INNER JOIN public.users u ON u.id = n.user_id
  LEFT JOIN public.user_profiles up ON up.user_id = n.user_id
  INNER JOIN other_intents oi ON oi.user_id = n.user_id
  WHERE NOT EXISTS (
      SELECT 1 FROM public.matches m
      WHERE (m.user1_id = p_user_id AND m.user2_id = n.user_id)
         OR (m.user1_id = n.user_id AND m.user2_id = p_user_id)
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.unmatched_pairs up2
      WHERE (up2.user1_id = p_user_id AND up2.user2_id = n.user_id)
         OR (up2.user1_id = n.user_id AND up2.user2_id = p_user_id)
    )
    AND ARRAY(SELECT intent FROM unnest(current_active) AS t(intent) WHERE intent = ANY(oi.intents)) IS NOT NULL
    AND array_length(ARRAY(SELECT intent FROM unnest(current_active) AS t(intent) WHERE intent = ANY(oi.intents)), 1) > 0
    AND (p_intents IS NULL OR array_length(p_intents, 1) IS NULL OR
         ARRAY(SELECT intent FROM unnest(current_active) AS t(intent) WHERE intent = ANY(oi.intents) AND intent = ANY(p_intents)) IS NOT NULL)
  ORDER BY n.dist ASC;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_potential_matches_by_intents(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_potential_matches_by_intents(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT[]) TO anon;

