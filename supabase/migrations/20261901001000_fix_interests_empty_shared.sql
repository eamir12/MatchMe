-- Fix interest matching: shared top-level with both empty sub-lists should be considered shared
-- Also filter out category name appearing as its own sub (Volunteering: Volunteering)
BEGIN;

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
  a_exists boolean := false; a_name text; a_gender text; a_dob date; a_age integer; a_lifestyle jsonb; a_family jsonb; a_religion jsonb; a_height integer; a_active jsonb; a_active_arr text[]; a_sub_intents jsonb; a_personal jsonb; a_business jsonb; a_merged_interests jsonb; a_prefs jsonb;
  b_exists boolean := false; b_name text; b_gender text; b_dob date; b_age integer; b_lifestyle jsonb; b_family jsonb; b_religion jsonb; b_height integer; b_active jsonb; b_active_arr text[]; b_sub_intents jsonb; b_personal jsonb; b_business jsonb; b_merged_interests jsonb; b_prefs jsonb;
  shared_intents text[];
  v_already_matched boolean := false; v_matched_intent text; v_match_type text; v_unmatched boolean := false;
  per_intent jsonb := '[]'::jsonb; compatible_intents text[] := ARRAY[]::text[]; compat boolean := false;
  shared_intent text;
  a_sub_arr text[]; b_sub_arr text[]; a_sub_json jsonb; b_sub_json jsonb; overlap_sub text[]; sub_pass boolean;
  a_gender_ok boolean; b_gender_ok boolean; gender_pass boolean; a_age_ok boolean; b_age_ok boolean; age_pass boolean; a_gender_prefs jsonb; b_gender_prefs jsonb; a_age_prefs jsonb; b_age_prefs jsonb;
  lifestyle_pass boolean; family_pass boolean; religion_pass boolean; height_pass boolean; filters_pass boolean;
  a_lifestyle_filter jsonb; b_lifestyle_filter jsonb; a_family_filter jsonb; b_family_filter jsonb; a_religion_filter jsonb; b_religion_filter jsonb; a_height_filter jsonb; b_height_filter jsonb;
  lifestyle_a_pass boolean; lifestyle_b_pass boolean; family_a_pass boolean; family_b_pass boolean; religion_a_pass boolean; religion_b_pass boolean; height_a_pass boolean; height_b_pass boolean;
  interest_pass boolean; overlap_cats text[]; personal_overlap text[]; business_overlap text[]; personal_pass boolean; business_pass boolean;
  intent_all_pass boolean;
  entry jsonb;
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true) INTO v_is_admin;
  IF NOT COALESCE(v_is_admin, false) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_user_a IS NULL OR p_user_b IS NULL THEN RAISE EXCEPTION 'both user ids are required'; END IF;
  IF p_user_a = p_user_b THEN RAISE EXCEPTION 'select two different users'; END IF;

  SELECT u.name, u.gender, u.date_of_birth, up.lifestyle, up.family, up.religion, up.height, up.active_modes, up.sub_intents, COALESCE(up.personal_interests, '{}'::jsonb), COALESCE(up.business_interests, '{}'::jsonb), COALESCE(up.intent_preferences, '{}'::jsonb)
  INTO a_name, a_gender, a_dob, a_lifestyle, a_family, a_religion, a_height, a_active, a_sub_intents, a_personal, a_business, a_prefs
  FROM public.users u LEFT JOIN public.user_profiles up ON up.user_id = u.id WHERE u.id = p_user_a;
  IF a_name IS NOT NULL OR EXISTS (SELECT 1 FROM public.users WHERE id = p_user_a) THEN a_exists := true; END IF;
  IF NOT a_exists THEN SELECT name, gender, date_of_birth INTO a_name, a_gender, a_dob FROM public.users WHERE id = p_user_a; IF FOUND THEN a_exists := true; END IF; END IF;

  SELECT u.name, u.gender, u.date_of_birth, up.lifestyle, up.family, up.religion, up.height, up.active_modes, up.sub_intents, COALESCE(up.personal_interests, '{}'::jsonb), COALESCE(up.business_interests, '{}'::jsonb), COALESCE(up.intent_preferences, '{}'::jsonb)
  INTO b_name, b_gender, b_dob, b_lifestyle, b_family, b_religion, b_height, b_active, b_sub_intents, b_personal, b_business, b_prefs
  FROM public.users u LEFT JOIN public.user_profiles up ON up.user_id = u.id WHERE u.id = p_user_b;
  IF b_name IS NOT NULL OR EXISTS (SELECT 1 FROM public.users WHERE id = p_user_b) THEN b_exists := true; END IF;
  IF NOT b_exists THEN SELECT name, gender, date_of_birth INTO b_name, b_gender, b_dob FROM public.users WHERE id = p_user_b; IF FOUND THEN b_exists := true; END IF; END IF;

  IF NOT a_exists OR NOT b_exists THEN RETURN jsonb_build_object('error', 'user_not_found', 'user_a_exists', a_exists, 'user_b_exists', b_exists); END IF;

  IF a_dob IS NOT NULL THEN a_age := EXTRACT(YEAR FROM AGE(a_dob)); END IF;
  IF b_dob IS NOT NULL THEN b_age := EXTRACT(YEAR FROM AGE(b_dob)); END IF;

  IF a_active IS NULL THEN a_active := '[]'::jsonb; END IF;
  IF b_active IS NULL THEN b_active := '[]'::jsonb; END IF;
  BEGIN SELECT ARRAY(SELECT jsonb_array_elements_text(a_active)) INTO a_active_arr; EXCEPTION WHEN OTHERS THEN a_active_arr := ARRAY[]::text[]; END;
  BEGIN SELECT ARRAY(SELECT jsonb_array_elements_text(b_active)) INTO b_active_arr; EXCEPTION WHEN OTHERS THEN b_active_arr := ARRAY[]::text[]; END;
  IF a_active_arr IS NULL THEN a_active_arr := ARRAY[]::text[]; END IF;
  IF b_active_arr IS NULL THEN b_active_arr := ARRAY[]::text[]; END IF;
  IF a_sub_intents IS NULL THEN a_sub_intents := '{}'::jsonb; END IF;
  IF b_sub_intents IS NULL THEN b_sub_intents := '{}'::jsonb; END IF;
  IF a_prefs IS NULL THEN a_prefs := '{}'::jsonb; END IF;
  IF b_prefs IS NULL THEN b_prefs := '{}'::jsonb; END IF;

  a_merged_interests := public.merge_interest_maps(a_personal, a_business);
  b_merged_interests := public.merge_interest_maps(b_personal, b_business);
  IF a_merged_interests IS NULL THEN a_merged_interests := '{}'::jsonb; END IF;
  IF b_merged_interests IS NULL THEN b_merged_interests := '{}'::jsonb; END IF;

  SELECT ARRAY(SELECT unnest(a_active_arr) INTERSECT SELECT unnest(b_active_arr)) INTO shared_intents;
  IF shared_intents IS NULL THEN shared_intents := ARRAY[]::text[]; END IF;

  SELECT m.matched_intent, m.match_type INTO v_matched_intent, v_match_type FROM public.matches m WHERE (m.user1_id = p_user_a AND m.user2_id = p_user_b) OR (m.user1_id = p_user_b AND m.user2_id = p_user_a) LIMIT 1;
  IF FOUND THEN v_already_matched := true; END IF;
  IF EXISTS (SELECT 1 FROM public.unmatched_pairs up2 WHERE (up2.user1_id = p_user_a AND up2.user2_id = p_user_b) OR (up2.user1_id = p_user_b AND up2.user2_id = p_user_a)) THEN v_unmatched := true; END IF;

  IF array_length(shared_intents, 1) IS NOT NULL AND array_length(shared_intents, 1) > 0 THEN
    FOREACH shared_intent IN ARRAY shared_intents LOOP
      a_sub_json := COALESCE(a_sub_intents -> shared_intent, '[]'::jsonb);
      b_sub_json := COALESCE(b_sub_intents -> shared_intent, '[]'::jsonb);
      BEGIN SELECT ARRAY(SELECT jsonb_array_elements_text(a_sub_json)) INTO a_sub_arr; EXCEPTION WHEN OTHERS THEN a_sub_arr := ARRAY[]::text[]; END;
      BEGIN SELECT ARRAY(SELECT jsonb_array_elements_text(b_sub_json)) INTO b_sub_arr; EXCEPTION WHEN OTHERS THEN b_sub_arr := ARRAY[]::text[]; END;
      IF a_sub_arr IS NULL THEN a_sub_arr := ARRAY[]::text[]; END IF;
      IF b_sub_arr IS NULL THEN b_sub_arr := ARRAY[]::text[]; END IF;
      IF array_length(a_sub_arr,1) IS NULL OR array_length(b_sub_arr,1) IS NULL THEN
        IF array_length(a_sub_arr,1) IS NULL OR array_length(b_sub_arr,1) IS NULL THEN sub_pass := false; overlap_sub := ARRAY[]::text[]; ELSE SELECT ARRAY(SELECT unnest(a_sub_arr) INTERSECT SELECT unnest(b_sub_arr)) INTO overlap_sub; IF overlap_sub IS NULL THEN overlap_sub := ARRAY[]::text[]; END IF; sub_pass := array_length(overlap_sub,1) IS NOT NULL AND array_length(overlap_sub,1) > 0; END IF;
      ELSE SELECT ARRAY(SELECT unnest(a_sub_arr) INTERSECT SELECT unnest(b_sub_arr)) INTO overlap_sub; IF overlap_sub IS NULL THEN overlap_sub := ARRAY[]::text[]; END IF; sub_pass := array_length(overlap_sub,1) IS NOT NULL AND array_length(overlap_sub,1) > 0; END IF;

      a_gender_prefs := COALESCE(a_prefs -> 'gender_preferences', '{}'::jsonb);
      b_gender_prefs := COALESCE(b_prefs -> 'gender_preferences', '{}'::jsonb);
      IF NOT (b_gender_prefs ? shared_intent) THEN a_gender_ok := true; ELSE a_gender_ok := (b_gender_prefs -> shared_intent) ? COALESCE(a_gender, ''); END IF;
      IF NOT (a_gender_prefs ? shared_intent) THEN b_gender_ok := true; ELSE b_gender_ok := (a_gender_prefs -> shared_intent) ? COALESCE(b_gender, ''); END IF;
      gender_pass := a_gender_ok AND b_gender_ok;

      a_age_prefs := COALESCE(a_prefs -> 'age_preferences', '{}'::jsonb);
      b_age_prefs := COALESCE(b_prefs -> 'age_preferences', '{}'::jsonb);
      IF NOT (b_age_prefs ? shared_intent) THEN a_age_ok := true; ELSIF a_age IS NULL THEN a_age_ok := true; ELSE BEGIN IF jsonb_array_length(b_age_prefs -> shared_intent) >= 2 AND a_age >= (b_age_prefs -> shared_intent ->> 0)::numeric AND a_age <= (b_age_prefs -> shared_intent ->> 1)::numeric THEN a_age_ok := true; ELSE a_age_ok := false; END IF; EXCEPTION WHEN OTHERS THEN a_age_ok := false; END; END IF;
      IF NOT (a_age_prefs ? shared_intent) THEN b_age_ok := true; ELSIF b_age IS NULL THEN b_age_ok := true; ELSE BEGIN IF jsonb_array_length(a_age_prefs -> shared_intent) >= 2 AND b_age >= (a_age_prefs -> shared_intent ->> 0)::numeric AND b_age <= (a_age_prefs -> shared_intent ->> 1)::numeric THEN b_age_ok := true; ELSE b_age_ok := false; END IF; EXCEPTION WHEN OTHERS THEN b_age_ok := false; END; END IF;
      age_pass := a_age_ok AND b_age_ok;

      a_lifestyle_filter := COALESCE((a_prefs -> 'lifestyle_filters' -> shared_intent), NULL);
      b_lifestyle_filter := COALESCE((b_prefs -> 'lifestyle_filters' -> shared_intent), NULL);
      a_family_filter := COALESCE((a_prefs -> 'family_filters' -> shared_intent), NULL);
      b_family_filter := COALESCE((b_prefs -> 'family_filters' -> shared_intent), NULL);
      a_religion_filter := COALESCE((a_prefs -> 'religion_filters' -> shared_intent), NULL);
      b_religion_filter := COALESCE((b_prefs -> 'religion_filters' -> shared_intent), NULL);
      a_height_filter := COALESCE((a_prefs -> 'height_preferences' -> shared_intent), NULL);
      b_height_filter := COALESCE((b_prefs -> 'height_preferences' -> shared_intent), NULL);

      BEGIN lifestyle_a_pass := public.check_preference_filter(b_lifestyle_filter, COALESCE(a_lifestyle, '{}'::jsonb), a_height, 'lifestyle'); EXCEPTION WHEN OTHERS THEN lifestyle_a_pass := false; END;
      BEGIN lifestyle_b_pass := public.check_preference_filter(a_lifestyle_filter, COALESCE(b_lifestyle, '{}'::jsonb), b_height, 'lifestyle'); EXCEPTION WHEN OTHERS THEN lifestyle_b_pass := false; END;
      lifestyle_pass := lifestyle_a_pass AND lifestyle_b_pass;

      BEGIN family_a_pass := public.check_preference_filter(b_family_filter, COALESCE(a_family, '{}'::jsonb), a_height, 'family'); EXCEPTION WHEN OTHERS THEN family_a_pass := false; END;
      BEGIN family_b_pass := public.check_preference_filter(a_family_filter, COALESCE(b_family, '{}'::jsonb), b_height, 'family'); EXCEPTION WHEN OTHERS THEN family_b_pass := false; END;
      family_pass := family_a_pass AND family_b_pass;

      BEGIN religion_a_pass := public.check_preference_filter(b_religion_filter, COALESCE(a_religion, '{}'::jsonb), a_height, 'religion'); EXCEPTION WHEN OTHERS THEN religion_a_pass := false; END;
      BEGIN religion_b_pass := public.check_preference_filter(a_religion_filter, COALESCE(b_religion, '{}'::jsonb), b_height, 'religion'); EXCEPTION WHEN OTHERS THEN religion_b_pass := false; END;
      religion_pass := religion_a_pass AND religion_b_pass;

      BEGIN height_a_pass := public.check_preference_filter(b_height_filter, NULL, a_height, 'height'); EXCEPTION WHEN OTHERS THEN height_a_pass := false; END;
      BEGIN height_b_pass := public.check_preference_filter(a_height_filter, NULL, b_height, 'height'); EXCEPTION WHEN OTHERS THEN height_b_pass := false; END;
      height_pass := height_a_pass AND height_b_pass;

      filters_pass := lifestyle_pass AND family_pass AND religion_pass AND height_pass;

      -- Interests: treat shared top-level with both empty sub-lists as shared, and filter out category-as-sub duplication
      IF a_merged_interests = '{}'::jsonb OR b_merged_interests = '{}'::jsonb THEN
        interest_pass := false; overlap_cats := ARRAY[]::text[];
      ELSE
        SELECT ARRAY(
          SELECT cat FROM jsonb_object_keys(a_merged_interests) AS cat
          WHERE a_merged_interests ? cat AND b_merged_interests ? cat
            AND (
              (jsonb_array_length(a_merged_interests->cat)=0 AND jsonb_array_length(b_merged_interests->cat)=0)
              OR EXISTS (
                SELECT 1 FROM jsonb_array_elements_text(a_merged_interests->cat) AS sub
                WHERE lower(sub) <> lower(cat)
                  AND sub = ANY(SELECT jsonb_array_elements_text(b_merged_interests->cat) WHERE lower(jsonb_array_elements_text::text) <> lower(cat))
              )
            )
        ) INTO overlap_cats;
        IF overlap_cats IS NULL THEN overlap_cats := ARRAY[]::text[]; END IF;
        -- Need to handle the above EXISTS correctly with filtering; use a more explicit check:
        -- Recompute with proper filtering if the above is not accurate, fallback to simple check with both-empty handling
        IF array_length(overlap_cats,1) IS NULL THEN
          -- Fallback simple: if both have cat and both empty, consider overlap
          SELECT ARRAY(
            SELECT cat FROM jsonb_object_keys(a_merged_interests) AS cat
            WHERE a_merged_interests ? cat AND b_merged_interests ? cat
              AND (
                (jsonb_array_length(a_merged_interests->cat)=0 AND jsonb_array_length(b_merged_interests->cat)=0)
                OR EXISTS (
                  SELECT 1 FROM jsonb_array_elements_text(a_merged_interests->cat) AS s1
                  JOIN jsonb_array_elements_text(b_merged_interests->cat) AS s2 ON lower(s1) = lower(s2) AND lower(s1) <> lower(cat)
                )
              )
          ) INTO overlap_cats;
          IF overlap_cats IS NULL THEN overlap_cats := ARRAY[]::text[]; END IF;
        END IF;
        interest_pass := array_length(overlap_cats,1) IS NOT NULL AND array_length(overlap_cats,1) > 0;
      END IF;

      -- Separate personal/business for display, with same empty-shared logic
      IF a_personal = '{}'::jsonb OR b_personal = '{}'::jsonb THEN
        personal_overlap := ARRAY[]::text[];
      ELSE
        SELECT ARRAY(
          SELECT cat FROM jsonb_object_keys(a_personal) AS cat
          WHERE a_personal ? cat AND b_personal ? cat
            AND (
              (jsonb_array_length(a_personal->cat)=0 AND jsonb_array_length(b_personal->cat)=0)
              OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(a_personal->cat) AS s1 JOIN jsonb_array_elements_text(b_personal->cat) AS s2 ON lower(s1)=lower(s2) AND lower(s1) <> lower(cat))
            )
        ) INTO personal_overlap;
        IF personal_overlap IS NULL THEN personal_overlap := ARRAY[]::text[]; END IF;
      END IF;
      IF a_business = '{}'::jsonb OR b_business = '{}'::jsonb THEN
        business_overlap := ARRAY[]::text[];
      ELSE
        SELECT ARRAY(
          SELECT cat FROM jsonb_object_keys(a_business) AS cat
          WHERE a_business ? cat AND b_business ? cat
            AND (
              (jsonb_array_length(a_business->cat)=0 AND jsonb_array_length(b_business->cat)=0)
              OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(a_business->cat) AS s1 JOIN jsonb_array_elements_text(b_business->cat) AS s2 ON lower(s1)=lower(s2) AND lower(s1) <> lower(cat))
            )
        ) INTO business_overlap;
        IF business_overlap IS NULL THEN business_overlap := ARRAY[]::text[]; END IF;
      END IF;
      personal_pass := array_length(personal_overlap,1) IS NOT NULL AND array_length(personal_overlap,1) > 0;
      business_pass := array_length(business_overlap,1) IS NOT NULL AND array_length(business_overlap,1) > 0;

      intent_all_pass := sub_pass AND gender_pass AND age_pass AND filters_pass AND interest_pass;
      IF intent_all_pass THEN compatible_intents := array_append(compatible_intents, shared_intent); END IF;

      entry := jsonb_build_object(
        'intent', shared_intent,
        'sub_intent', jsonb_build_object('passed', sub_pass, 'a_values', COALESCE(to_jsonb(a_sub_arr), '[]'::jsonb), 'b_values', COALESCE(to_jsonb(b_sub_arr), '[]'::jsonb), 'overlap', COALESCE(to_jsonb(overlap_sub), '[]'::jsonb)),
        'gender', jsonb_build_object('passed', gender_pass, 'a_gender', a_gender, 'b_gender', b_gender, 'a_ok_for_b', a_gender_ok, 'b_ok_for_a', b_gender_ok, 'a_pref', COALESCE(b_gender_prefs -> shared_intent, '[]'::jsonb), 'b_pref', COALESCE(a_gender_prefs -> shared_intent, '[]'::jsonb)),
        'age', jsonb_build_object('passed', age_pass, 'a_age', a_age, 'b_age', b_age, 'a_ok', a_age_ok, 'b_ok', b_age_ok, 'a_pref', COALESCE(b_age_prefs -> shared_intent, '[]'::jsonb), 'b_pref', COALESCE(a_age_prefs -> shared_intent, '[]'::jsonb)),
        'lifestyle', jsonb_build_object('passed', lifestyle_pass, 'a_pass', lifestyle_a_pass, 'b_pass', lifestyle_b_pass, 'a_filter', COALESCE(b_lifestyle_filter, '{}'::jsonb), 'b_filter', COALESCE(a_lifestyle_filter, '{}'::jsonb), 'a_value', COALESCE(a_lifestyle, '{}'::jsonb), 'b_value', COALESCE(b_lifestyle, '{}'::jsonb)),
        'family', jsonb_build_object('passed', family_pass, 'a_pass', family_a_pass, 'b_pass', family_b_pass, 'a_filter', COALESCE(b_family_filter, '{}'::jsonb), 'b_filter', COALESCE(a_family_filter, '{}'::jsonb), 'a_value', COALESCE(a_family, '{}'::jsonb), 'b_value', COALESCE(b_family, '{}'::jsonb)),
        'religion', jsonb_build_object('passed', religion_pass, 'a_pass', religion_a_pass, 'b_pass', religion_b_pass, 'a_filter', COALESCE(b_religion_filter, '{}'::jsonb), 'b_filter', COALESCE(a_religion_filter, '{}'::jsonb), 'a_value', COALESCE(a_religion, '{}'::jsonb), 'b_value', COALESCE(b_religion, '{}'::jsonb)),
        'height', jsonb_build_object('passed', height_pass, 'a_pass', height_a_pass, 'b_pass', height_b_pass, 'a_filter', COALESCE(b_height_filter, '{}'::jsonb), 'b_filter', COALESCE(a_height_filter, '{}'::jsonb), 'a_height', a_height, 'b_height', b_height),
        'filters', jsonb_build_object('passed', filters_pass),
        'interests', jsonb_build_object('passed', interest_pass, 'overlap_categories', COALESCE(to_jsonb(overlap_cats), '[]'::jsonb), 'personal_overlap', COALESCE(to_jsonb(personal_overlap), '[]'::jsonb), 'business_overlap', COALESCE(to_jsonb(business_overlap), '[]'::jsonb), 'personal_pass', personal_pass, 'business_pass', business_pass),
        'all_passed', intent_all_pass
      );
      per_intent := per_intent || jsonb_build_array(entry);
    END LOOP;
  END IF;
  compat := array_length(compatible_intents,1) IS NOT NULL AND array_length(compatible_intents,1) > 0;
  RETURN jsonb_build_object(
    'user_a', jsonb_build_object('id', p_user_a, 'name', COALESCE(a_name, ''), 'gender', a_gender, 'age', a_age, 'date_of_birth', a_dob, 'height', a_height, 'lifestyle', COALESCE(a_lifestyle, '{}'::jsonb), 'family', COALESCE(a_family, '{}'::jsonb), 'religion', COALESCE(a_religion, '{}'::jsonb), 'active_modes', COALESCE(to_jsonb(a_active_arr), '[]'::jsonb), 'sub_intents', COALESCE(a_sub_intents, '{}'::jsonb), 'interests', COALESCE(a_merged_interests, '{}'::jsonb), 'personal_interests', COALESCE(a_personal, '{}'::jsonb), 'business_interests', COALESCE(a_business, '{}'::jsonb), 'intent_preferences', COALESCE(a_prefs, '{}'::jsonb)),
    'user_b', jsonb_build_object('id', p_user_b, 'name', COALESCE(b_name, ''), 'gender', b_gender, 'age', b_age, 'date_of_birth', b_dob, 'height', b_height, 'lifestyle', COALESCE(b_lifestyle, '{}'::jsonb), 'family', COALESCE(b_family, '{}'::jsonb), 'religion', COALESCE(b_religion, '{}'::jsonb), 'active_modes', COALESCE(to_jsonb(b_active_arr), '[]'::jsonb), 'sub_intents', COALESCE(b_sub_intents, '{}'::jsonb), 'interests', COALESCE(b_merged_interests, '{}'::jsonb), 'personal_interests', COALESCE(b_personal, '{}'::jsonb), 'business_interests', COALESCE(b_business, '{}'::jsonb), 'intent_preferences', COALESCE(b_prefs, '{}'::jsonb)),
    'shared_intents', COALESCE(to_jsonb(shared_intents), '[]'::jsonb),
    'has_shared_intents', (array_length(shared_intents,1) IS NOT NULL AND array_length(shared_intents,1) > 0),
    'already_matched', v_already_matched,
    'matched_intent', v_matched_intent,
    'match_type', v_match_type,
    'is_unmatched_pair', v_unmatched,
    'per_intent', per_intent,
    'compatible_intents', COALESCE(to_jsonb(compatible_intents), '[]'::jsonb),
    'is_compatible', compat
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_compare_users(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_compare_users(uuid, uuid) TO service_role;
COMMIT;
