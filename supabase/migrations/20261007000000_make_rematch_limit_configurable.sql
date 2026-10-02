-- Migration: Make rematch limit configurable via app_config and fix unmatched_pairs handling
-- Question: Should unmatched_pairs row stay on rematch? YES - it must stay to count expiries.
--   - On first expiry without chat: INSERT expiry_count=1, is_permanent=(1>=max)
--   - On rematch: keep row, compute v_next_occurrence = expiry_count+1 (1->2, 2->3)
--   - On next expiry: UPDATE expiry_count+1, is_permanent=(new>=max)
--   - Manual unmatch via unmatch_from_system_match sets is_permanent=true → never rematch
--   - Row is NEVER deleted on rematch; only deleted if you explicitly want to reset (not here)
-- This migration adds app_config keys and rewrites 3 functions to read them.
-- Also fixes the inconsistent data seen: 2026-09-02 17:24 unmatched_pairs expiry_count=0 but should be 1,
-- and 2026-09-02 17:41 rematch occurrence=1 but should be 2.

BEGIN;

-- 1) Config: total allowed match_occurrences (1 = no rematch, 3 = 2 rematches). Default 3.
INSERT INTO public.app_config (config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value)
VALUES (
  'matches.max_match_occurrence',
  '3',
  'integer',
  'matching',
  'Maximum times the same pair can be matched (1 = no rematch, 3 = original + 2 rematches). When expiry_count reaches this, is_permanent=true and no further rematches are created.',
  true,
  1,
  10
)
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description;

-- Helper to read max occurrence with fallback 3
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

-- 2) Rewrite cleanup_expired_matches to be configurable and correctly track expiry_count
DROP FUNCTION IF EXISTS public.cleanup_expired_matches(timestamptz, int);
CREATE OR REPLACE FUNCTION public.cleanup_expired_matches(p_cutoff timestamptz, p_limit int DEFAULT 500)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_window_cfg int;
  v_max_occ int;
  v_eligible RECORD;
  v_a uuid;
  v_b uuid;
  v_hist RECORD;
  v_new_count int;
  v_is_perm boolean;
  v_count int := 0;
BEGIN
  SELECT NULLIF(config_value::text,'')::int INTO v_window_cfg FROM public.app_config WHERE config_key = 'matches.chat_start_window_seconds' LIMIT 1;
  IF v_window_cfg IS NULL OR v_window_cfg <= 0 THEN v_window_cfg := 86400; END IF;
  v_max_occ := public._get_max_match_occurrence();
  FOR v_eligible IN
    SELECT m.id, m.user1_id, m.user2_id, m.match_type, m.match_occurrence
    FROM public.matches m
    WHERE m.match_type IN ('proximity','event','co_motion')
      AND m.created_at + make_interval(secs => COALESCE(m.chat_start_window_seconds, v_window_cfg) + COALESCE(m.chat_start_extension_seconds, 0)) < now()
    ORDER BY m.created_at LIMIT COALESCE(p_limit, 500)
  LOOP
    IF EXISTS (SELECT 1 FROM public.chat_messages cm WHERE cm.match_id = v_eligible.id LIMIT 1) THEN CONTINUE; END IF;
    v_a := LEAST(v_eligible.user1_id, v_eligible.user2_id);
    v_b := GREATEST(v_eligible.user1_id, v_eligible.user2_id);
    SELECT expiry_count, is_permanent INTO v_hist FROM public.unmatched_pairs WHERE user1_id = v_a AND user2_id = v_b FOR UPDATE;
    IF NOT FOUND THEN
      v_new_count := 1;
      v_is_perm := v_new_count >= v_max_occ;
      INSERT INTO public.unmatched_pairs (user1_id, user2_id, created_by, created_at, match_type, match_id, expiry_count, is_permanent)
      VALUES (v_a, v_b, '00000000-0000-0000-0000-000000000000'::uuid, now(), v_eligible.match_type, v_eligible.id, v_new_count, v_is_perm);
    ELSE
      IF v_hist.is_permanent THEN NULL;
      ELSE
        v_new_count := COALESCE(v_hist.expiry_count, 0) + 1;
        v_is_perm := v_new_count >= v_max_occ;
        UPDATE public.unmatched_pairs SET expiry_count = v_new_count, is_permanent = v_is_perm, created_at = GREATEST(unmatched_pairs.created_at, now()), match_type = COALESCE(unmatched_pairs.match_type, v_eligible.match_type), match_id = COALESCE(unmatched_pairs.match_id, v_eligible.id) WHERE user1_id = v_a AND user2_id = v_b;
      END IF;
    END IF;
    DELETE FROM public.chats c WHERE c.match_id = v_eligible.id;
    DELETE FROM public.user_recent_matches urm WHERE urm.match_id = v_eligible.id;
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='user_recent_chats') THEN
      EXECUTE 'DELETE FROM public.user_recent_chats WHERE match_id = $1' USING v_eligible.id;
    END IF;
    DELETE FROM public.chat_messages cm WHERE cm.match_id = v_eligible.id;
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='match_chat_extensions') THEN
      EXECUTE 'DELETE FROM public.match_chat_extensions WHERE match_id = $1' USING v_eligible.id;
    END IF;
    DELETE FROM public.matches m WHERE m.id = v_eligible.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN COALESCE(v_count, 0);
