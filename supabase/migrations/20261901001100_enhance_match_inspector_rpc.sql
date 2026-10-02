-- Migration: Enhance Match Inspector RPC with Proximity, Distance, Visibility, and Granular Criteria
-- Purpose: Complete Match Inspector data model for admin clarity + fix _filter_values helper
BEGIN;

------------------------------------------------------------------------------
-- 1) Fix _filter_values helper function (alias jsonb_array_elements_text correctly)
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._filter_values(p_filters JSONB, p_key TEXT)
RETURNS TEXT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_raw JSONB;
    v_val TEXT;
BEGIN
    v_raw := p_filters -> p_key;

    -- Not present at all → no filter
    IF v_raw IS NULL THEN
        RETURN NULL;
    END IF;

    -- Array format
    IF jsonb_typeof(v_raw) = 'array' THEN
        IF jsonb_array_length(v_raw) = 0 THEN
            RETURN NULL;
        END IF;
        -- If the only element is 'any', treat as no filter
        IF jsonb_array_length(v_raw) = 1 AND (v_raw ->> 0) = 'any' THEN
            RETURN NULL;
        END IF;
        RETURN ARRAY(SELECT t.val FROM jsonb_array_elements_text(v_raw) AS t(val) WHERE t.val <> 'any');
    END IF;

    -- Single string format (backward compat)
    v_val := p_filters ->> p_key;
    IF v_val IS NULL OR v_val = 'any' THEN
        RETURN NULL;
    END IF;
    RETURN ARRAY[v_val];
END;
$$;

