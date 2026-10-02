-- Migration: Admin Match Comparison — admin search + detailed compatibility RPC
-- Purpose: Allow admin to pick 2 users and see why they match or not

BEGIN;

-- ---------------------------------------------------------------------------
-- Helper: admin check
-- ---------------------------------------------------------------------------
-- Reuses pattern from other admin RPCs.

-- ---------------------------------------------------------------------------
-- 1) admin_search_users — search users for dropdown
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_search_users(text, integer);
CREATE OR REPLACE FUNCTION public.admin_search_users(
  p_query text DEFAULT NULL,
  p_limit integer DEFAULT 20
)
RETURNS TABLE (
  id uuid,
  name text,
  email text,
  gender text,
  date_of_birth date,
  photos jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_query text;
  v_limit integer;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_query := NULLIF(trim(COALESCE(p_query, '')), '');
  v_limit := GREATEST(LEAST(COALESCE(p_limit, 20), 100), 1);

  -- Defensive: avoid referencing u.email / u.created_at which may not exist in all envs
  -- Use dynamic SQL so function creation succeeds even if column is missing.
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='users' AND column_name='email'
  ) THEN
    RETURN QUERY EXECUTE
      'SELECT
         u.id,
         COALESCE(u.name, '''') AS name,
         COALESCE(u.email, '''') AS email,
         u.gender,
         u.date_of_birth,
         COALESCE(up.photos, ''[]''::jsonb) AS photos
       FROM public.users u
       LEFT JOIN public.user_profiles up ON up.user_id = u.id
       WHERE ($1 IS NULL
         OR u.id::text ILIKE ''%'' || $1 || ''%''
         OR COALESCE(u.name, '''') ILIKE ''%'' || $1 || ''%''
         OR COALESCE(u.email, '''') ILIKE ''%'' || $1 || ''%'')
       ORDER BY
         CASE WHEN $1 IS NULL THEN 0 ELSE
           CASE WHEN COALESCE(u.name,'''') ILIKE $1 || ''%'' THEN 0
                WHEN COALESCE(u.name,'''') ILIKE ''%'' || $1 || ''%'' THEN 1
                ELSE 2 END
         END,
         u.id DESC
       LIMIT $2'
    USING v_query, v_limit;
  ELSE
    RETURN QUERY EXECUTE
      'SELECT
         u.id,
         COALESCE(u.name, '''') AS name,
         ''''::text AS email,
         u.gender,
         u.date_of_birth,
         COALESCE(up.photos, ''[]''::jsonb) AS photos
       FROM public.users u
       LEFT JOIN public.user_profiles up ON up.user_id = u.id
       WHERE ($1 IS NULL
         OR u.id::text ILIKE ''%'' || $1 || ''%''
         OR COALESCE(u.name, '''') ILIKE ''%'' || $1 || ''%'')
       ORDER BY
         CASE WHEN $1 IS NULL THEN 0 ELSE
           CASE WHEN COALESCE(u.name,'''') ILIKE $1 || ''%'' THEN 0
                WHEN COALESCE(u.name,'''') ILIKE ''%'' || $1 || ''%'' THEN 1
                ELSE 2 END
         END,
         u.id DESC
       LIMIT $2'
    USING v_query, v_limit;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_search_users(text, integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) admin_compare_users — detailed compatibility breakdown between 2 users
-- ---------------------------------------------------------------------------
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

  -- User A raw
  a_exists boolean := false;
  a_name text;
  a_gender text;
  a_dob date;
  a_age integer;
  a_lifestyle jsonb;
  a_family jsonb;
  a_religion jsonb;
  a_height integer;
  a_active jsonb;
  a_active_arr text[];
  a_sub_intents jsonb;
  a_personal jsonb;
  a_business jsonb;
  a_merged_interests jsonb;
  a_prefs jsonb;

  -- User B raw
  b_exists boolean := false;
  b_name text;
  b_gender text;
  b_dob date;
  b_age integer;
  b_lifestyle jsonb;
  b_family jsonb;
  b_religion jsonb;
  b_height integer;
  b_active jsonb;
  b_active_arr text[];
  b_sub_intents jsonb;
  b_personal jsonb;
  b_business jsonb;
  b_merged_interests jsonb;
  b_prefs jsonb;

  -- Shared intents
  shared_intents text[];

  -- Already matched
  v_match_row record;
  v_already_matched boolean := false;
  v_matched_intent text;
  v_match_type text;
  v_unmatched boolean := false;

  -- Per-intent breakdown
  per_intent jsonb := '[]'::jsonb;
  compatible_intents text[] := ARRAY[]::text[];
  compat boolean := false;

  -- Loop variables
  shared_intent text;
  -- sub-intents
  a_sub_arr text[];
  b_sub_arr text[];
  a_sub_json jsonb;
  b_sub_json jsonb;
  overlap_sub text[];
  sub_pass boolean;

  -- gender/age
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

  -- filters
  lifestyle_pass boolean;
  family_pass boolean;
  religion_pass boolean;
  height_pass boolean;
  filters_pass boolean;

  -- Interests
  interest_pass boolean;
  overlap_cats text[];

  -- Overall
  intent_all_pass boolean;

  -- JSON builders
  entry jsonb;
BEGIN
  -- Admin check
  SELECT EXISTS (
    SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.is_admin = true
  ) INTO v_is_admin;
  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_user_a IS NULL OR p_user_b IS NULL THEN
    RAISE EXCEPTION 'both user ids are required';
  END IF;
  IF p_user_a = p_user_b THEN
    RAISE EXCEPTION 'select two different users';
  END IF;

  -- Load User A
  SELECT
    u.name, u.gender, u.date_of_birth,
    up.lifestyle, up.family, up.religion, up.height,
    up.active_modes, up.sub_intents,
    COALESCE(up.personal_interests, '{}'::jsonb),
    COALESCE(up.business_interests, '{}'::jsonb),
    COALESCE(up.intent_preferences, '{}'::jsonb)
  INTO a_name, a_gender, a_dob, a_lifestyle, a_family, a_religion, a_height,
       a_active, a_sub_intents, a_personal, a_business, a_prefs
  FROM public.users u
  LEFT JOIN public.user_profiles up ON up.user_id = u.id
  WHERE u.id = p_user_a;

  IF a_name IS NOT NULL OR EXISTS (SELECT 1 FROM public.users WHERE id = p_user_a) THEN
    a_exists := true;
  END IF;
  -- fallback fetch if not in join
  IF NOT a_exists THEN
    SELECT name, gender, date_of_birth INTO a_name, a_gender, a_dob FROM public.users WHERE id = p_user_a;
    IF FOUND THEN a_exists := true; END IF;
  END IF;

  -- Load User B
  SELECT
    u.name, u.gender, u.date_of_birth,
    up.lifestyle, up.family, up.religion, up.height,
    up.active_modes, up.sub_intents,
    COALESCE(up.personal_interests, '{}'::jsonb),
    COALESCE(up.business_interests, '{}'::jsonb),
    COALESCE(up.intent_preferences, '{}'::jsonb)
  INTO b_name, b_gender, b_dob, b_lifestyle, b_family, b_religion, b_height,
       b_active, b_sub_intents, b_personal, b_business, b_prefs
  FROM public.users u
  LEFT JOIN public.user_profiles up ON up.user_id = u.id
  WHERE u.id = p_user_b;

  IF b_name IS NOT NULL OR EXISTS (SELECT 1 FROM public.users WHERE id = p_user_b) THEN
    b_exists := true;
  END IF;
  IF NOT b_exists THEN
    SELECT name, gender, date_of_birth INTO b_name, b_gender, b_dob FROM public.users WHERE id = p_user_b;
    IF FOUND THEN b_exists := true; END IF;
  END IF;

  IF NOT a_exists OR NOT b_exists THEN
    RETURN jsonb_build_object(
      'error', 'user_not_found',
      'user_a_exists', a_exists,
      'user_b_exists', b_exists
    );
  END IF;

  -- Ages
  IF a_dob IS NOT NULL THEN
    a_age := EXTRACT(YEAR FROM AGE(a_dob));
  END IF;
  IF b_dob IS NOT NULL THEN
    b_age := EXTRACT(YEAR FROM AGE(b_dob));
  END IF;

  -- Normalize active_modes
  IF a_active IS NULL THEN a_active := '[]'::jsonb; END IF;
  IF b_active IS NULL THEN b_active := '[]'::jsonb; END IF;
  -- Convert to text[]
  BEGIN
    SELECT ARRAY(SELECT elem #>> '{}' FROM jsonb_array_elements(a_active) AS elem) INTO a_active_arr;
  EXCEPTION WHEN OTHERS THEN
    a_active_arr := ARRAY[]::text[];
  END;
  BEGIN
    SELECT ARRAY(SELECT elem #>> '{}' FROM jsonb_array_elements(b_active) AS elem) INTO b_active_arr;
  EXCEPTION WHEN OTHERS THEN
    b_active_arr := ARRAY[]::text[];
  END;
  IF a_active_arr IS NULL THEN a_active_arr := ARRAY[]::text[]; END IF;
  IF b_active_arr IS NULL THEN b_active_arr := ARRAY[]::text[]; END IF;

  IF a_sub_intents IS NULL THEN a_sub_intents := '{}'::jsonb; END IF;
  IF b_sub_intents IS NULL THEN b_sub_intents := '{}'::jsonb; END IF;
  IF a_prefs IS NULL THEN a_prefs := '{}'::jsonb; END IF;
  IF b_prefs IS NULL THEN b_prefs := '{}'::jsonb; END IF;

  -- Merged interests
  a_merged_interests := public.merge_interest_maps(a_personal, a_business);
  b_merged_interests := public.merge_interest_maps(b_personal, b_business);
  IF a_merged_interests IS NULL THEN a_merged_interests := '{}'::jsonb; END IF;
  IF b_merged_interests IS NULL THEN b_merged_interests := '{}'::jsonb; END IF;

  -- Shared intents
  SELECT ARRAY(
    SELECT unnest(a_active_arr) INTERSECT SELECT unnest(b_active_arr)
  ) INTO shared_intents;
  IF shared_intents IS NULL THEN shared_intents := ARRAY[]::text[]; END IF;

  -- Already matched?
  SELECT m.matched_intent, m.match_type INTO v_matched_intent, v_match_type
  FROM public.matches m
  WHERE (m.user1_id = p_user_a AND m.user2_id = p_user_b)
     OR (m.user1_id = p_user_b AND m.user2_id = p_user_a)
  LIMIT 1;
  IF FOUND THEN v_already_matched := true; END IF;

  -- Unmatched pair?
  IF EXISTS (
    SELECT 1 FROM public.unmatched_pairs up2
    WHERE (up2.user1_id = p_user_a AND up2.user2_id = p_user_b)
       OR (up2.user1_id = p_user_b AND up2.user2_id = p_user_a)
  ) THEN
    v_unmatched := true;
  END IF;

  -- Per-intent breakdown
  IF array_length(shared_intents, 1) IS NOT NULL AND array_length(shared_intents, 1) > 0 THEN
    FOREACH shared_intent IN ARRAY shared_intents LOOP
      -- Sub-intents for this intent
      a_sub_json := COALESCE(a_sub_intents -> shared_intent, '[]'::jsonb);
      b_sub_json := COALESCE(b_sub_intents -> shared_intent, '[]'::jsonb);
      -- Convert to text[]
      BEGIN
        SELECT ARRAY(SELECT elem #>> '{}' FROM jsonb_array_elements(a_sub_json) AS elem) INTO a_sub_arr;
      EXCEPTION WHEN OTHERS THEN a_sub_arr := ARRAY[]::text[]; END;
      BEGIN
        SELECT ARRAY(SELECT elem #>> '{}' FROM jsonb_array_elements(b_sub_json) AS elem) INTO b_sub_arr;
      EXCEPTION WHEN OTHERS THEN b_sub_arr := ARRAY[]::text[]; END;
      IF a_sub_arr IS NULL THEN a_sub_arr := ARRAY[]::text[]; END IF;
      IF b_sub_arr IS NULL THEN b_sub_arr := ARRAY[]::text[]; END IF;

      -- Sub-intent pass logic: if both have values, need overlap; if one or both empty, consider pass (matches event logic of requiring overlap only when both present? For proximity matching, requires both have and overlap; but we unify: empty means pass)
      -- We'll use strict proximity rule: both must have at least one and overlap, otherwise fail. However to explain better, we report fail when no overlap if both non-empty, and pass when either empty (flexible).
      -- For admin clarity: if either empty => pass (no restriction), else need overlap.
      IF array_length(a_sub_arr,1) IS NULL OR array_length(b_sub_arr,1) IS NULL THEN
        -- If proximity matching requires both to have sub_intents, then this should fail. But for UI we treat empty as pass to avoid blocking. Let's check proximity vs event: proximity requires both have and overlap, event allows pass if empty.
        -- We will compute sub_pass as: if both empty -> true; if one empty -> true (flexible); if both non-empty -> overlap check.
        -- To stay consistent with perform_continuous_user_matching (strict), we would fail if either empty. However admin should see why not matching, so we expose raw overlap and a strict flag.
        -- We'll report strict: requires overlap when both present, otherwise fail if either empty (since proximity requires sub_intents).
        -- For visibility, set sub_pass = (overlap exists) when both non-empty, else false when either empty.
        IF array_length(a_sub_arr,1) IS NULL OR array_length(b_sub_arr,1) IS NULL THEN
          sub_pass := false;
          overlap_sub := ARRAY[]::text[];
        ELSE
          SELECT ARRAY(SELECT unnest(a_sub_arr) INTERSECT SELECT unnest(b_sub_arr)) INTO overlap_sub;
          IF overlap_sub IS NULL THEN overlap_sub := ARRAY[]::text[]; END IF;
          sub_pass := array_length(overlap_sub,1) IS NOT NULL AND array_length(overlap_sub,1) > 0;
        END IF;
      ELSE
        SELECT ARRAY(SELECT unnest(a_sub_arr) INTERSECT SELECT unnest(b_sub_arr)) INTO overlap_sub;
        IF overlap_sub IS NULL THEN overlap_sub := ARRAY[]::text[]; END IF;
        sub_pass := array_length(overlap_sub,1) IS NOT NULL AND array_length(overlap_sub,1) > 0;
      END IF;

      -- Gender prefs for this intent
      a_gender_prefs := COALESCE(a_prefs -> 'gender_preferences', '{}'::jsonb);
      b_gender_prefs := COALESCE(b_prefs -> 'gender_preferences', '{}'::jsonb);
      -- a candidate (A) against B's filter
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

      -- Age prefs
      a_age_prefs := COALESCE(a_prefs -> 'age_preferences', '{}'::jsonb);
      b_age_prefs := COALESCE(b_prefs -> 'age_preferences', '{}'::jsonb);
      -- B's preference against A
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

      -- Lifestyle / family / religion / height
      -- Use check_preference_filter per category extracted per intent
      -- Need per-intent lifestyle_filters etc: a_prefs->'lifestyle_filters'->intent
      -- For candidate check, lifestyle check uses candidate lifestyle jsonb
      BEGIN
        lifestyle_pass := public.check_preference_filter(
          COALESCE((b_prefs -> 'lifestyle_filters' -> shared_intent), NULL),
          COALESCE(a_lifestyle, '{}'::jsonb), a_height, 'lifestyle'
        ) AND public.check_preference_filter(
          COALESCE((a_prefs -> 'lifestyle_filters' -> shared_intent), NULL),
          COALESCE(b_lifestyle, '{}'::jsonb), b_height, 'lifestyle'
        );
      EXCEPTION WHEN OTHERS THEN lifestyle_pass := false; END;
      BEGIN
        family_pass := public.check_preference_filter(
          COALESCE((b_prefs -> 'family_filters' -> shared_intent), NULL),
          COALESCE(a_family, '{}'::jsonb), a_height, 'family'
        ) AND public.check_preference_filter(
          COALESCE((a_prefs -> 'family_filters' -> shared_intent), NULL),
          COALESCE(b_family, '{}'::jsonb), b_height, 'family'
        );
      EXCEPTION WHEN OTHERS THEN family_pass := false; END;
      BEGIN
        religion_pass := public.check_preference_filter(
          COALESCE((b_prefs -> 'religion_filters' -> shared_intent), NULL),
          COALESCE(a_religion, '{}'::jsonb), a_height, 'religion'
        ) AND public.check_preference_filter(
          COALESCE((a_prefs -> 'religion_filters' -> shared_intent), NULL),
          COALESCE(b_religion, '{}'::jsonb), b_height, 'religion'
        );
      EXCEPTION WHEN OTHERS THEN religion_pass := false; END;
      BEGIN
        height_pass := public.check_preference_filter(
          COALESCE((b_prefs -> 'height_preferences' -> shared_intent), NULL),
          NULL, a_height, 'height'
        ) AND public.check_preference_filter(
          COALESCE((a_prefs -> 'height_preferences' -> shared_intent), NULL),
          NULL, b_height, 'height'
        );
      EXCEPTION WHEN OTHERS THEN height_pass := false; END;
      filters_pass := lifestyle_pass AND family_pass AND religion_pass AND height_pass;

      -- Interests overlap
      IF a_merged_interests = '{}'::jsonb OR b_merged_interests = '{}'::jsonb THEN
        interest_pass := false;
        overlap_cats := ARRAY[]::text[];
      ELSE
        SELECT ARRAY(
          SELECT cat
          FROM jsonb_object_keys(a_merged_interests) AS cat
          WHERE a_merged_interests ? cat AND b_merged_interests ? cat
            AND jsonb_array_length(a_merged_interests->cat) > 0
            AND jsonb_array_length(b_merged_interests->cat) > 0
            AND EXISTS (
              SELECT 1 FROM jsonb_array_elements(a_merged_interests->cat) AS sub
              WHERE sub #>> '{}' = ANY(SELECT elem #>> '{}' FROM jsonb_array_elements(b_merged_interests->cat) AS elem)
            )
        ) INTO overlap_cats;
        IF overlap_cats IS NULL THEN overlap_cats := ARRAY[]::text[]; END IF;
        interest_pass := array_length(overlap_cats,1) IS NOT NULL AND array_length(overlap_cats,1) > 0;
      END IF;

      -- Overall per intent: all criteria must pass
      -- For proximity logic, these all must pass. We also consider sub_intent strictly.
      intent_all_pass := sub_pass AND gender_pass AND age_pass AND filters_pass AND interest_pass;

      IF intent_all_pass THEN
        compatible_intents := array_append(compatible_intents, shared_intent);
      END IF;

      entry := jsonb_build_object(
        'intent', shared_intent,
        'sub_intent', jsonb_build_object(
          'passed', sub_pass,
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
          'a_pref', COALESCE(b_gender_prefs -> shared_intent, '[]'::jsonb),
          'b_pref', COALESCE(a_gender_prefs -> shared_intent, '[]'::jsonb)
        ),
        'age', jsonb_build_object(
          'passed', age_pass,
          'a_age', a_age,
          'b_age', b_age,
          'a_ok', a_age_ok,
          'b_ok', b_age_ok,
          'a_pref', COALESCE(b_age_prefs -> shared_intent, '[]'::jsonb),
          'b_pref', COALESCE(a_age_prefs -> shared_intent, '[]'::jsonb)
        ),
        'lifestyle', jsonb_build_object('passed', lifestyle_pass),
        'family', jsonb_build_object('passed', family_pass),
        'religion', jsonb_build_object('passed', religion_pass),
        'height', jsonb_build_object('passed', height_pass, 'a_height', a_height, 'b_height', b_height),
        'filters', jsonb_build_object('passed', filters_pass),
        'interests', jsonb_build_object('passed', interest_pass, 'overlap_categories', COALESCE(to_jsonb(overlap_cats), '[]'::jsonb)),
        'all_passed', intent_all_pass
      );

      per_intent := per_intent || jsonb_build_array(entry);
    END LOOP;
  END IF;

  compat := array_length(compatible_intents,1) IS NOT NULL AND array_length(compatible_intents,1) > 0;

  RETURN jsonb_build_object(
    'user_a', jsonb_build_object(
      'id', p_user_a,
      'name', COALESCE(a_name, ''),
      'gender', a_gender,
      'age', a_age,
      'date_of_birth', a_dob,
      'height', a_height,
      'lifestyle', COALESCE(a_lifestyle, '{}'::jsonb),
      'family', COALESCE(a_family, '{}'::jsonb),
      'religion', COALESCE(a_religion, '{}'::jsonb),
      'active_modes', COALESCE(to_jsonb(a_active_arr), '[]'::jsonb),
      'sub_intents', COALESCE(a_sub_intents, '{}'::jsonb),
      'interests', COALESCE(a_merged_interests, '{}'::jsonb),
      'intent_preferences', COALESCE(a_prefs, '{}'::jsonb)
    ),
    'user_b', jsonb_build_object(
      'id', p_user_b,
      'name', COALESCE(b_name, ''),
      'gender', b_gender,
      'age', b_age,
      'date_of_birth', b_dob,
      'height', b_height,
      'lifestyle', COALESCE(b_lifestyle, '{}'::jsonb),
      'family', COALESCE(b_family, '{}'::jsonb),
      'religion', COALESCE(b_religion, '{}'::jsonb),
      'active_modes', COALESCE(to_jsonb(b_active_arr), '[]'::jsonb),
      'sub_intents', COALESCE(b_sub_intents, '{}'::jsonb),
      'interests', COALESCE(b_merged_interests, '{}'::jsonb),
      'intent_preferences', COALESCE(b_prefs, '{}'::jsonb)
    ),
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

-- ---------------------------------------------------------------------------
-- 3) Translations for Match Inspector (en / es / he)
-- ---------------------------------------------------------------------------
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminNavMatchInspector', $$Match Inspector$$),
  ('es', 'adminNavMatchInspector', $$Inspector de Matches$$),
  ('he', 'adminNavMatchInspector', $$בודק התאמות$$),

  ('en', 'matchInspectorTitle', $$Match Inspector$$),
  ('es', 'matchInspectorTitle', $$Inspector de Matches$$),
  ('he', 'matchInspectorTitle', $$בודק התאמות$$),

  ('en', 'matchInspectorSubtitle', $$Compare two users to see why they match or not.$$),
  ('es', 'matchInspectorSubtitle', $$Compara dos usuarios para ver por qué coinciden o no.$$),
  ('he', 'matchInspectorSubtitle', $$השוו שני משתמשים כדי לראות מדוע הם מתאימים או לא.$$),

  ('en', 'matchInspectorSelectA', $$First user$$),
  ('es', 'matchInspectorSelectA', $$Primer usuario$$),
  ('he', 'matchInspectorSelectA', $$משתמש ראשון$$),

  ('en', 'matchInspectorSelectB', $$Second user$$),
  ('es', 'matchInspectorSelectB', $$Segundo usuario$$),
  ('he', 'matchInspectorSelectB', $$משתמש שני$$),

  ('en', 'matchInspectorSearchHint', $$Search by name or ID...$$),
  ('es', 'matchInspectorSearchHint', $$Buscar por nombre o ID...$$),
  ('he', 'matchInspectorSearchHint', $$חיפוש לפי שם או מזהה...$$),

  ('en', 'matchInspectorCompareButton', $$Compare$$),
  ('es', 'matchInspectorCompareButton', $$Comparar$$),
  ('he', 'matchInspectorCompareButton', $$השווה$$),

  ('en', 'matchInspectorSwap', $$Swap$$),
  ('es', 'matchInspectorSwap', $$Intercambiar$$),
  ('he', 'matchInspectorSwap', $$החלף$$),

  ('en', 'matchInspectorClear', $$Clear$$),
  ('es', 'matchInspectorClear', $$Limpiar$$),
  ('he', 'matchInspectorClear', $$נקה$$),

  ('en', 'matchInspectorLoading', $$Analyzing...$$),
  ('es', 'matchInspectorLoading', $$Analizando...$$),
  ('he', 'matchInspectorLoading', $$מנתח...$$),

  ('en', 'matchInspectorSameUser', $$Please select two different users.$$),
  ('es', 'matchInspectorSameUser', $$Selecciona dos usuarios distintos.$$),
  ('he', 'matchInspectorSameUser', $$נא לבחור שני משתמשים שונים.$$),

  ('en', 'matchInspectorResultCompatible', $$These users are compatible$$),
  ('es', 'matchInspectorResultCompatible', $$Estos usuarios son compatibles$$),
  ('he', 'matchInspectorResultCompatible', $$המשתמשים האלה תואמים$$),

  ('en', 'matchInspectorResultNotCompatible', $$These users are not compatible$$),
  ('es', 'matchInspectorResultNotCompatible', $$Estos usuarios no son compatibles$$),
  ('he', 'matchInspectorResultNotCompatible', $$המשתמשים האלה אינם תואמים$$),

  ('en', 'matchInspectorAlreadyMatched', $$Already matched$$),
  ('es', 'matchInspectorAlreadyMatched', $$Ya coinciden$$),
  ('he', 'matchInspectorAlreadyMatched', $$כבר מותאמים$$),

  ('en', 'matchInspectorUnmatchedPair', $$Previously unmatched pair$$),
  ('es', 'matchInspectorUnmatchedPair', $$Pareja previamente descartada$$),
  ('he', 'matchInspectorUnmatchedPair', $$זוג שנפסל בעבר$$),

  ('en', 'matchInspectorReasonsHeader', $$Compatibility breakdown$$),
  ('es', 'matchInspectorReasonsHeader', $$Desglose de compatibilidad$$),
  ('he', 'matchInspectorReasonsHeader', $$פירוט תאימות$$),

  ('en', 'matchInspectorOverall', $$Overall$$),
  ('es', 'matchInspectorOverall', $$General$$),
  ('he', 'matchInspectorOverall', $$כללי$$),

  ('en', 'matchInspectorReasonSharedIntents', $$Shared intents$$),
  ('es', 'matchInspectorReasonSharedIntents', $$Intenciones compartidas$$),
  ('he', 'matchInspectorReasonSharedIntents', $$כוונות משותפות$$),

  ('en', 'matchInspectorReasonSubIntents', $$Sub-intents$$),
  ('es', 'matchInspectorReasonSubIntents', $$Sub-intenciones$$),
  ('he', 'matchInspectorReasonSubIntents', $$תת-כוונות$$),

  ('en', 'matchInspectorReasonGender', $$Gender preferences$$),
  ('es', 'matchInspectorReasonGender', $$Preferencias de género$$),
  ('he', 'matchInspectorReasonGender', $$העדפות מגדר$$),

  ('en', 'matchInspectorReasonAge', $$Age preferences$$),
  ('es', 'matchInspectorReasonAge', $$Preferencias de edad$$),
  ('he', 'matchInspectorReasonAge', $$העדפות גיל$$),

  ('en', 'matchInspectorReasonLifestyle', $$Lifestyle filters$$),
  ('es', 'matchInspectorReasonLifestyle', $$Filtros de estilo de vida$$),
  ('he', 'matchInspectorReasonLifestyle', $$מסנני סגנון חיים$$),

  ('en', 'matchInspectorReasonFamily', $$Family filters$$),
  ('es', 'matchInspectorReasonFamily', $$Filtros familiares$$),
  ('he', 'matchInspectorReasonFamily', $$מסננים משפחתיים$$),

  ('en', 'matchInspectorReasonReligion', $$Religion filters$$),
  ('es', 'matchInspectorReasonReligion', $$Filtros de religión$$),
  ('he', 'matchInspectorReasonReligion', $$מסנני דת$$),

  ('en', 'matchInspectorReasonHeight', $$Height filters$$),
  ('es', 'matchInspectorReasonHeight', $$Filtros de altura$$),
  ('he', 'matchInspectorReasonHeight', $$מסנני גובה$$),

  ('en', 'matchInspectorReasonInterests', $$Interests$$),
  ('es', 'matchInspectorReasonInterests', $$Intereses$$),
  ('he', 'matchInspectorReasonInterests', $$תחומי עניין$$),

  ('en', 'matchInspectorReasonFilters', $$Other filters$$),
  ('es', 'matchInspectorReasonFilters', $$Otros filtros$$),
  ('he', 'matchInspectorReasonFilters', $$מסננים אחרים$$),

  ('en', 'matchInspectorUserA', $$User A$$),
  ('es', 'matchInspectorUserA', $$Usuario A$$),
  ('he', 'matchInspectorUserA', $$משתמש א'$$),

  ('en', 'matchInspectorUserB', $$User B$$),
  ('es', 'matchInspectorUserB', $$Usuario B$$),
  ('he', 'matchInspectorUserB', $$משתמש ב'$$),

  ('en', 'matchInspectorNoSharedIntents', $$No shared intents — users have no active mode in common.$$),
  ('es', 'matchInspectorNoSharedIntents', $$Sin intenciones compartidas — no hay modo activo en común.$$),
  ('he', 'matchInspectorNoSharedIntents', $$אין כוונות משותפות — אין מצב פעיל משותף.$$),

  ('en', 'matchInspectorCompatibleIntents', $$Compatible on: {intents}$$),
  ('es', 'matchInspectorCompatibleIntents', $$Compatible en: {intents}$$),
  ('he', 'matchInspectorCompatibleIntents', $$תואם ב: {intents}$$),

  ('en', 'matchInspectorNoCompatibleIntents', $$No compatible intents — at least one requirement fails for every shared intent.$$),
  ('es', 'matchInspectorNoCompatibleIntents', $$Ninguna intención compatible — al menos un requisito falla en cada intención compartida.$$),
  ('he', 'matchInspectorNoCompatibleIntents', $$אין כוונות תואמות — לפחות דרישה אחת נכשלת בכל כוונה משותפת.$$),

  ('en', 'matchInspectorPass', $$Passed$$),
  ('es', 'matchInspectorPass', $$Aprobado$$),
  ('he', 'matchInspectorPass', $$עבר$$),

  ('en', 'matchInspectorFail', $$Failed$$),
  ('es', 'matchInspectorFail', $$Falló$$),
  ('he', 'matchInspectorFail', $$נכשל$$),

  ('en', 'matchInspectorErrorLoadFailed', $$Failed to compare users: {error}$$),
  ('es', 'matchInspectorErrorLoadFailed', $$Error al comparar usuarios: {error}$$),
  ('he', 'matchInspectorErrorLoadFailed', $$השוואת המשתמשים נכשלה: {error}$$),

  ('en', 'matchInspectorSearchNoResults', $$No users found.$$),
  ('es', 'matchInspectorSearchNoResults', $$No se encontraron usuarios.$$),
  ('he', 'matchInspectorSearchNoResults', $$לא נמצאו משתמשים.$$),

  ('en', 'matchInspectorSelectHint', $$Choose two users to compare.$$),
  ('es', 'matchInspectorSelectHint', $$Elige dos usuarios para comparar.$$),
  ('he', 'matchInspectorSelectHint', $$בחרו שני משתמשים להשוואה.$$),

  ('en', 'matchInspectorDetails', $$Details$$),
  ('es', 'matchInspectorDetails', $$Detalles$$),
  ('he', 'matchInspectorDetails', $$פרטים$$),

  ('en', 'matchInspectorValues', $$Values$$),
  ('es', 'matchInspectorValues', $$Valores$$),
  ('he', 'matchInspectorValues', $$ערכים$$),

  ('en', 'matchInspectorAValue', $$User A: {value}$$),
  ('es', 'matchInspectorAValue', $$Usuario A: {value}$$),
  ('he', 'matchInspectorAValue', $$משתמש א': {value}$$),

  ('en', 'matchInspectorBValue', $$User B: {value}$$),
  ('es', 'matchInspectorBValue', $$Usuario B: {value}$$),
  ('he', 'matchInspectorBValue', $$משתמש ב': {value}$$),

  ('en', 'matchInspectorOverlap', $$Overlap: {value}$$),
  ('es', 'matchInspectorOverlap', $$Coincidencia: {value}$$),
  ('he', 'matchInspectorOverlap', $$חפיפה: {value}$$),

  ('en', 'matchInspectorEmpty', $$Empty$$),
  ('es', 'matchInspectorEmpty', $$Vacío$$),
  ('he', 'matchInspectorEmpty', $$ריק$$),

  ('en', 'matchInspectorNotSet', $$Not set$$),
  ('es', 'matchInspectorNotSet', $$No configurado$$),
  ('he', 'matchInspectorNotSet', $$לא הוגדר$$),

  ('en', 'matchInspectorPerIntentHeader', $$Per-intent analysis$$),
  ('es', 'matchInspectorPerIntentHeader', $$Análisis por intención$$),
  ('he', 'matchInspectorPerIntentHeader', $$ניתוח לפי כוונה$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