END;
$$;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_matches(timestamptz, int) TO service_role;

-- 3) Rewrite perform_continuous_user_matching to use configurable max
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
                INSERT INTO matches (user1_id, user2_id, matched_intent, match_type, created_at, match_occurrence) VALUES (v_a, v_b, matched_intent_result, 'proximity', NOW(), v_next_occurrence);
                total_matches_created := total_matches_created + 1;
            END IF;
        END LOOP;
    END LOOP;
    RETURN QUERY SELECT total_users_processed, total_matches_created, 'completed'::TEXT;
END;
$_$;
GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO anon;

-- 4) Rewrite perform_event_matching similarly
DROP FUNCTION IF EXISTS public.perform_event_matching(uuid);
CREATE OR REPLACE FUNCTION public.perform_event_matching(p_event_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $_$
DECLARE
    event_attendee RECORD;
    other_attendee RECORD;
    attendee_a_id uuid;
    attendee_b_id uuid;
    existing_match_id uuid;
    shared_intents TEXT[];
    has_matching_sub_intent BOOLEAN := FALSE;
    shared_intent TEXT;
    pair_allowed BOOLEAN := FALSE;
    a_has_compliant BOOLEAN; b_has_compliant BOOLEAN; has_shared_interest BOOLEAN := FALSE; shared_interest_category TEXT;
    a_gender TEXT; a_dob DATE; a_age INTEGER; a_enabled BOOLEAN; a_active TEXT[]; a_interests JSONB; a_lifestyle JSONB; a_family JSONB; a_religion JSONB; a_height INTEGER; a_prefs JSONB;
    b_gender TEXT; b_dob DATE; b_age INTEGER; b_enabled BOOLEAN; b_active TEXT[]; b_interests JSONB; b_lifestyle JSONB; b_family JSONB; b_religion JSONB; b_height INTEGER; b_prefs JSONB;
    a_sub JSONB; b_sub JSONB; filters_compatible BOOLEAN; a_gender_ok BOOLEAN; a_age_ok BOOLEAN; b_gender_ok BOOLEAN; b_age_ok BOOLEAN;
    v_a uuid; v_b uuid; v_hist RECORD; v_next_occurrence int; v_max_occ int;
BEGIN
    v_max_occ := public._get_max_match_occurrence();
    SET search_path = 'public';
    FOR event_attendee IN SELECT DISTINCT ea.user_id FROM event_attendees ea WHERE ea.event_id = p_event_id LOOP
        attendee_a_id := event_attendee.user_id;
        SELECT gender, date_of_birth, shared_event_matching_enabled INTO a_gender, a_dob, a_enabled FROM users WHERE id = attendee_a_id;
        IF a_enabled IS NULL OR NOT a_enabled THEN CONTINUE; END IF;
        IF a_dob IS NOT NULL THEN a_age := EXTRACT(YEAR FROM AGE(a_dob)); ELSE a_age := NULL; END IF;
        SELECT lifestyle, family, religion, height, ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)), public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb)), intent_preferences
        INTO a_lifestyle, a_family, a_religion, a_height, a_active, a_interests, a_prefs FROM user_profiles WHERE user_id = attendee_a_id;
        IF a_active IS NULL OR array_length(a_active,1) IS NULL THEN CONTINUE; END IF; a_interests := COALESCE(a_interests, '{}'::jsonb);
        FOR other_attendee IN SELECT DISTINCT ea2.user_id FROM event_attendees ea2 WHERE ea2.event_id = p_event_id AND ea2.user_id != attendee_a_id LOOP
            attendee_b_id := other_attendee.user_id; IF attendee_a_id >= attendee_b_id THEN CONTINUE; END IF;
            v_a := LEAST(attendee_a_id, attendee_b_id); v_b := GREATEST(attendee_a_id, attendee_b_id);
            SELECT expiry_count, is_permanent INTO v_hist FROM public.unmatched_pairs WHERE user1_id = v_a AND user2_id = v_b;
            IF FOUND AND COALESCE(v_hist.is_permanent,false)=true THEN CONTINUE; END IF;
            IF FOUND AND COALESCE(v_hist.expiry_count,0) >= v_max_occ THEN CONTINUE; END IF;
            v_next_occurrence := COALESCE(v_hist.expiry_count,0)+1; IF v_next_occurrence > v_max_occ THEN CONTINUE; END IF;
            IF EXISTS (SELECT 1 FROM public.unmatched_pairs up WHERE up.user1_id = attendee_a_id AND up.user2_id = attendee_b_id AND COALESCE(up.is_permanent,false)=true) THEN CONTINUE; END IF;
            IF EXISTS (SELECT 1 FROM public.unmatched_pairs up WHERE up.user1_id = attendee_b_id AND up.user2_id = attendee_a_id AND COALESCE(up.is_permanent,false)=true) THEN CONTINUE; END IF;
            SELECT id INTO existing_match_id FROM matches WHERE (user1_id = attendee_a_id AND user2_id = attendee_b_id) OR (user1_id = attendee_b_id AND user2_id = attendee_a_id) LIMIT 1;
            IF existing_match_id IS NOT NULL THEN CONTINUE; END IF;
            SELECT gender, date_of_birth, shared_event_matching_enabled INTO b_gender, b_dob, b_enabled FROM users WHERE id = attendee_b_id;
            IF b_enabled IS NULL OR NOT b_enabled THEN CONTINUE; END IF;
            IF b_dob IS NOT NULL THEN b_age := EXTRACT(YEAR FROM AGE(b_dob)); ELSE b_age := NULL; END IF;
            SELECT lifestyle, family, religion, height, ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)), public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb)), intent_preferences
            INTO b_lifestyle, b_family, b_religion, b_height, b_active, b_interests, b_prefs FROM user_profiles WHERE user_id = attendee_b_id;
            IF b_active IS NULL OR array_length(b_active,1) IS NULL THEN CONTINUE; END IF; b_interests := COALESCE(b_interests, '{}'::jsonb);
            SELECT ARRAY(SELECT intent FROM unnest(a_active) AS t(intent) WHERE intent = ANY(b_active)) INTO shared_intents;
            IF shared_intents IS NULL OR array_length(shared_intents,1) IS NULL THEN CONTINUE; END IF;
            has_matching_sub_intent := FALSE;
            <<sub_intent_loop>> FOREACH shared_intent IN ARRAY shared_intents LOOP
                a_sub := COALESCE((SELECT up.sub_intents -> shared_intent FROM user_profiles up WHERE up.user_id = attendee_a_id), '[]'::jsonb);
                b_sub := COALESCE((SELECT up.sub_intents -> shared_intent FROM user_profiles up WHERE up.user_id = attendee_b_id), '[]'::jsonb);
                IF jsonb_array_length(a_sub)=0 OR jsonb_array_length(b_sub)=0 THEN has_matching_sub_intent:=TRUE; EXIT sub_intent_loop; END IF;
                IF (SELECT count(*) FROM jsonb_array_elements_text(a_sub) va WHERE va IN (SELECT jsonb_array_elements_text(b_sub))) >0 THEN has_matching_sub_intent:=TRUE; EXIT sub_intent_loop; END IF;
            END LOOP sub_intent_loop;
            IF NOT has_matching_sub_intent THEN CONTINUE; END IF;
            pair_allowed := FALSE;
            <<intent_enforcement_loop>> FOREACH shared_intent IN ARRAY shared_intents LOOP
                a_gender_ok := (NOT ((b_prefs -> 'gender_preferences') ? shared_intent) OR ((b_prefs -> 'gender_preferences') -> shared_intent) ? a_gender);
                a_age_ok := (NOT ((b_prefs -> 'age_preferences') ? shared_intent) OR a_age IS NULL OR (jsonb_array_length((b_prefs -> 'age_preferences') -> shared_intent) >=2 AND a_age >= ((b_prefs -> 'age_preferences') -> shared_intent ->> 0)::numeric AND a_age <= ((b_prefs -> 'age_preferences') -> shared_intent ->> 1)::numeric));
                b_gender_ok := (NOT ((a_prefs -> 'gender_preferences') ? shared_intent) OR ((a_prefs -> 'gender_preferences') -> shared_intent) ? b_gender);
                b_age_ok := (NOT ((a_prefs -> 'age_preferences') ? shared_intent) OR b_age IS NULL OR (jsonb_array_length((a_prefs -> 'age_preferences') -> shared_intent) >=2 AND b_age >= ((a_prefs -> 'age_preferences') -> shared_intent ->> 0)::numeric AND b_age <= ((a_prefs -> 'age_preferences') -> shared_intent ->> 1)::numeric));
                filters_compatible := public.are_filters_compatible(a_lifestyle, a_family, a_religion, a_height, b_lifestyle, b_family, b_religion, b_height, (b_prefs -> 'lifestyle_filters'), (b_prefs -> 'family_filters'), (b_prefs -> 'religion_filters'), (b_prefs -> 'height_preferences'), (a_prefs -> 'lifestyle_filters'), (a_prefs -> 'family_filters'), (a_prefs -> 'religion_filters'), (a_prefs -> 'height_preferences'), shared_intent);
                IF a_gender_ok AND a_age_ok AND b_gender_ok AND b_age_ok AND filters_compatible THEN pair_allowed:=TRUE; EXIT intent_enforcement_loop; END IF;
                SELECT EXISTS (SELECT 1 FROM event_attendees ea INNER JOIN users u2 ON u2.id = ea.user_id WHERE ea.event_id = p_event_id AND ea.user_id <> attendee_b_id AND ea.user_id <> attendee_a_id AND public.is_compliant_candidate((a_prefs -> 'gender_preferences'), (a_prefs -> 'age_preferences'), u2.gender, u2.date_of_birth, shared_intent)) INTO a_has_compliant;
                SELECT EXISTS (SELECT 1 FROM event_attendees ea INNER JOIN users u2 ON u2.id = ea.user_id WHERE ea.event_id = p_event_id AND ea.user_id <> attendee_a_id AND ea.user_id <> attendee_b_id AND public.is_compliant_candidate((b_prefs -> 'gender_preferences'), (b_prefs -> 'age_preferences'), u2.gender, u2.date_of_birth, shared_intent)) INTO b_has_compliant;
                IF NOT a_has_compliant AND NOT b_has_compliant THEN pair_allowed:=TRUE; EXIT intent_enforcement_loop; END IF;
            END LOOP intent_enforcement_loop;
            IF NOT pair_allowed THEN CONTINUE; END IF;
            has_shared_interest := FALSE;
            FOR shared_interest_category IN SELECT jsonb_object_keys(a_interests) LOOP
                IF a_interests ? shared_interest_category AND b_interests ? shared_interest_category THEN
                    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(a_interests -> shared_interest_category) AS ia WHERE ia = ANY(SELECT jsonb_array_elements_text(b_interests -> shared_interest_category))) THEN has_shared_interest:=TRUE; EXIT; END IF;
                END IF;
            END LOOP;
            IF NOT has_shared_interest THEN CONTINUE; END IF;
            INSERT INTO matches (user1_id, user2_id, match_type, matched_intent, event_id, created_at, match_occurrence) VALUES (attendee_a_id, attendee_b_id, 'event', shared_intents[1], p_event_id, NOW(), v_next_occurrence);
        END LOOP;
    END LOOP;
END;
$_$;
GRANT EXECUTE ON FUNCTION public.perform_event_matching(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_event_matching(uuid) TO anon;

-- 5) Fix existing inconsistent data: dd6d20a5 <-> ffc20046 should have expiry_count=1 and rematch occurrence=2
-- The row in matches 1d7074ac (2026-09-02 17:41) was created after unmatched 17:24 but got occurrence 1 due to expiry_count 0 bug.
-- Correct both:
UPDATE public.unmatched_pairs
SET expiry_count = 1, is_permanent = false
WHERE user1_id = 'dd6d20a5-cd79-4761-8a74-751acb555b4d' AND user2_id = 'ffc20046-a777-463b-922a-547151aa1455'
  AND expiry_count = 0;

UPDATE public.matches
SET match_occurrence = 2
WHERE id = '1d7074ac-868d-45ea-a452-40b59fe49528' AND match_occurrence = 1
  AND EXISTS (SELECT 1 FROM public.unmatched_pairs WHERE user1_id='dd6d20a5-cd79-4761-8a74-751acb555b4d' AND user2_id='ffc20046-a777-463b-922a-547151aa1455' AND expiry_count >=1);

COMMIT;