GRANT EXECUTE ON FUNCTION public._filter_values(JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public._filter_values(JSONB, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public._filter_values(JSONB, TEXT) TO service_role;

------------------------------------------------------------------------------
-- 2) Match Inspector admin_compare_users RPC
------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_compare_users(uuid, uuid);
CREATE OR REPLACE FUNCTION public.admin_compare_users(
  p_user_a uuid,
  p_user_b uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;

  -- User A fields
  a_exists boolean := false;
  a_name text := '';
  a_email text := '';
  a_gender text;
  a_dob date;
  a_age integer;
  a_lifestyle jsonb := '{}'::jsonb;
  a_family jsonb := '{}'::jsonb;
  a_religion jsonb := '{}'::jsonb;
  a_height integer;
  a_active jsonb := '[]'::jsonb;
  a_active_arr text[] := ARRAY[]::text[];
  a_sub_intents jsonb := '{}'::jsonb;
  a_personal jsonb := '{}'::jsonb;
  a_business jsonb := '{}'::jsonb;
  a_merged_interests jsonb := '{}'::jsonb;
  a_prefs jsonb := '{}'::jsonb;
  a_photos jsonb := '[]'::jsonb;
  a_radius integer := 10000;
  a_vis_user boolean := true;
  a_vis_sys text := 'visible';
  a_lat double precision;
  a_lng double precision;
  a_loc_updated timestamptz;
  a_online boolean := false;
  a_last_active timestamptz;

  -- User B fields
  b_exists boolean := false;
  b_name text := '';
  b_email text := '';
  b_gender text;
  b_dob date;
  b_age integer;
  b_lifestyle jsonb := '{}'::jsonb;
  b_family jsonb := '{}'::jsonb;
  b_religion jsonb := '{}'::jsonb;
  b_height integer;
  b_active jsonb := '[]'::jsonb;
  b_active_arr text[] := ARRAY[]::text[];
  b_sub_intents jsonb := '{}'::jsonb;
  b_personal jsonb := '{}'::jsonb;
  b_business jsonb := '{}'::jsonb;
  b_merged_interests jsonb := '{}'::jsonb;
  b_prefs jsonb := '{}'::jsonb;
  b_photos jsonb := '[]'::jsonb;
  b_radius integer := 10000;
  b_vis_user boolean := true;
  b_vis_sys text := 'visible';
  b_lat double precision;
  b_lng double precision;
  b_loc_updated timestamptz;
  b_online boolean := false;
  b_last_active timestamptz;

  -- Environmental & Proximity
  v_distance_km double precision := NULL;
  v_a_radius_km double precision := 10.0;
  v_b_radius_km double precision := 10.0;
  v_a_in_b_radius boolean := NULL;
  v_b_in_a_radius boolean := NULL;
  v_proximity_pass boolean := true;
  earth_km CONSTANT double precision := 6371.0;
  v_cos_val double precision;

  -- Shared intents & Match History
  shared_intents text[];
  v_already_matched boolean := false;
  v_matched_intent text;
  v_match_type text;
  v_matched_at timestamptz;
  v_unmatched boolean := false;
  v_unmatched_at timestamptz;

  -- Per-intent breakdown
  per_intent jsonb := '[]'::jsonb;
  compatible_intents text[] := ARRAY[]::text[];
  all_blockers jsonb := '[]'::jsonb;
  compat boolean := false;

  -- Loop variables
  shared_intent text;
  a_sub_arr text[];
  b_sub_arr text[];
  a_sub_json jsonb;
  b_sub_json jsonb;
  overlap_sub text[];
  sub_pass boolean;
  sub_unrestricted boolean;

  -- Gender/Age
  a_gender_ok boolean;
  b_gender_ok boolean;
  gender_pass boolean;
  a_age_ok boolean;
  b_age_ok boolean;
  age_pass boolean;
  a_gender_prefs jsonb;
  b_gender_prefs jsonb;
  a_age_prefs jsonb;
  b_age_prefs jsonb;

  -- Granular Lifestyle
  a_lifestyle_filter jsonb;
  b_lifestyle_filter jsonb;
  smoke_a_val text; smoke_b_val text; smoke_a_ok boolean; smoke_b_ok boolean; smoke_pass boolean;
  drink_a_val text; drink_b_val text; drink_a_ok boolean; drink_b_ok boolean; drink_pass boolean;
  diet_a_val text; diet_b_val text; diet_a_ok boolean; diet_b_ok boolean; diet_pass boolean;
  ex_a_val text; ex_b_val text; ex_a_ok boolean; ex_b_ok boolean; ex_pass boolean;
  lifestyle_pass boolean; lifestyle_a_pass boolean; lifestyle_b_pass boolean;

  -- Granular Family
  a_family_filter jsonb;
  b_family_filter jsonb;
  has_child_a_val text; has_child_b_val text; has_child_a_ok boolean; has_child_b_ok boolean; has_child_pass boolean;
  wants_child_a_val text; wants_child_b_val text; wants_child_a_ok boolean; wants_child_b_ok boolean; wants_child_pass boolean;
  family_pass boolean; family_a_pass boolean; family_b_pass boolean;

  -- Granular Religion & Height
  a_religion_filter jsonb; b_religion_filter jsonb;
  relig_a_val text; relig_b_val text; relig_a_ok boolean; relig_b_ok boolean; relig_pass boolean;
  religion_pass boolean; religion_a_pass boolean; religion_b_pass boolean;

  a_height_filter jsonb; b_height_filter jsonb;
  height_a_ok boolean; height_b_ok boolean; height_pass boolean;
  filters_pass boolean;

  -- Domain-specific interests
  interest_pass boolean;
  overlap_cats text[];
  domain_interest_a jsonb;
  domain_interest_b jsonb;
  domain_type text;

  intent_all_pass boolean;
  intent_blockers text[];
  entry jsonb;
BEGIN
  -- Admin check
  SELECT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) INTO v_is_admin;
  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_user_a IS NULL OR p_user_b IS NULL THEN
    RAISE EXCEPTION 'both user ids are required';
  END IF;
  IF p_user_a = p_user_b THEN
    RAISE EXCEPTION 'select two different users';
  END IF;

  -- Load User A core profile
  SELECT
    COALESCE(u.name, ''),
    u.gender,
    u.date_of_birth,
    COALESCE(up.lifestyle, '{}'::jsonb),
    COALESCE(up.family, '{}'::jsonb),
    COALESCE(up.religion, '{}'::jsonb),
    up.height,
    COALESCE(up.active_modes, '[]'::jsonb),
    COALESCE(up.sub_intents, '{}'::jsonb),
    COALESCE(up.personal_interests, '{}'::jsonb),
    COALESCE(up.business_interests, '{}'::jsonb),
    COALESCE(up.intent_preferences, '{}'::jsonb),
    COALESCE(up.photos, '[]'::jsonb)
  INTO
    a_name, a_gender, a_dob,
    a_lifestyle, a_family, a_religion, a_height,
    a_active, a_sub_intents, a_personal, a_business, a_prefs, a_photos
  FROM public.users u
  LEFT JOIN public.user_profiles up ON up.user_id = u.id
  WHERE u.id = p_user_a;

  IF a_name IS NOT NULL OR EXISTS (SELECT 1 FROM public.users WHERE id = p_user_a) THEN
    a_exists := true;
  END IF;

  -- Load User A optional settings defensively
  BEGIN
    SELECT
      COALESCE(u.match_radius_default, 10000),
      COALESCE(u.user_visibility_setting, true),
      COALESCE(u.system_visibility_status, 'visible')
    INTO a_radius, a_vis_user, a_vis_sys
    FROM public.users u WHERE u.id = p_user_a;
  EXCEPTION WHEN OTHERS THEN
    a_radius := 10000; a_vis_user := true; a_vis_sys := 'visible';
  END;

  -- Load User A location & online status
  BEGIN
    SELECT ul.latitude, ul.longitude, ul.updated_at INTO a_lat, a_lng, a_loc_updated
    FROM public.user_locations ul WHERE ul.user_id = p_user_a LIMIT 1;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    SELECT ua.is_online, ua.last_active_at INTO a_online, a_last_active
    FROM public.user_activity ua WHERE ua.user_id = p_user_a LIMIT 1;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- Load User B core profile
  SELECT
    COALESCE(u.name, ''),
    u.gender,
    u.date_of_birth,
    COALESCE(up.lifestyle, '{}'::jsonb),
    COALESCE(up.family, '{}'::jsonb),
    COALESCE(up.religion, '{}'::jsonb),
    up.height,
    COALESCE(up.active_modes, '[]'::jsonb),
    COALESCE(up.sub_intents, '{}'::jsonb),
    COALESCE(up.personal_interests, '{}'::jsonb),
    COALESCE(up.business_interests, '{}'::jsonb),
    COALESCE(up.intent_preferences, '{}'::jsonb),
    COALESCE(up.photos, '[]'::jsonb)
  INTO
    b_name, b_gender, b_dob,
    b_lifestyle, b_family, b_religion, b_height,
    b_active, b_sub_intents, b_personal, b_business, b_prefs, b_photos
  FROM public.users u
  LEFT JOIN public.user_profiles up ON up.user_id = u.id
  WHERE u.id = p_user_b;

  IF b_name IS NOT NULL OR EXISTS (SELECT 1 FROM public.users WHERE id = p_user_b) THEN
    b_exists := true;
  END IF;

  IF NOT a_exists OR NOT b_exists THEN
    RETURN jsonb_build_object(
      'error', 'user_not_found',
      'user_a_exists', a_exists,
      'user_b_exists', b_exists
    );
  END IF;

  -- Load User B optional settings defensively
  BEGIN
    SELECT
      COALESCE(u.match_radius_default, 10000),
      COALESCE(u.user_visibility_setting, true),
      COALESCE(u.system_visibility_status, 'visible')
    INTO b_radius, b_vis_user, b_vis_sys
    FROM public.users u WHERE u.id = p_user_b;
  EXCEPTION WHEN OTHERS THEN
    b_radius := 10000; b_vis_user := true; b_vis_sys := 'visible';
  END;

  -- Load User B location & online status
  BEGIN
    SELECT ul.latitude, ul.longitude, ul.updated_at INTO b_lat, b_lng, b_loc_updated
    FROM public.user_locations ul WHERE ul.user_id = p_user_b LIMIT 1;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    SELECT ua.is_online, ua.last_active_at INTO b_online, b_last_active
    FROM public.user_activity ua WHERE ua.user_id = p_user_b LIMIT 1;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- Compute Ages
  IF a_dob IS NOT NULL THEN a_age := EXTRACT(YEAR FROM AGE(a_dob)); END IF;
  IF b_dob IS NOT NULL THEN b_age := EXTRACT(YEAR FROM AGE(b_dob)); END IF;

  -- Active modes arrays (safe table alias with column alias)
  IF a_active IS NULL THEN a_active := '[]'::jsonb; END IF;
  IF b_active IS NULL THEN b_active := '[]'::jsonb; END IF;
  BEGIN
    SELECT ARRAY(SELECT t.val FROM jsonb_array_elements_text(a_active) AS t(val)) INTO a_active_arr;
  EXCEPTION WHEN OTHERS THEN a_active_arr := ARRAY[]::text[];
  END;
  BEGIN
    SELECT ARRAY(SELECT t.val FROM jsonb_array_elements_text(b_active) AS t(val)) INTO b_active_arr;
  EXCEPTION WHEN OTHERS THEN b_active_arr := ARRAY[]::text[];
  END;
  IF a_active_arr IS NULL THEN a_active_arr := ARRAY[]::text[]; END IF;
  IF b_active_arr IS NULL THEN b_active_arr := ARRAY[]::text[]; END IF;

  IF a_sub_intents IS NULL THEN a_sub_intents := '{}'::jsonb; END IF;
  IF b_sub_intents IS NULL THEN b_sub_intents := '{}'::jsonb; END IF;
  IF a_prefs IS NULL THEN a_prefs := '{}'::jsonb; END IF;
  IF b_prefs IS NULL THEN b_prefs := '{}'::jsonb; END IF;

  -- Merged interests (defensive merge)
  BEGIN
    a_merged_interests := public.merge_interest_maps(a_personal, a_business);
    b_merged_interests := public.merge_interest_maps(b_personal, b_business);
  EXCEPTION WHEN OTHERS THEN
    a_merged_interests := a_personal;
    b_merged_interests := b_personal;
  END;
  IF a_merged_interests IS NULL THEN a_merged_interests := '{}'::jsonb; END IF;
  IF b_merged_interests IS NULL THEN b_merged_interests := '{}'::jsonb; END IF;

  -- Compute Distance & Radius Checks
  v_a_radius_km := (COALESCE(a_radius, 10000) / 1000.0)::double precision;
  v_b_radius_km := (COALESCE(b_radius, 10000) / 1000.0)::double precision;

  IF a_lat IS NOT NULL AND a_lng IS NOT NULL AND b_lat IS NOT NULL AND b_lng IS NOT NULL THEN
    v_cos_val := LEAST(1.0, GREATEST(-1.0, (
      cos(radians(a_lat)) * cos(radians(b_lat)) * cos(radians(b_lng) - radians(a_lng))
      + sin(radians(a_lat)) * sin(radians(b_lat))
    )));
    v_distance_km := ROUND((earth_km * acos(v_cos_val))::numeric, 2)::double precision;
    v_b_in_a_radius := (v_distance_km <= v_a_radius_km);
    v_a_in_b_radius := (v_distance_km <= v_b_radius_km);
    v_proximity_pass := v_b_in_a_radius AND v_a_in_b_radius;
  END IF;

  -- Shared intents
  SELECT ARRAY(SELECT unnest(a_active_arr) INTERSECT SELECT unnest(b_active_arr)) INTO shared_intents;
  IF shared_intents IS NULL THEN shared_intents := ARRAY[]::text[]; END IF;

  -- Already matched?
  BEGIN
    SELECT m.matched_intent, m.match_type, m.created_at INTO v_matched_intent, v_match_type, v_matched_at
    FROM public.matches m
    WHERE (m.user1_id = p_user_a AND m.user2_id = p_user_b)
       OR (m.user1_id = p_user_b AND m.user2_id = p_user_a)
    LIMIT 1;
    IF FOUND THEN v_already_matched := true; END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- Unmatched pair?
  BEGIN
    SELECT up2.created_at INTO v_unmatched_at
    FROM public.unmatched_pairs up2
    WHERE (up2.user1_id = p_user_a AND up2.user2_id = p_user_b)
       OR (up2.user1_id = p_user_b AND up2.user2_id = p_user_a)
    LIMIT 1;
    IF FOUND THEN v_unmatched := true; END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- Check Per-Intent Criteria
  IF array_length(shared_intents, 1) IS NOT NULL AND array_length(shared_intents, 1) > 0 THEN
    FOREACH shared_intent IN ARRAY shared_intents LOOP
      intent_blockers := ARRAY[]::text[];

      -- 1. Sub-Intents
      a_sub_json := COALESCE(a_sub_intents -> shared_intent, '[]'::jsonb);
      b_sub_json := COALESCE(b_sub_intents -> shared_intent, '[]'::jsonb);
      BEGIN
        SELECT ARRAY(SELECT t.val FROM jsonb_array_elements_text(a_sub_json) AS t(val)) INTO a_sub_arr;
      EXCEPTION WHEN OTHERS THEN a_sub_arr := ARRAY[]::text[];
      END;
      BEGIN
        SELECT ARRAY(SELECT t.val FROM jsonb_array_elements_text(b_sub_json) AS t(val)) INTO b_sub_arr;
      EXCEPTION WHEN OTHERS THEN b_sub_arr := ARRAY[]::text[];
      END;
      IF a_sub_arr IS NULL THEN a_sub_arr := ARRAY[]::text[]; END IF;
      IF b_sub_arr IS NULL THEN b_sub_arr := ARRAY[]::text[]; END IF;

      IF array_length(a_sub_arr, 1) IS NULL OR array_length(b_sub_arr, 1) IS NULL THEN
        sub_unrestricted := true;
        overlap_sub := ARRAY[]::text[];
        sub_pass := true;
      ELSE
        sub_unrestricted := false;
        SELECT ARRAY(SELECT unnest(a_sub_arr) INTERSECT SELECT unnest(b_sub_arr)) INTO overlap_sub;
        IF overlap_sub IS NULL THEN overlap_sub := ARRAY[]::text[]; END IF;
        sub_pass := (array_length(overlap_sub, 1) IS NOT NULL AND array_length(overlap_sub, 1) > 0);
      END IF;

      IF NOT sub_pass THEN
        intent_blockers := array_append(intent_blockers, 'sub_intents');
      END IF;

      -- 2. Gender Preferences
      a_gender_prefs := COALESCE(a_prefs -> 'gender_preferences', '{}'::jsonb);
      b_gender_prefs := COALESCE(b_prefs -> 'gender_preferences', '{}'::jsonb);
      IF NOT (b_gender_prefs ? shared_intent) THEN
        a_gender_ok := true;
      ELSE
        a_gender_ok := (b_gender_prefs -> shared_intent) ? COALESCE(a_gender, '');
      END IF;
      IF NOT (a_gender_prefs ? shared_intent) THEN
        b_gender_ok := true;
      ELSE
        b_gender_ok := (a_gender_prefs -> shared_intent) ? COALESCE(b_gender, '');
      END IF;
      gender_pass := a_gender_ok AND b_gender_ok;
      IF NOT gender_pass THEN
        intent_blockers := array_append(intent_blockers, 'gender');
      END IF;

      -- 3. Age Preferences
      a_age_prefs := COALESCE(a_prefs -> 'age_preferences', '{}'::jsonb);
      b_age_prefs := COALESCE(b_prefs -> 'age_preferences', '{}'::jsonb);
      IF NOT (b_age_prefs ? shared_intent) THEN
        a_age_ok := true;
      ELSIF a_age IS NULL THEN
        a_age_ok := true;
      ELSE
        BEGIN
          IF jsonb_array_length(b_age_prefs -> shared_intent) >= 2
             AND a_age >= (b_age_prefs -> shared_intent ->> 0)::numeric
             AND a_age <= (b_age_prefs -> shared_intent ->> 1)::numeric THEN
            a_age_ok := true;
          ELSE
            a_age_ok := false;
          END IF;
        EXCEPTION WHEN OTHERS THEN a_age_ok := false; END;
      END IF;

      IF NOT (a_age_prefs ? shared_intent) THEN
        b_age_ok := true;
      ELSIF b_age IS NULL THEN
        b_age_ok := true;
      ELSE
        BEGIN
          IF jsonb_array_length(a_age_prefs -> shared_intent) >= 2
             AND b_age >= (a_age_prefs -> shared_intent ->> 0)::numeric
             AND b_age <= (a_age_prefs -> shared_intent ->> 1)::numeric THEN
            b_age_ok := true;
          ELSE
            b_age_ok := false;
          END IF;
        EXCEPTION WHEN OTHERS THEN b_age_ok := false; END;
      END IF;
      age_pass := a_age_ok AND b_age_ok;
      IF NOT age_pass THEN
        intent_blockers := array_append(intent_blockers, 'age');
      END IF;

      -- 4. Granular Lifestyle Filters
      a_lifestyle_filter := COALESCE((a_prefs -> 'lifestyle_filters' -> shared_intent), '{}'::jsonb);
      b_lifestyle_filter := COALESCE((b_prefs -> 'lifestyle_filters' -> shared_intent), '{}'::jsonb);

      -- Smoking
      smoke_a_val := a_lifestyle ->> 'smoking';
      smoke_b_val := b_lifestyle ->> 'smoking';
      smoke_a_ok := public.check_preference_filter(jsonb_build_object('smoking', b_lifestyle_filter -> 'smoking'), a_lifestyle, a_height, 'lifestyle');
      smoke_b_ok := public.check_preference_filter(jsonb_build_object('smoking', a_lifestyle_filter -> 'smoking'), b_lifestyle, b_height, 'lifestyle');
      smoke_pass := smoke_a_ok AND smoke_b_ok;

      -- Drinking
      drink_a_val := a_lifestyle ->> 'drinking';
      drink_b_val := b_lifestyle ->> 'drinking';
      drink_a_ok := public.check_preference_filter(jsonb_build_object('drinking', b_lifestyle_filter -> 'drinking'), a_lifestyle, a_height, 'lifestyle');
      drink_b_ok := public.check_preference_filter(jsonb_build_object('drinking', a_lifestyle_filter -> 'drinking'), b_lifestyle, b_height, 'lifestyle');
      drink_pass := drink_a_ok AND drink_b_ok;

      -- Diet
      diet_a_val := a_lifestyle ->> 'diet';
      diet_b_val := b_lifestyle ->> 'diet';
      diet_a_ok := public.check_preference_filter(jsonb_build_object('diets', b_lifestyle_filter -> 'diets'), a_lifestyle, a_height, 'lifestyle');
      diet_b_ok := public.check_preference_filter(jsonb_build_object('diets', a_lifestyle_filter -> 'diets'), b_lifestyle, b_height, 'lifestyle');
      diet_pass := diet_a_ok AND diet_b_ok;

      -- Exercise
      ex_a_val := a_lifestyle ->> 'exercise';
      ex_b_val := b_lifestyle ->> 'exercise';
      ex_a_ok := public.check_preference_filter(jsonb_build_object('exercise', b_lifestyle_filter -> 'exercise'), a_lifestyle, a_height, 'lifestyle');
      ex_b_ok := public.check_preference_filter(jsonb_build_object('exercise', a_lifestyle_filter -> 'exercise'), b_lifestyle, b_height, 'lifestyle');
      ex_pass := ex_a_ok AND ex_b_ok;

      lifestyle_a_pass := smoke_a_ok AND drink_a_ok AND diet_a_ok AND ex_a_ok;
      lifestyle_b_pass := smoke_b_ok AND drink_b_ok AND diet_b_ok AND ex_b_ok;
      lifestyle_pass := lifestyle_a_pass AND lifestyle_b_pass;
      IF NOT lifestyle_pass THEN
        intent_blockers := array_append(intent_blockers, 'lifestyle');
      END IF;

      -- 5. Granular Family Filters
      a_family_filter := COALESCE((a_prefs -> 'family_filters' -> shared_intent), '{}'::jsonb);
      b_family_filter := COALESCE((b_prefs -> 'family_filters' -> shared_intent), '{}'::jsonb);

      has_child_a_val := a_family ->> 'has_children';
      has_child_b_val := b_family ->> 'has_children';
      has_child_a_ok := public.check_preference_filter(jsonb_build_object('has_children', b_family_filter -> 'has_children'), a_family, a_height, 'family');
      has_child_b_ok := public.check_preference_filter(jsonb_build_object('has_children', a_family_filter -> 'has_children'), b_family, b_height, 'family');
      has_child_pass := has_child_a_ok AND has_child_b_ok;

      wants_child_a_val := a_family ->> 'wants_children';
      wants_child_b_val := b_family ->> 'wants_children';
      wants_child_a_ok := public.check_preference_filter(jsonb_build_object('wants_children', b_family_filter -> 'wants_children'), a_family, a_height, 'family');
      wants_child_b_ok := public.check_preference_filter(jsonb_build_object('wants_children', a_family_filter -> 'wants_children'), b_family, b_height, 'family');
      wants_child_pass := wants_child_a_ok AND wants_child_b_ok;

      family_a_pass := has_child_a_ok AND wants_child_a_ok;
      family_b_pass := has_child_b_ok AND wants_child_b_ok;
      family_pass := family_a_pass AND family_b_pass;
      IF NOT family_pass THEN
        intent_blockers := array_append(intent_blockers, 'family');
      END IF;

      -- 6. Granular Religion Filters
      a_religion_filter := COALESCE((a_prefs -> 'religion_filters' -> shared_intent), '{}'::jsonb);
      b_religion_filter := COALESCE((b_prefs -> 'religion_filters' -> shared_intent), '{}'::jsonb);

      relig_a_val := a_religion ->> 'religion';
      relig_b_val := b_religion ->> 'religion';
      relig_a_ok := public.check_preference_filter(b_religion_filter, a_religion, a_height, 'religion');
      relig_b_ok := public.check_preference_filter(a_religion_filter, b_religion, b_height, 'religion');
      religion_a_pass := relig_a_ok;
      religion_b_pass := relig_b_ok;
      religion_pass := religion_a_pass AND religion_b_pass;
      IF NOT religion_pass THEN
        intent_blockers := array_append(intent_blockers, 'religion');
      END IF;

      -- 7. Granular Height Preferences
      a_height_filter := COALESCE((a_prefs -> 'height_preferences' -> shared_intent), '{}'::jsonb);
      b_height_filter := COALESCE((b_prefs -> 'height_preferences' -> shared_intent), '{}'::jsonb);
      height_a_ok := public.check_preference_filter(b_height_filter, NULL, a_height, 'height');
      height_b_ok := public.check_preference_filter(a_height_filter, NULL, b_height, 'height');
      height_pass := height_a_ok AND height_b_ok;
      IF NOT height_pass THEN
        intent_blockers := array_append(intent_blockers, 'height');
      END IF;

      filters_pass := lifestyle_pass AND family_pass AND religion_pass AND height_pass;

      -- 8. Domain-Specific Interests Overlap
      IF shared_intent IN ('romantic', 'friendship', 'activity_partner') THEN
        domain_interest_a := a_personal;
        domain_interest_b := b_personal;
        domain_type := 'personal';
      ELSIF shared_intent IN ('business', 'business_networking') THEN
        domain_interest_a := a_business;
        domain_interest_b := b_business;
        domain_type := 'business';
      ELSE
        domain_interest_a := a_merged_interests;
        domain_interest_b := b_merged_interests;
        domain_type := 'merged';
      END IF;

      IF domain_interest_a = '{}'::jsonb OR domain_interest_b = '{}'::jsonb THEN
        interest_pass := false;
        overlap_cats := ARRAY[]::text[];
      ELSE
        SELECT ARRAY(
          SELECT cat FROM jsonb_object_keys(domain_interest_a) AS cat
          WHERE domain_interest_a ? cat AND domain_interest_b ? cat
            AND (
              (jsonb_array_length(domain_interest_a->cat)=0 AND jsonb_array_length(domain_interest_b->cat)=0)
              OR EXISTS (
                SELECT 1
                FROM jsonb_array_elements_text(domain_interest_a->cat) AS s1(val)
                JOIN jsonb_array_elements_text(domain_interest_b->cat) AS s2(val)
                  ON lower(s1.val) = lower(s2.val) AND lower(s1.val) <> lower(cat)
              )
            )
        ) INTO overlap_cats;
        IF overlap_cats IS NULL THEN overlap_cats := ARRAY[]::text[]; END IF;
        interest_pass := (array_length(overlap_cats, 1) IS NOT NULL AND array_length(overlap_cats, 1) > 0);
      END IF;

      IF NOT interest_pass THEN
        intent_blockers := array_append(intent_blockers, 'interests');
      END IF;

      -- Total Intent Verdict
      intent_all_pass := sub_pass AND gender_pass AND age_pass AND filters_pass AND interest_pass;
      IF intent_all_pass THEN
        compatible_intents := array_append(compatible_intents, shared_intent);
      END IF;

      entry := jsonb_build_object(
        'intent', shared_intent,
        'domain_type', domain_type,
        'all_passed', intent_all_pass,
        'blockers', COALESCE(to_jsonb(intent_blockers), '[]'::jsonb),
        'sub_intent', jsonb_build_object(
          'passed', sub_pass,
          'unrestricted', sub_unrestricted,
          'a_values', COALESCE(to_jsonb(a_sub_arr), '[]'::jsonb),
          'b_values', COALESCE(to_jsonb(b_sub_arr), '[]'::jsonb),
          'overlap', COALESCE(to_jsonb(overlap_sub), '[]'::jsonb)
        ),
        'gender', jsonb_build_object(
          'passed', gender_pass,
          'a_gender', a_gender,
          'b_gender', b_gender,
          'a_ok_for_b', a_gender_ok,
          'b_ok_for_a', b_gender_ok,
          'a_pref', COALESCE(a_gender_prefs -> shared_intent, '[]'::jsonb),
          'b_pref', COALESCE(b_gender_prefs -> shared_intent, '[]'::jsonb)
        ),
        'age', jsonb_build_object(
          'passed', age_pass,
          'a_age', a_age,
          'b_age', b_age,
          'a_ok', a_age_ok,
          'b_ok', b_age_ok,
          'a_pref', COALESCE(a_age_prefs -> shared_intent, '[]'::jsonb),
          'b_pref', COALESCE(b_age_prefs -> shared_intent, '[]'::jsonb)
        ),
        'lifestyle', jsonb_build_object(
          'passed', lifestyle_pass,
          'a_pass', lifestyle_a_pass,
          'b_pass', lifestyle_b_pass,
          'smoking', jsonb_build_object('passed', smoke_pass, 'a_val', smoke_a_val, 'b_val', smoke_b_val, 'a_ok', smoke_a_ok, 'b_ok', smoke_b_ok, 'a_pref', COALESCE(a_lifestyle_filter->'smoking', '[]'::jsonb), 'b_pref', COALESCE(b_lifestyle_filter->'smoking', '[]'::jsonb)),
          'drinking', jsonb_build_object('passed', drink_pass, 'a_val', drink_a_val, 'b_val', drink_b_val, 'a_ok', drink_a_ok, 'b_ok', drink_b_ok, 'a_pref', COALESCE(a_lifestyle_filter->'drinking', '[]'::jsonb), 'b_pref', COALESCE(b_lifestyle_filter->'drinking', '[]'::jsonb)),
          'diet', jsonb_build_object('passed', diet_pass, 'a_val', diet_a_val, 'b_val', diet_b_val, 'a_ok', diet_a_ok, 'b_ok', diet_b_ok, 'a_pref', COALESCE(a_lifestyle_filter->'diets', '[]'::jsonb), 'b_pref', COALESCE(b_lifestyle_filter->'diets', '[]'::jsonb)),
          'exercise', jsonb_build_object('passed', ex_pass, 'a_val', ex_a_val, 'b_val', ex_b_val, 'a_ok', ex_a_ok, 'b_ok', ex_b_ok, 'a_pref', COALESCE(a_lifestyle_filter->'exercise', '[]'::jsonb), 'b_pref', COALESCE(b_lifestyle_filter->'exercise', '[]'::jsonb))
        ),
        'family', jsonb_build_object(
          'passed', family_pass,
          'a_pass', family_a_pass,
          'b_pass', family_b_pass,
          'has_children', jsonb_build_object('passed', has_child_pass, 'a_val', has_child_a_val, 'b_val', has_child_b_val, 'a_ok', has_child_a_ok, 'b_ok', has_child_b_ok, 'a_pref', COALESCE(a_family_filter->'has_children', '[]'::jsonb), 'b_pref', COALESCE(b_family_filter->'has_children', '[]'::jsonb)),
          'wants_children', jsonb_build_object('passed', wants_child_pass, 'a_val', wants_child_a_val, 'b_val', wants_child_b_val, 'a_ok', wants_child_a_ok, 'b_ok', wants_child_b_ok, 'a_pref', COALESCE(a_family_filter->'wants_children', '[]'::jsonb), 'b_pref', COALESCE(b_family_filter->'wants_children', '[]'::jsonb))
        ),
        'religion', jsonb_build_object(
          'passed', religion_pass,
          'a_pass', religion_a_pass,
          'b_pass', religion_b_pass,
          'a_val', relig_a_val,
          'b_val', relig_b_val,
          'a_ok', relig_a_ok,
          'b_ok', relig_b_ok,
          'a_pref', COALESCE(a_religion_filter->'religions', '[]'::jsonb),
          'b_pref', COALESCE(b_religion_filter->'religions', '[]'::jsonb)
        ),
        'height', jsonb_build_object(
          'passed', height_pass,
          'a_pass', height_a_ok,
          'b_pass', height_b_ok,
          'a_val', a_height,
          'b_val', b_height,
          'a_pref', a_height_filter,
          'b_pref', b_height_filter
        ),
        'filters', jsonb_build_object('passed', filters_pass),
        'interests', jsonb_build_object(
          'passed', interest_pass,
          'domain_type', domain_type,
          'overlap_categories', COALESCE(to_jsonb(overlap_cats), '[]'::jsonb)
        )
      );

      per_intent := per_intent || jsonb_build_array(entry);
    END LOOP;
  ELSE
    all_blockers := all_blockers || jsonb_build_array('no_shared_intents');
  END IF;

  compat := (array_length(compatible_intents, 1) IS NOT NULL AND array_length(compatible_intents, 1) > 0);

  RETURN jsonb_build_object(
    'user_a', jsonb_build_object(
      'id', p_user_a,
      'name', COALESCE(a_name, ''),
      'email', COALESCE(a_email, ''),
      'gender', a_gender,
      'age', a_age,
      'date_of_birth', a_dob,
      'height', a_height,
      'match_radius_meters', a_radius,
      'visibility_user', a_vis_user,
      'visibility_system', a_vis_sys,
      'is_online', a_online,
      'last_active_at', a_last_active,
      'location_updated_at', a_loc_updated,
      'lifestyle', COALESCE(a_lifestyle, '{}'::jsonb),
      'family', COALESCE(a_family, '{}'::jsonb),
      'religion', COALESCE(a_religion, '{}'::jsonb),
      'active_modes', COALESCE(to_jsonb(a_active_arr), '[]'::jsonb),
      'sub_intents', COALESCE(a_sub_intents, '{}'::jsonb),
      'interests', COALESCE(a_merged_interests, '{}'::jsonb),
      'personal_interests', COALESCE(a_personal, '{}'::jsonb),
      'business_interests', COALESCE(a_business, '{}'::jsonb),
      'intent_preferences', COALESCE(a_prefs, '{}'::jsonb),
      'photos', a_photos
    ),
    'user_b', jsonb_build_object(
      'id', p_user_b,
      'name', COALESCE(b_name, ''),
      'email', COALESCE(b_email, ''),
      'gender', b_gender,
      'age', b_age,
      'date_of_birth', b_dob,
      'height', b_height,
      'match_radius_meters', b_radius,
      'visibility_user', b_vis_user,
      'visibility_system', b_vis_sys,
      'is_online', b_online,
      'last_active_at', b_last_active,
      'location_updated_at', b_loc_updated,
      'lifestyle', COALESCE(b_lifestyle, '{}'::jsonb),
      'family', COALESCE(b_family, '{}'::jsonb),
      'religion', COALESCE(b_religion, '{}'::jsonb),
      'active_modes', COALESCE(to_jsonb(b_active_arr), '[]'::jsonb),
      'sub_intents', COALESCE(b_sub_intents, '{}'::jsonb),
      'interests', COALESCE(b_merged_interests, '{}'::jsonb),
      'personal_interests', COALESCE(b_personal, '{}'::jsonb),
      'business_interests', COALESCE(b_business, '{}'::jsonb),
      'intent_preferences', COALESCE(b_prefs, '{}'::jsonb),
      'photos', b_photos
    ),
    'environmental', jsonb_build_object(
      'distance_km', v_distance_km,
      'a_radius_km', v_a_radius_km,
      'b_radius_km', v_b_radius_km,
      'a_in_b_radius', v_a_in_b_radius,
      'b_in_a_radius', v_b_in_a_radius,
      'proximity_pass', v_proximity_pass,
      'a_visible', (a_vis_user AND a_vis_sys = 'visible'),
      'b_visible', (b_vis_user AND b_vis_sys = 'visible'),
      'a_online', a_online,
      'b_online', b_online
    ),
    'shared_intents', COALESCE(to_jsonb(shared_intents), '[]'::jsonb),
    'has_shared_intents', (array_length(shared_intents,1) IS NOT NULL AND array_length(shared_intents,1) > 0),
    'already_matched', v_already_matched,
    'matched_intent', v_matched_intent,
    'match_type', v_match_type,
    'matched_at', v_matched_at,
    'is_unmatched_pair', v_unmatched,
    'unmatched_at', v_unmatched_at,
    'per_intent', per_intent,
    'compatible_intents', COALESCE(to_jsonb(compatible_intents), '[]'::jsonb),
    'is_compatible', compat
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_compare_users(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_compare_users(uuid, uuid) TO service_role;

-- Seed translations for new Match Inspector features
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchInspectorBlockersTitle', $$Blockers preventing match$$),
  ('es', 'matchInspectorBlockersTitle', $$Factores que impiden la coincidencia$$),
  ('he', 'matchInspectorBlockersTitle', $$חסימות המונעות התאמה$$),

  ('en', 'matchInspectorBlockersNone', $$All criteria passed — these users can match!$$),
  ('es', 'matchInspectorBlockersNone', $$¡Todos los criterios aprobados — estos usuarios pueden coincidir!$$),
  ('he', 'matchInspectorBlockersNone', $$כל הקריטריונים עברו בהצלחה — משתמשים אלה יכולים להתאים!$$),

  ('en', 'matchInspectorEnvironmentalHeader', $$Environment & System Status$$),
  ('es', 'matchInspectorEnvironmentalHeader', $$Estado del entorno y sistema$$),
  ('he', 'matchInspectorEnvironmentalHeader', $$סביבה וסטטוס מערכת$$),

  ('en', 'matchInspectorDistance', $$Distance$$),
  ('es', 'matchInspectorDistance', $$Distancia$$),
  ('he', 'matchInspectorDistance', $$מרחק$$),

  ('en', 'matchInspectorDistanceUnknown', $$Location not reported$$),
  ('es', 'matchInspectorDistanceUnknown', $$Ubicación no reportada$$),
  ('he', 'matchInspectorDistanceUnknown', $$מיקום לא דווח$$),

  ('en', 'matchInspectorWithinRadius', $$Within radius$$),
  ('es', 'matchInspectorWithinRadius', $$Dentro del radio$$),
  ('he', 'matchInspectorWithinRadius', $$בטווח הרדיוס$$),

  ('en', 'matchInspectorOutOfRadius', $$Exceeds match radius$$),
  ('es', 'matchInspectorOutOfRadius', $$Supera el radio de match$$),
  ('he', 'matchInspectorOutOfRadius', $$חורג מרדיוס ההתאמה$$),

  ('en', 'matchInspectorMatrixParam', $$Criteria / Filter$$),
  ('es', 'matchInspectorMatrixParam', $$Criterio / Filtro$$),
  ('he', 'matchInspectorMatrixParam', $$קריטריון / מסנן$$),

  ('en', 'matchInspectorMatrixUserA', $$User A (Profile & Wants)$$),
  ('es', 'matchInspectorMatrixUserA', $$Usuario A (Perfil y Deseos)$$),
  ('he', 'matchInspectorMatrixUserA', $$משתמש א' (פרופיל והעדפות)$$),

  ('en', 'matchInspectorMatrixUserB', $$User B (Profile & Wants)$$),
  ('es', 'matchInspectorMatrixUserB', $$Usuario B (Perfil y Deseos)$$),
  ('he', 'matchInspectorMatrixUserB', $$משתמש ב' (פרופיל והעדפות)$$),

  ('en', 'matchInspectorMatrixVerdict', $$Match Verdict$$),
  ('es', 'matchInspectorMatrixVerdict', $$Veredicto$$),
  ('he', 'matchInspectorMatrixVerdict', $$פסק דין$$),

  ('en', 'matchInspectorSmoking', $$Smoking$$),
  ('es', 'matchInspectorSmoking', $$Fumar$$),
  ('he', 'matchInspectorSmoking', $$עישון$$),

  ('en', 'matchInspectorDrinking', $$Drinking$$),
  ('es', 'matchInspectorDrinking', $$Bebida$$),
  ('he', 'matchInspectorDrinking', $$שתייה$$),

  ('en', 'matchInspectorDiet', $$Diet$$),
  ('es', 'matchInspectorDiet', $$Dieta$$),
  ('he', 'matchInspectorDiet', $$תזונה$$),

  ('en', 'matchInspectorExercise', $$Exercise$$),
  ('es', 'matchInspectorExercise', $$Ejercicio$$),
  ('he', 'matchInspectorExercise', $$כושר גופני$$),

  ('en', 'matchInspectorHasChildren', $$Has Children$$),
  ('es', 'matchInspectorHasChildren', $$Tiene hijos$$),
  ('he', 'matchInspectorHasChildren', $$יש ילדים$$),

  ('en', 'matchInspectorWantsChildren', $$Wants Children$$),
  ('es', 'matchInspectorWantsChildren', $$Desea hijos$$),
  ('he', 'matchInspectorWantsChildren', $$רוצה ילדים$$),

  ('en', 'matchInspectorReligion', $$Religion$$),
  ('es', 'matchInspectorReligion', $$Religión$$),
  ('he', 'matchInspectorReligion', $$דת$$),

  ('en', 'matchInspectorHeight', $$Height$$),
  ('es', 'matchInspectorHeight', $$Altura$$),
  ('he', 'matchInspectorHeight', $$גובה$$),

  ('en', 'matchInspectorInterests', $$Interests Overlap$$),
  ('es', 'matchInspectorInterests', $$Coincidencia de intereses$$),
  ('he', 'matchInspectorInterests', $$חפיפת תחומי עניין$$),

  ('en', 'matchInspectorSubIntents', $$Sub-Intents$$),
  ('es', 'matchInspectorSubIntents', $$Sub-intenciones$$),
  ('he', 'matchInspectorSubIntents', $$תת-כוונות$$),

  ('en', 'matchInspectorOnline', $$Online$$),
  ('es', 'matchInspectorOnline', $$En línea$$),
  ('he', 'matchInspectorOnline', $$מחובר$$),

  ('en', 'matchInspectorOffline', $$Offline$$),
  ('es', 'matchInspectorOffline', $$Desconectado$$),
  ('he', 'matchInspectorOffline', $$לא מחובר$$),

  ('en', 'matchInspectorVisible', $$Visible$$),
  ('es', 'matchInspectorVisible', $$Visible$$),
  ('he', 'matchInspectorVisible', $$גלוי$$),

  ('en', 'matchInspectorHidden', $$Hidden$$),
  ('es', 'matchInspectorHidden', $$Oculto$$),
  ('he', 'matchInspectorHidden', $$מוסתר$$),

  ('en', 'matchInspectorGhosted', $$Ghosted$$),
  ('es', 'matchInspectorGhosted', $$Modo fantasma$$),
  ('he', 'matchInspectorGhosted', $$במצב רפאים$$),

  ('en', 'matchInspectorUnrestricted', $$Unrestricted / Any$$),
  ('es', 'matchInspectorUnrestricted', $$Sin restricción / Cualquiera$$),
  ('he', 'matchInspectorUnrestricted', $$ללא הגבלה / הכל$$),

  ('en', 'matchInspectorMutualPass', $$Mutual Match$$),
  ('es', 'matchInspectorMutualPass', $$Coincidencia mutua$$),
  ('he', 'matchInspectorMutualPass', $$התאמה הדדית$$),

  ('en', 'matchInspectorMismatch', $$Mismatch$$),
  ('es', 'matchInspectorMismatch', $$Discrepancia$$),
  ('he', 'matchInspectorMismatch', $$אי-התאמה$$),

  ('en', 'matchInspectorUserAMismatch', $$User A violates User B filter$$),
  ('es', 'matchInspectorUserAMismatch', $$Usuario A no cumple filtro de B$$),
  ('he', 'matchInspectorUserAMismatch', $$משתמש א' חורג מהמסנן של ב'$$),

  ('en', 'matchInspectorUserBMismatch', $$User B violates User A filter$$),
  ('es', 'matchInspectorUserBMismatch', $$Usuario B no cumple filtro de A$$),
  ('he', 'matchInspectorUserBMismatch', $$משתמש ב' חורג מהמסנן של א'$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
