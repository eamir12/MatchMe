-- Migration: Restructure user_profiles to single-row-per-user schema
-- Date: 2026-07-10 (rewritten)
--
-- This migration:
--   1. Restructures user_profiles from multi-row (one per intent_type) to single-row per user
--   2. Moves profile columns from users table to user_profiles
--   3. Consolidates per-intent preferences into intent_preferences JSONB
--   4. Removes strict_gender_age_enforcement entirely
--   5. Rewrites all matching functions for the new schema

BEGIN;

-- ============================================================
-- STEP 0: Helper function – merge two interest maps (union of arrays per key)
-- ============================================================
DROP FUNCTION IF EXISTS public.merge_interest_maps(jsonb, jsonb);
CREATE OR REPLACE FUNCTION public.merge_interest_maps(a jsonb, b jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  result jsonb := COALESCE(a, '{}'::jsonb);
  key    text;
BEGIN
  IF b IS NULL OR b = '{}'::jsonb THEN
    RETURN result;
  END IF;

  FOR key IN SELECT jsonb_object_keys(b)
  LOOP
    IF result ? key THEN
      result := result || jsonb_build_object(
        key,
        (
          SELECT COALESCE(jsonb_agg(DISTINCT v ORDER BY v), '[]'::jsonb)
          FROM (
            SELECT jsonb_array_elements_text(result -> key) AS v
            UNION
            SELECT jsonb_array_elements_text(b     -> key) AS v
          ) sub
        )
      );
    ELSE
      result := result || jsonb_build_object(key, b -> key);
    END IF;
  END LOOP;

  RETURN result;
END;
$$;

-- ============================================================
-- STEP 1: Add new columns to user_profiles
-- ============================================================
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS bio text;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS photos jsonb DEFAULT '[]'::jsonb;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS approved_primary_photos jsonb DEFAULT '[]'::jsonb;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS height integer;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS occupation text;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS education text;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS zodiac_sign text;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS lifestyle jsonb;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS family jsonb;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS religion jsonb;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS languages_known jsonb DEFAULT '{}'::jsonb;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS instagram_url text;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS linkedin_url text;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS facebook_url text;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS active_modes jsonb DEFAULT '[]'::jsonb;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS sub_intents jsonb DEFAULT '{}'::jsonb;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS personal_interests jsonb DEFAULT '{}'::jsonb;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS business_interests jsonb DEFAULT '{}'::jsonb;
-- intent_preferences stores the merged per-intent filter/preference maps:
-- { "gender_preferences": {"Romantic": [...], ...},
--   "age_preferences": {"Romantic": [...], ...},
--   "lifestyle_filters": {"Romantic": {...}, ...},
--   "family_filters": {"Romantic": {...}, ...},
--   "religion_filters": {"Romantic": {...}, ...},
--   "height_preferences": {"Romantic": {...}, ...} }
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS intent_preferences jsonb DEFAULT '{}'::jsonb;

-- ============================================================
-- STEP 2: Helper function – build intent_preferences JSONB
--         Merges the 6 separate per-intent preference maps from users
--         into a single JSONB column on user_profiles.
-- ============================================================
DROP FUNCTION IF EXISTS public.build_intent_preferences(uuid);
CREATE OR REPLACE FUNCTION public.build_intent_preferences(uid uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'gender_preferences',  COALESCE(u.gender_preferences, '{}'::jsonb),
    'age_preferences',     COALESCE(u.age_preferences, '{}'::jsonb),
    'lifestyle_filters',   COALESCE(u.lifestyle_filters, '{}'::jsonb),
    'family_filters',      COALESCE(u.family_filters, '{}'::jsonb),
    'religion_filters',    COALESCE(u.religion_filters, '{}'::jsonb),
    'height_preferences',  COALESCE(u.height_preferences, '{}'::jsonb)
  ) INTO result
  FROM users u
  WHERE u.id = uid;

  RETURN COALESCE(result, '{}'::jsonb);
END;
$$;

-- ============================================================
-- STEP 3: Helper function – aggregate sub_intents from user_profiles
--         profile_data rows into a single JSONB object keyed by intent_type.
-- ============================================================
DROP FUNCTION IF EXISTS public.build_sub_intents(uuid);
CREATE OR REPLACE FUNCTION public.build_sub_intents(uid uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT COALESCE(
    jsonb_object_agg(
      intent_type,
      profile_data -> 'sub_intent'
    ) FILTER (WHERE profile_data ? 'sub_intent'),
    '{}'::jsonb
  ) INTO result
  FROM user_profiles
  WHERE user_id = uid
    AND profile_data ? 'sub_intent';

  RETURN COALESCE(result, '{}'::jsonb);
END;
$$;

-- ============================================================
-- STEP 3a.5: Add personal_interests / business_interests to users
--            so STEP 3b can use them as an intermediate scratchpad.
--            These are dropped in STEP 8.
-- ============================================================
ALTER TABLE users ADD COLUMN IF NOT EXISTS personal_interests jsonb DEFAULT '{}'::jsonb;
ALTER TABLE users ADD COLUMN IF NOT EXISTS business_interests jsonb DEFAULT '{}'::jsonb;

-- ============================================================
-- STEP 3b: Reconcile interests from profile_data->'interests'
--          The old matching functions read interests from
--          user_profiles.profile_data->'interests', not from
--          users.personal_interests/business_interests. This step
--          ensures those columns are populated before STEP 4
--          copies them to the new user_profiles rows.
-- ============================================================
DO $$
DECLARE
  rec record;
  ie record;
  aggregated_interests jsonb;
  existing_personal jsonb;
  existing_business jsonb;
BEGIN
  FOR rec IN
    SELECT DISTINCT up.user_id
    FROM user_profiles up
    WHERE up.profile_data ? 'interests'
  LOOP
    -- Accumulate interests from all per-intent profile_data rows
    aggregated_interests := '{}'::jsonb;
    FOR ie IN
      SELECT up2.profile_data->'interests' AS interests
      FROM user_profiles up2
      WHERE up2.user_id = rec.user_id
        AND up2.profile_data ? 'interests'
        AND up2.profile_data->'interests' != '{}'::jsonb
    LOOP
      aggregated_interests := public.merge_interest_maps(aggregated_interests, ie.interests);
    END LOOP;

    IF aggregated_interests = '{}'::jsonb THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(personal_interests, '{}'::jsonb),
           COALESCE(business_interests, '{}'::jsonb)
    INTO existing_personal, existing_business
    FROM users WHERE id = rec.user_id;

    -- If both are empty, put aggregated interests into personal_interests
    IF existing_personal = '{}'::jsonb AND existing_business = '{}'::jsonb THEN
      UPDATE users SET personal_interests = aggregated_interests WHERE id = rec.user_id;
    ELSIF existing_personal = '{}'::jsonb THEN
      UPDATE users SET personal_interests = aggregated_interests WHERE id = rec.user_id;
    END IF;
  END LOOP;
END $$;

-- ============================================================
-- STEP 4: Populate the new user_profiles columns from existing data
-- ============================================================
DO $$
DECLARE
  rec record;
  existing_intent_type text;
BEGIN
  FOR rec IN SELECT DISTINCT user_id FROM user_profiles LOOP
    SELECT intent_type INTO existing_intent_type
    FROM user_profiles
    WHERE user_id = rec.user_id
    ORDER BY created_at ASC
    LIMIT 1;

    UPDATE user_profiles SET
      bio = u.bio,
      photos = COALESCE(to_jsonb(u.photos), '[]'::jsonb),
      approved_primary_photos = COALESCE(to_jsonb(u.approved_primary_photos), '[]'::jsonb),
      height = u.height,
      occupation = u.occupation,
      education = u.education,
      zodiac_sign = u.zodiac_sign,
      lifestyle = u.lifestyle,
      family = u.family,
      religion = u.religion,
      languages_known = COALESCE(to_jsonb(u.languages_known), '{}'::jsonb),
      instagram_url = u.instagram_url,
      linkedin_url = u.linkedin_url,
      facebook_url = u.facebook_url,
      active_modes = COALESCE(to_jsonb(u.active_modes), '[]'::jsonb),
      sub_intents = public.build_sub_intents(rec.user_id),
      personal_interests = COALESCE(u.personal_interests, '{}'::jsonb),
      business_interests = COALESCE(u.business_interests, '{}'::jsonb),
      intent_preferences = public.build_intent_preferences(rec.user_id),
      updated_at = now()
    FROM users u
    WHERE u.id = rec.user_id
      AND user_profiles.user_id = rec.user_id
      AND user_profiles.intent_type = existing_intent_type;

    DELETE FROM user_profiles
    WHERE user_id = rec.user_id AND intent_type != existing_intent_type;
  END LOOP;

  -- Handle users who have NO user_profiles rows yet
  FOR rec IN
    SELECT u.id AS user_id
    FROM users u
    WHERE NOT EXISTS (SELECT 1 FROM user_profiles up WHERE up.user_id = u.id)
  LOOP
    INSERT INTO user_profiles (
      user_id, bio, photos, approved_primary_photos, height, occupation,
      education, zodiac_sign, lifestyle, family, religion, languages_known,
      instagram_url, linkedin_url, facebook_url, active_modes, sub_intents,
      personal_interests, business_interests, intent_preferences,
      created_at, updated_at
    )
    SELECT
      u.id,
      u.bio,
      COALESCE(to_jsonb(u.photos), '[]'::jsonb),
      COALESCE(to_jsonb(u.approved_primary_photos), '[]'::jsonb),
      u.height,
      u.occupation,
      u.education,
      u.zodiac_sign,
      u.lifestyle,
      u.family,
      u.religion,
      COALESCE(to_jsonb(u.languages_known), '{}'::jsonb),
      u.instagram_url,
      u.linkedin_url,
      u.facebook_url,
      COALESCE(to_jsonb(u.active_modes), '[]'::jsonb),
      '{}'::jsonb,
      COALESCE(u.personal_interests, '{}'::jsonb),
      COALESCE(u.business_interests, '{}'::jsonb),
      public.build_intent_preferences(u.id),
      COALESCE(u.created_at, now()),
      now()
    FROM users u
    WHERE u.id = rec.user_id;
  END LOOP;
END $$;

-- ============================================================
-- STEP 5: Drop helper functions
-- ============================================================
DROP FUNCTION IF EXISTS public.build_intent_preferences(uuid);
DROP FUNCTION IF EXISTS public.build_sub_intents(uuid);

-- ============================================================
-- STEP 6: Drop old constraints and set new primary key
-- ============================================================
DO $$
DECLARE
  constraint_rec record;
BEGIN
  FOR constraint_rec IN
    SELECT conname, contype
    FROM pg_constraint
    WHERE conrelid = 'public.user_profiles'::regclass
      AND contype IN ('p', 'u')
  LOOP
    EXECUTE 'ALTER TABLE public.user_profiles DROP CONSTRAINT IF EXISTS ' || quote_ident(constraint_rec.conname);
  END LOOP;
END $$;

ALTER TABLE public.user_profiles ADD PRIMARY KEY (user_id);

-- Drop the old auto-generated id column (no longer needed with user_id as PK)
ALTER TABLE public.user_profiles DROP COLUMN IF EXISTS id;

-- ============================================================
-- STEP 7: Drop old columns from user_profiles
-- ============================================================
ALTER TABLE public.user_profiles DROP COLUMN IF EXISTS intent_type;
ALTER TABLE public.user_profiles DROP COLUMN IF EXISTS profile_data;

-- Drop the 4-parameter is_compliant_candidate overload that reads
-- gender_preferences/age_preferences from users (both dropped in STEP 8).
-- The 5-parameter version (used by matching functions) receives values as args.
DROP FUNCTION IF EXISTS public.is_compliant_candidate(UUID, TEXT, DATE, TEXT);

-- ============================================================
-- STEP 8: Drop columns from users table (moved to user_profiles)
-- ============================================================
ALTER TABLE public.users DROP COLUMN IF EXISTS bio;
ALTER TABLE public.users DROP COLUMN IF EXISTS photos;
ALTER TABLE public.users DROP COLUMN IF EXISTS approved_primary_photos;
ALTER TABLE public.users DROP COLUMN IF EXISTS height;
ALTER TABLE public.users DROP COLUMN IF EXISTS occupation;
ALTER TABLE public.users DROP COLUMN IF EXISTS education;
ALTER TABLE public.users DROP COLUMN IF EXISTS zodiac_sign;
ALTER TABLE public.users DROP COLUMN IF EXISTS lifestyle;
ALTER TABLE public.users DROP COLUMN IF EXISTS family;
ALTER TABLE public.users DROP COLUMN IF EXISTS religion;
ALTER TABLE public.users DROP COLUMN IF EXISTS languages_known;
ALTER TABLE public.users DROP COLUMN IF EXISTS instagram_url;
ALTER TABLE public.users DROP COLUMN IF EXISTS linkedin_url;
ALTER TABLE public.users DROP COLUMN IF EXISTS facebook_url;
ALTER TABLE public.users DROP COLUMN IF EXISTS active_modes;
ALTER TABLE public.users DROP COLUMN IF EXISTS personal_interests;
ALTER TABLE public.users DROP COLUMN IF EXISTS business_interests;
ALTER TABLE public.users DROP COLUMN IF EXISTS gender_preferences;
ALTER TABLE public.users DROP COLUMN IF EXISTS age_preferences;
ALTER TABLE public.users DROP COLUMN IF EXISTS lifestyle_filters;
ALTER TABLE public.users DROP COLUMN IF EXISTS family_filters;
ALTER TABLE public.users DROP COLUMN IF EXISTS religion_filters;
ALTER TABLE public.users DROP COLUMN IF EXISTS height_preferences;
ALTER TABLE public.users DROP COLUMN IF EXISTS strict_gender_age_enforcement;

-- ============================================================
-- STEP 9: Drop the interest validation trigger (no longer relevant)
-- ============================================================
DROP TRIGGER IF EXISTS trg_validate_interests ON public.user_profiles;
DROP FUNCTION IF EXISTS public.validate_interest_no_self_reference();

-- ============================================================
-- STEP 10: Rewrite perform_continuous_user_matching
--          All data now comes from:
--            users:       identity (gender, dob, visibility, matching config)
--            user_profiles: profile details, sub_intents, interests, preferences
-- ============================================================
DROP FUNCTION IF EXISTS public.perform_continuous_user_matching();
CREATE OR REPLACE FUNCTION public.perform_continuous_user_matching()
RETURNS TABLE (
    users_processed INTEGER,
    matches_created INTEGER,
    status TEXT
)
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
BEGIN
    SET search_path = 'public';

    FOR user_record IN
        SELECT
            ul.user_id, ul.latitude, ul.longitude,
            u.match_radius_default,
            COALESCE(u.user_visibility_setting,false) AS user_visibility_setting,
            COALESCE(u.system_visibility_status,'visible') AS system_visibility_status
        FROM user_locations ul
        INNER JOIN users u ON ul.user_id = u.id
        WHERE (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE)
          AND COALESCE(u.user_visibility_setting,false) = TRUE
          AND COALESCE(u.system_visibility_status,'visible') = 'visible')
        AND ul.updated_at >= NOW() - INTERVAL '5 minutes'
        ORDER BY ul.updated_at DESC
    LOOP
        total_users_processed := total_users_processed + 1;

        SELECT gender, date_of_birth INTO current_user_gender, current_user_dob
        FROM users WHERE id = user_record.user_id;

        IF current_user_dob IS NOT NULL THEN
            current_user_age := EXTRACT(YEAR FROM AGE(current_user_dob));
        ELSE
            current_user_age := NULL;
        END IF;

        SELECT lifestyle, family, religion, height,
               ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)),
               public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb)),
               intent_preferences
        INTO current_user_lifestyle, current_user_family, current_user_religion,
             current_user_height, current_user_intents,
             current_user_interests, current_user_prefs
        FROM user_profiles WHERE user_id = user_record.user_id;

        IF current_user_intents IS NULL THEN CONTINUE; END IF;

        FOR nearby_user_record IN
            SELECT * FROM find_nearby_users(
                user_record.user_id, user_record.latitude, user_record.longitude,
                (user_record.match_radius_default / 1000.0)::DOUBLE PRECISION
            )
        LOOP
            IF EXISTS (
                SELECT 1 FROM matches
                WHERE (user1_id = user_record.user_id AND user2_id = nearby_user_record.user_id)
                   OR (user1_id = nearby_user_record.user_id AND user2_id = user_record.user_id)
            ) THEN
                CONTINUE;
            END IF;

            SELECT gender, date_of_birth INTO other_user_gender, other_user_dob
            FROM users
            WHERE id = nearby_user_record.user_id
              AND (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
                AND COALESCE(user_visibility_setting,false) = TRUE
                AND COALESCE(system_visibility_status,'visible') = 'visible');

            IF other_user_gender IS NULL THEN CONTINUE; END IF;

            IF other_user_dob IS NOT NULL THEN
                other_user_age := EXTRACT(YEAR FROM AGE(other_user_dob));
            ELSE
                other_user_age := NULL;
            END IF;

            SELECT lifestyle, family, religion, height,
                   ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)),
                   public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb)),
                   intent_preferences
            INTO other_user_lifestyle, other_user_family, other_user_religion,
                 other_user_height, other_user_intents,
                 other_user_interests, other_user_prefs
            FROM user_profiles WHERE user_id = nearby_user_record.user_id;

            IF other_user_intents IS NULL OR array_length(other_user_intents, 1) = 0 THEN
                CONTINUE;
            END IF;

            SELECT ARRAY(
                SELECT intent
                FROM unnest(current_user_intents) as t(intent)
                WHERE intent = ANY(other_user_intents)
            ) INTO shared_intents;

            IF array_length(shared_intents, 1) IS NULL OR array_length(shared_intents, 1) = 0 THEN
                CONTINUE;
            END IF;

            matched_intent_result := NULL;

            <<intent_loop>>
            FOREACH shared_intent IN ARRAY shared_intents LOOP

                -- CRITERION 1: Sub-intent overlap
                current_sub_intents_arr := ARRAY(
                    SELECT jsonb_array_elements_text(
                      COALESCE((SELECT up.sub_intents -> shared_intent FROM user_profiles up WHERE up.user_id = user_record.user_id), '[]'::jsonb)
                    )
                );

                other_sub_intents_arr := ARRAY(
                    SELECT jsonb_array_elements_text(
                      COALESCE((SELECT up.sub_intents -> shared_intent FROM user_profiles up WHERE up.user_id = nearby_user_record.user_id), '[]'::jsonb)
                    )
                );

                IF array_length(current_sub_intents_arr, 1) IS NULL
                   OR array_length(other_sub_intents_arr, 1) IS NULL THEN
                    CONTINUE intent_loop;
                END IF;

                IF NOT (current_sub_intents_arr && other_sub_intents_arr) THEN
                    CONTINUE intent_loop;
                END IF;

                -- CRITERION 2: Gender preferences
                a_gender_ok := (
                    NOT ((other_user_prefs -> 'gender_preferences') ? shared_intent)
                    OR ((other_user_prefs -> 'gender_preferences') -> shared_intent) ? current_user_gender
                );
                b_gender_ok := (
                    NOT ((current_user_prefs -> 'gender_preferences') ? shared_intent)
                    OR ((current_user_prefs -> 'gender_preferences') -> shared_intent) ? other_user_gender
                );

                IF NOT a_gender_ok OR NOT b_gender_ok THEN
                    CONTINUE intent_loop;
                END IF;

                -- CRITERION 2b: Age preferences
                a_age_ok := (
                    NOT ((other_user_prefs -> 'age_preferences') ? shared_intent)
                    OR current_user_age IS NULL
                    OR (
                        jsonb_array_length((other_user_prefs -> 'age_preferences') -> shared_intent) >= 2
                        AND current_user_age >= ((other_user_prefs -> 'age_preferences') -> shared_intent ->> 0)::numeric
                        AND current_user_age <= ((other_user_prefs -> 'age_preferences') -> shared_intent ->> 1)::numeric
                    )
                );
                b_age_ok := (
                    NOT ((current_user_prefs -> 'age_preferences') ? shared_intent)
                    OR other_user_age IS NULL
                    OR (
                        jsonb_array_length((current_user_prefs -> 'age_preferences') -> shared_intent) >= 2
                        AND other_user_age >= ((current_user_prefs -> 'age_preferences') -> shared_intent ->> 0)::numeric
                        AND other_user_age <= ((current_user_prefs -> 'age_preferences') -> shared_intent ->> 1)::numeric
                    )
                );

                IF NOT a_age_ok OR NOT b_age_ok THEN
                    CONTINUE intent_loop;
                END IF;

                -- CRITERION 2c: Lifestyle/family/religion/height filter compatibility
                filters_compatible := public.are_filters_compatible(
                    current_user_lifestyle, current_user_family,
                    current_user_religion, current_user_height,
                    other_user_lifestyle, other_user_family,
                    other_user_religion, other_user_height,
                    (other_user_prefs -> 'lifestyle_filters'), (other_user_prefs -> 'family_filters'),
                    (other_user_prefs -> 'religion_filters'), (other_user_prefs -> 'height_preferences'),
                    (current_user_prefs -> 'lifestyle_filters'), (current_user_prefs -> 'family_filters'),
                    (current_user_prefs -> 'religion_filters'), (current_user_prefs -> 'height_preferences'),
                    shared_intent
                );

                IF NOT filters_compatible THEN
                    CONTINUE intent_loop;
                END IF;

                -- CRITERION 3+4: Interest overlap
                IF current_user_interests IS NULL OR other_user_interests IS NULL
                   OR current_user_interests = '{}'::jsonb OR other_user_interests = '{}'::jsonb THEN
                    CONTINUE intent_loop;
                END IF;

                IF NOT EXISTS (
                    SELECT 1
                    FROM jsonb_object_keys(current_user_interests) AS cat
                    WHERE current_user_interests ? cat AND other_user_interests ? cat
                      AND jsonb_array_length(current_user_interests->cat) > 0
                      AND jsonb_array_length(other_user_interests->cat) > 0
                      AND EXISTS (
                          SELECT 1
                          FROM jsonb_array_elements_text(current_user_interests->cat) AS sub
                          WHERE sub = ANY(SELECT jsonb_array_elements_text(other_user_interests->cat))
                      )
                ) THEN
                    CONTINUE intent_loop;
                END IF;

                matched_intent_result := shared_intent;
                EXIT intent_loop;

            END LOOP intent_loop;

            IF matched_intent_result IS NOT NULL THEN
                INSERT INTO matches (user1_id, user2_id, matched_intent, match_type, created_at)
                VALUES (
                    LEAST(user_record.user_id, nearby_user_record.user_id),
                    GREATEST(user_record.user_id, nearby_user_record.user_id),
                    matched_intent_result, 'proximity', NOW()
                );
                total_matches_created := total_matches_created + 1;
            END IF;

        END LOOP;
    END LOOP;

    RETURN QUERY SELECT total_users_processed, total_matches_created, 'completed'::TEXT;
END;
$_$;

GRANT EXECUTE ON FUNCTION perform_continuous_user_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION perform_continuous_user_matching() TO anon;

-- ============================================================
-- STEP 11: Rewrite perform_event_matching
-- ============================================================
DROP FUNCTION IF EXISTS public.perform_event_matching(uuid);
CREATE OR REPLACE FUNCTION public.perform_event_matching(p_event_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $_$
DECLARE
    event_attendee RECORD;
    other_attendee RECORD;
    attendee_a_id UUID;
    attendee_b_id UUID;
    existing_match_id UUID;
    shared_intents TEXT[];
    has_matching_sub_intent BOOLEAN := FALSE;
    shared_intent TEXT;
    pair_allowed BOOLEAN := FALSE;
    a_has_compliant BOOLEAN;
    b_has_compliant BOOLEAN;
    has_shared_interest BOOLEAN := FALSE;
    shared_interest_category TEXT;
    -- User A data
    a_gender TEXT;
    a_dob DATE;
    a_age INTEGER;
    a_enabled BOOLEAN;
    a_active TEXT[];
    a_interests JSONB;
    a_lifestyle JSONB;
    a_family JSONB;
    a_religion JSONB;
    a_height INTEGER;
    a_prefs JSONB;
    -- User B data
    b_gender TEXT;
    b_dob DATE;
    b_age INTEGER;
    b_enabled BOOLEAN;
    b_active TEXT[];
    b_interests JSONB;
    b_lifestyle JSONB;
    b_family JSONB;
    b_religion JSONB;
    b_height INTEGER;
    b_prefs JSONB;
    -- Per-intent vars
    a_gender_ok BOOLEAN;
    a_age_ok BOOLEAN;
    b_gender_ok BOOLEAN;
    b_age_ok BOOLEAN;
    filters_compatible BOOLEAN;
    a_sub JSONB;
    b_sub JSONB;
BEGIN
    SET search_path = 'public';

    FOR event_attendee IN
        SELECT DISTINCT ea.user_id FROM event_attendees ea WHERE ea.event_id = p_event_id
    LOOP
        attendee_a_id := event_attendee.user_id;

        SELECT gender, date_of_birth, shared_event_matching_enabled
        INTO a_gender, a_dob, a_enabled
        FROM users WHERE id = attendee_a_id;

        IF a_enabled IS NULL OR NOT a_enabled THEN CONTINUE; END IF;
        IF a_dob IS NOT NULL THEN a_age := EXTRACT(YEAR FROM AGE(a_dob)); ELSE a_age := NULL; END IF;

        SELECT lifestyle, family, religion, height,
               ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)),
               public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb)),
               intent_preferences
        INTO a_lifestyle, a_family, a_religion, a_height, a_active,
             a_interests, a_prefs
        FROM user_profiles WHERE user_id = attendee_a_id;

        IF a_active IS NULL OR array_length(a_active, 1) IS NULL THEN CONTINUE; END IF;
        a_interests := COALESCE(a_interests, '{}'::jsonb);

        FOR other_attendee IN
            SELECT DISTINCT ea2.user_id FROM event_attendees ea2
            WHERE ea2.event_id = p_event_id AND ea2.user_id != attendee_a_id
        LOOP
            attendee_b_id := other_attendee.user_id;
            IF attendee_a_id >= attendee_b_id THEN CONTINUE; END IF;

            IF EXISTS (
                SELECT 1 FROM public.unmatched_pairs up
                WHERE up.user1_id = attendee_a_id AND up.user2_id = attendee_b_id
            ) THEN CONTINUE; END IF;

            SELECT id INTO existing_match_id FROM matches
            WHERE (user1_id = attendee_a_id AND user2_id = attendee_b_id)
               OR (user1_id = attendee_b_id AND user2_id = attendee_a_id)
            LIMIT 1;
            IF existing_match_id IS NOT NULL THEN CONTINUE; END IF;

            SELECT gender, date_of_birth, shared_event_matching_enabled
            INTO b_gender, b_dob, b_enabled
            FROM users WHERE id = attendee_b_id;

            IF b_enabled IS NULL OR NOT b_enabled THEN CONTINUE; END IF;
            IF b_dob IS NOT NULL THEN b_age := EXTRACT(YEAR FROM AGE(b_dob)); ELSE b_age := NULL; END IF;

            SELECT lifestyle, family, religion, height,
                   ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)),
                   public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb)),
                   intent_preferences
            INTO b_lifestyle, b_family, b_religion, b_height, b_active,
                 b_interests, b_prefs
            FROM user_profiles WHERE user_id = attendee_b_id;

            IF b_active IS NULL OR array_length(b_active, 1) IS NULL THEN CONTINUE; END IF;
            b_interests := COALESCE(b_interests, '{}'::jsonb);

            SELECT ARRAY(
                SELECT intent FROM unnest(a_active) AS t(intent) WHERE intent = ANY(b_active)
            ) INTO shared_intents;

            IF shared_intents IS NULL OR array_length(shared_intents, 1) IS NULL THEN CONTINUE; END IF;

            -- Check shared sub-intents
            has_matching_sub_intent := FALSE;
            <<sub_intent_loop>>
            FOREACH shared_intent IN ARRAY shared_intents LOOP
                a_sub := COALESCE((SELECT up.sub_intents -> shared_intent FROM user_profiles up WHERE up.user_id = attendee_a_id), '[]'::jsonb);
                b_sub := COALESCE((SELECT up.sub_intents -> shared_intent FROM user_profiles up WHERE up.user_id = attendee_b_id), '[]'::jsonb);

                IF jsonb_array_length(a_sub) = 0 OR jsonb_array_length(b_sub) = 0 THEN
                    has_matching_sub_intent := TRUE;
                    EXIT sub_intent_loop;
                END IF;

                IF (
                    SELECT count(*) FROM jsonb_array_elements_text(a_sub) va
                    WHERE va IN (SELECT jsonb_array_elements_text(b_sub))
                ) > 0 THEN
                    has_matching_sub_intent := TRUE;
                    EXIT sub_intent_loop;
                END IF;
            END LOOP sub_intent_loop;

            IF NOT has_matching_sub_intent THEN CONTINUE; END IF;

            -- Per-intent enforcement check (no more strict_gender_age_enforcement)
            pair_allowed := FALSE;
            <<intent_enforcement_loop>>
            FOREACH shared_intent IN ARRAY shared_intents LOOP
                a_gender_ok := (
                    NOT ((b_prefs -> 'gender_preferences') ? shared_intent)
                    OR ((b_prefs -> 'gender_preferences') -> shared_intent) ? a_gender
                );
                a_age_ok := (
                    NOT ((b_prefs -> 'age_preferences') ? shared_intent)
                    OR a_age IS NULL
                    OR (
                        jsonb_array_length((b_prefs -> 'age_preferences') -> shared_intent) >= 2
                        AND a_age >= ((b_prefs -> 'age_preferences') -> shared_intent ->> 0)::numeric
                        AND a_age <= ((b_prefs -> 'age_preferences') -> shared_intent ->> 1)::numeric
                    )
                );
                b_gender_ok := (
                    NOT ((a_prefs -> 'gender_preferences') ? shared_intent)
                    OR ((a_prefs -> 'gender_preferences') -> shared_intent) ? b_gender
                );
                b_age_ok := (
                    NOT ((a_prefs -> 'age_preferences') ? shared_intent)
                    OR b_age IS NULL
                    OR (
                        jsonb_array_length((a_prefs -> 'age_preferences') -> shared_intent) >= 2
                        AND b_age >= ((a_prefs -> 'age_preferences') -> shared_intent ->> 0)::numeric
                        AND b_age <= ((a_prefs -> 'age_preferences') -> shared_intent ->> 1)::numeric
                    )
                );

                filters_compatible := public.are_filters_compatible(
                    a_lifestyle, a_family, a_religion, a_height,
                    b_lifestyle, b_family, b_religion, b_height,
                    (b_prefs -> 'lifestyle_filters'), (b_prefs -> 'family_filters'),
                    (b_prefs -> 'religion_filters'), (b_prefs -> 'height_preferences'),
                    (a_prefs -> 'lifestyle_filters'), (a_prefs -> 'family_filters'),
                    (a_prefs -> 'religion_filters'), (a_prefs -> 'height_preferences'),
                    shared_intent
                );

                IF a_gender_ok AND a_age_ok AND b_gender_ok AND b_age_ok AND filters_compatible THEN
                    pair_allowed := TRUE;
                    EXIT intent_enforcement_loop;
                END IF;

                -- Flexible match check
                SELECT EXISTS (
                    SELECT 1 FROM event_attendees ea
                    INNER JOIN users u2 ON u2.id = ea.user_id
                    WHERE ea.event_id = p_event_id
                      AND ea.user_id <> attendee_b_id
                      AND ea.user_id <> attendee_a_id
                      AND public.is_compliant_candidate(
                          (a_prefs -> 'gender_preferences'), (a_prefs -> 'age_preferences'),
                          u2.gender, u2.date_of_birth, shared_intent
                      )
                ) INTO a_has_compliant;

                SELECT EXISTS (
                    SELECT 1 FROM event_attendees ea
                    INNER JOIN users u2 ON u2.id = ea.user_id
                    WHERE ea.event_id = p_event_id
                      AND ea.user_id <> attendee_a_id
                      AND ea.user_id <> attendee_b_id
                      AND public.is_compliant_candidate(
                          (b_prefs -> 'gender_preferences'), (b_prefs -> 'age_preferences'),
                          u2.gender, u2.date_of_birth, shared_intent
                      )
                ) INTO b_has_compliant;

                IF NOT a_has_compliant AND NOT b_has_compliant THEN
                    pair_allowed := TRUE;
                    EXIT intent_enforcement_loop;
                END IF;
            END LOOP intent_enforcement_loop;

            IF NOT pair_allowed THEN CONTINUE; END IF;

            -- Interest overlap check
            has_shared_interest := FALSE;
            FOR shared_interest_category IN SELECT jsonb_object_keys(a_interests) LOOP
                IF a_interests ? shared_interest_category AND b_interests ? shared_interest_category THEN
                    IF EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(a_interests -> shared_interest_category) AS ia
                        WHERE ia = ANY(SELECT jsonb_array_elements_text(b_interests -> shared_interest_category))
                    ) THEN
                        has_shared_interest := TRUE;
                        EXIT;
                    END IF;
                END IF;
            END LOOP;

            IF NOT has_shared_interest THEN CONTINUE; END IF;

            INSERT INTO matches (user1_id, user2_id, match_type, matched_intent, event_id, created_at)
            VALUES (attendee_a_id, attendee_b_id, 'event', shared_intents[1], p_event_id, NOW());
        END LOOP;
    END LOOP;
END;
$_$;

GRANT EXECUTE ON FUNCTION public.perform_event_matching(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_event_matching(UUID) TO anon;

-- ============================================================
-- STEP 12: Rewrite get_potential_event_matches
-- ============================================================
DROP FUNCTION IF EXISTS public.get_potential_event_matches(uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_potential_event_matches(p_event_id UUID, p_user_id UUID)
RETURNS TABLE (
    matched_user_id UUID,
    matched_user_name TEXT,
    shared_intents TEXT[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_enabled BOOLEAN;
    current_active TEXT[];
    current_interests JSONB;
    other_attendee RECORD;
    other_enabled BOOLEAN;
    other_interests JSONB;
    shared_intents_list TEXT[];
    has_shared_interest BOOLEAN := FALSE;
    shared_interest_category TEXT;
    existing_match_count INTEGER;
BEGIN
    SET search_path = 'public';

    SELECT shared_event_matching_enabled INTO current_enabled
    FROM users WHERE id = p_user_id;

    IF current_enabled IS NULL OR NOT current_enabled THEN RETURN; END IF;

    SELECT
      ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)),
      public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb))
    INTO current_active, current_interests
    FROM user_profiles WHERE user_id = p_user_id;

    IF current_active IS NULL THEN current_active := ARRAY[]::text[]; END IF;

    FOR other_attendee IN
        SELECT DISTINCT ea.user_id, u.name as user_name
        FROM event_attendees ea
        LEFT JOIN users u ON ea.user_id = u.id
        WHERE ea.event_id = p_event_id AND ea.user_id != p_user_id
    LOOP
        SELECT shared_event_matching_enabled INTO other_enabled
        FROM users WHERE id = other_attendee.user_id;

        IF other_enabled IS NULL OR NOT other_enabled THEN CONTINUE; END IF;

        SELECT ARRAY(
            SELECT intent FROM unnest(current_active) AS t(intent)
            WHERE intent = ANY(
              ARRAY(SELECT jsonb_array_elements_text(up.active_modes::jsonb) FROM user_profiles up WHERE up.user_id = other_attendee.user_id)
            )
        ) INTO shared_intents_list;

        IF shared_intents_list IS NULL OR array_length(shared_intents_list, 1) IS NULL THEN CONTINUE; END IF;

        SELECT public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb))
        INTO other_interests
        FROM user_profiles WHERE user_id = other_attendee.user_id;

        has_shared_interest := FALSE;
        FOR shared_interest_category IN SELECT jsonb_object_keys(current_interests) LOOP
            IF current_interests ? shared_interest_category AND other_interests ? shared_interest_category THEN
                IF EXISTS (
                    SELECT 1 FROM jsonb_array_elements_text(current_interests -> shared_interest_category) AS ci
                    WHERE ci = ANY(SELECT jsonb_array_elements_text(other_interests -> shared_interest_category))
                ) THEN
                    has_shared_interest := TRUE;
                    EXIT;
                END IF;
            END IF;
        END LOOP;

        IF NOT has_shared_interest THEN CONTINUE; END IF;

        SELECT COUNT(*) INTO existing_match_count
        FROM matches
        WHERE (user1_id = p_user_id AND user2_id = other_attendee.user_id)
           OR (user1_id = other_attendee.user_id AND user2_id = p_user_id);

        IF existing_match_count > 0 THEN CONTINUE; END IF;

        RETURN QUERY SELECT
            other_attendee.user_id,
            COALESCE(public.mask_full_name(other_attendee.user_name), 'Unknown User'),
            shared_intents_list;
    END LOOP;

    RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION get_potential_event_matches(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION get_potential_event_matches(uuid, uuid) TO anon;

-- ============================================================
-- STEP 13: Rewrite perform_event_matching_debug
-- ============================================================
DROP FUNCTION IF EXISTS public.perform_event_matching_debug(uuid);
CREATE OR REPLACE FUNCTION public.perform_event_matching_debug(p_event_id UUID)
RETURNS TABLE (
    user1_id UUID,
    user2_id UUID,
    match_reason TEXT,
    matched_intent TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    event_attendee RECORD;
    other_attendee RECORD;
    attendee_a_id UUID;
    attendee_b_id UUID;
    existing_match_id UUID;
    shared_intents TEXT[];
    has_shared_interest BOOLEAN := FALSE;
    shared_interest_category TEXT;
    a_active TEXT[];
    b_active TEXT[];
    a_interests JSONB;
    b_interests JSONB;
    a_enabled BOOLEAN;
    b_enabled BOOLEAN;
BEGIN
    SET search_path = 'public';

    FOR event_attendee IN
        SELECT DISTINCT ea.user_id FROM event_attendees ea WHERE ea.event_id = p_event_id
    LOOP
        attendee_a_id := event_attendee.user_id;

        SELECT shared_event_matching_enabled INTO a_enabled
        FROM users WHERE id = attendee_a_id;
        IF a_enabled IS NULL OR NOT a_enabled THEN CONTINUE; END IF;

        SELECT
          ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)),
          public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb))
        INTO a_active, a_interests
        FROM user_profiles WHERE user_id = attendee_a_id;

        IF a_active IS NULL THEN CONTINUE; END IF;

        FOR other_attendee IN
            SELECT DISTINCT ea2.user_id FROM event_attendees ea2
            WHERE ea2.event_id = p_event_id AND ea2.user_id != attendee_a_id
        LOOP
            attendee_b_id := other_attendee.user_id;
            IF attendee_a_id >= attendee_b_id THEN CONTINUE; END IF;

            SELECT id INTO existing_match_id FROM matches
            WHERE (user1_id = attendee_a_id AND user2_id = attendee_b_id)
               OR (user1_id = attendee_b_id AND user2_id = attendee_a_id)
            LIMIT 1;
            IF existing_match_id IS NOT NULL THEN CONTINUE; END IF;

            SELECT shared_event_matching_enabled INTO b_enabled
            FROM users WHERE id = attendee_b_id;
            IF b_enabled IS NULL OR NOT b_enabled THEN CONTINUE; END IF;

            SELECT
              ARRAY(SELECT jsonb_array_elements_text(active_modes::jsonb)),
              public.merge_interest_maps(COALESCE(personal_interests, '{}'::jsonb), COALESCE(business_interests, '{}'::jsonb))
            INTO b_active, b_interests
            FROM user_profiles WHERE user_id = attendee_b_id;

            IF b_active IS NULL THEN CONTINUE; END IF;

            SELECT ARRAY(
                SELECT intent FROM unnest(a_active) AS t(intent) WHERE intent = ANY(b_active)
            ) INTO shared_intents;

            IF shared_intents IS NULL OR array_length(shared_intents, 1) IS NULL THEN CONTINUE; END IF;

            has_shared_interest := FALSE;
            FOR shared_interest_category IN SELECT jsonb_object_keys(a_interests) LOOP
                IF a_interests ? shared_interest_category AND b_interests ? shared_interest_category THEN
                    IF EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(a_interests -> shared_interest_category) AS ia
                        WHERE ia IN (SELECT jsonb_array_elements_text(b_interests -> shared_interest_category))
                    ) THEN
                        has_shared_interest := TRUE;
                        EXIT;
                    END IF;
                END IF;
            END LOOP;

            IF has_shared_interest THEN
                user1_id := attendee_a_id;
                user2_id := attendee_b_id;
                match_reason := 'shared_interests';
                matched_intent := shared_intents[1];
                RETURN NEXT;
            END IF;
        END LOOP;
    END LOOP;

    RETURN;
END;
$$;

-- ============================================================
-- STEP 14: Rewrite get_masked_sender_name for new schema
-- ============================================================
DROP FUNCTION IF EXISTS public.get_masked_sender_name(uuid);
CREATE OR REPLACE FUNCTION public.get_masked_sender_name(sender_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    full_name TEXT;
BEGIN
    SELECT u.name INTO full_name FROM users u WHERE u.id = sender_id;
    RETURN public.mask_full_name(full_name);
END;
$$;

-- ============================================================
-- STEP 15: Rewrite get_potential_matches for new schema
--          display_name now comes from users.name
--          profile_data is assembled from user_profiles columns
-- ============================================================
DROP FUNCTION IF EXISTS public.get_potential_matches(uuid, double precision, double precision, double precision);
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
  ORDER BY distance_km ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_potential_matches(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_potential_matches(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO anon;

-- ============================================================
-- STEP 16: Rewrite get_potential_matches_by_intents for new schema
-- ============================================================
DROP FUNCTION IF EXISTS public.get_potential_matches_by_intents(uuid, double precision, double precision, double precision, text[]);
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

-- ============================================================
-- STEP 17: Rewrite list_orphan_profile_photos for new schema
--          photos moved from users to user_profiles
-- ============================================================
DROP FUNCTION IF EXISTS public.list_orphan_profile_photos(int, int);
CREATE OR REPLACE FUNCTION public.list_orphan_profile_photos(
  p_min_age_minutes int DEFAULT 1440,
  p_limit int DEFAULT 500
)
RETURNS TABLE (name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_threshold timestamptz;
  v_limit int;
BEGIN
  IF p_min_age_minutes IS NULL OR p_min_age_minutes < 0 THEN
    RAISE EXCEPTION 'p_min_age_minutes must be >= 0';
  END IF;

  v_limit := COALESCE(p_limit, 500);
  IF v_limit < 1 THEN v_limit := 1; END IF;
  IF v_limit > 1000 THEN v_limit := 1000; END IF;

  v_threshold := now() - make_interval(mins => p_min_age_minutes);

  RETURN QUERY
  WITH referenced AS (
    SELECT DISTINCT value AS name
    FROM public.user_profiles up
    CROSS JOIN LATERAL jsonb_array_elements_text(up.photos) AS value
    WHERE up.photos IS NOT NULL
      AND value IS NOT NULL
      AND btrim(value) <> ''
  )
  SELECT o.name
  FROM storage.objects o
  WHERE o.bucket_id = 'profile-photos'
    AND o.created_at < v_threshold
    AND NOT EXISTS (
      SELECT 1
      FROM referenced r
      WHERE r.name = o.name
    )
  ORDER BY o.created_at ASC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.list_orphan_profile_photos(int,int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_orphan_profile_photos(int,int) TO service_role;

-- ============================================================
-- STEP 18: Rewrite get_user_chats for new schema
--          photos now on user_profiles
-- ============================================================
DROP FUNCTION IF EXISTS public.get_user_chats(uuid, int);
CREATE OR REPLACE FUNCTION public.get_user_chats(p_user_id uuid, p_limit int DEFAULT 5)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  last_message_id uuid,
  last_message_preview text,
  last_message_at timestamptz,
  unread_count integer,
  updated_at timestamptz,
  translation_enabled boolean,
  translation_language text
) AS $$
  SELECT c.match_id,
         c.other_user_id,
         public.mask_full_name(u.name) as other_name,
         ARRAY(SELECT jsonb_array_elements_text(up.photos)) as other_photos,
         c.last_message_id,
         c.last_message_preview,
         c.last_message_at,
         c.unread_count,
         c.updated_at,
         c.translation_enabled,
         c.translation_language
  FROM public.chats c
  LEFT JOIN public.users u ON u.id = c.other_user_id
  LEFT JOIN public.user_profiles up ON up.user_id = c.other_user_id
  WHERE c.user_id = p_user_id
  ORDER BY COALESCE(c.last_message_at, c.updated_at) DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- STEP 19: Rewrite get_user_recent_matches for new schema
-- ============================================================
DROP FUNCTION IF EXISTS public.get_user_recent_matches(uuid, int);
CREATE OR REPLACE FUNCTION public.get_user_recent_matches(p_user_id uuid, p_limit int DEFAULT 20)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  match_type text,
  matched_intent text,
  last_activity_at timestamptz,
  created_at timestamptz
) AS $$
  SELECT urm.match_id,
         urm.other_user_id,
         public.mask_full_name(u.name) as other_name,
         ARRAY(SELECT jsonb_array_elements_text(up.photos)) as other_photos,
         urm.match_type,
         urm.matched_intent,
         urm.last_activity_at,
         urm.created_at
  FROM public.user_recent_matches urm
  LEFT JOIN public.users u ON u.id = urm.other_user_id
  LEFT JOIN public.user_profiles up ON up.user_id = urm.other_user_id
  WHERE urm.user_id = p_user_id
  ORDER BY urm.last_activity_at DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- STEP 20: Rewrite get_user_recent_chats for new schema
-- ============================================================
DROP FUNCTION IF EXISTS public.get_user_recent_chats(uuid, int);
CREATE OR REPLACE FUNCTION public.get_user_recent_chats(p_user_id uuid, p_limit int DEFAULT 20)
RETURNS TABLE (
  match_id uuid,
  other_user_id uuid,
  other_name text,
  other_photos text[],
  last_message_preview text,
  last_message_at timestamptz,
  unread_count integer,
  updated_at timestamptz,
  translation_enabled boolean,
  translation_language text,
  last_message_id uuid,
  last_message_sender_id uuid,
  last_message_translated text,
  last_message_source_language text,
  last_message_target_language text,
  last_message_encryption_scheme text,
  last_message_sender_key_id uuid,
  last_message_recipient_key_id uuid,
  last_message_recipient_id uuid,
  last_message_content_original_encrypted text,
  last_message_content_original_nonce text,
  last_message_content_translated_encrypted text,
  last_message_content_translated_nonce text,
  last_message_wrapped_keys jsonb
) AS $$
  SELECT c.match_id, c.other_user_id,
         public.mask_full_name(u.name) as other_name,
         ARRAY(SELECT jsonb_array_elements_text(up.photos)) as other_photos,
         c.last_message_preview, c.last_message_at,
         c.unread_count, c.updated_at,
         c.translation_enabled, c.translation_language,
         c.last_message_id,
         COALESCE(cm.sender_id, c.other_user_id) as last_message_sender_id,
         CASE 
             WHEN cm.content_translated_encrypted IS NOT NULL 
                  AND cm.content_translated_encrypted != '' 
             THEN cm.content_translated_encrypted
             ELSE NULL
         END as last_message_translated,
         cm.detected_source_language as last_message_source_language,
         cm.translated_target_language as last_message_target_language,
         cm.encryption_scheme as last_message_encryption_scheme,
         cm.sender_key_id as last_message_sender_key_id,
         cm.recipient_key_id as last_message_recipient_key_id,
         cm.recipient_id as last_message_recipient_id,
         cm.content_original_encrypted as last_message_content_original_encrypted,
         cm.content_original_nonce as last_message_content_original_nonce,
         cm.content_translated_encrypted as last_message_content_translated_encrypted,
         cm.content_translated_nonce as last_message_content_translated_nonce,
         cm.wrapped_keys as last_message_wrapped_keys
  FROM public.chats c
  INNER JOIN public.matches m ON m.id = c.match_id
  LEFT JOIN public.users u ON c.other_user_id = u.id
  LEFT JOIN public.user_profiles up ON up.user_id = c.other_user_id
  LEFT JOIN public.chat_messages cm ON cm.id = c.last_message_id
  WHERE c.user_id = p_user_id
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- STEP 21: Rewrite get_message_reactors for new schema
-- ============================================================
DROP FUNCTION IF EXISTS public.get_message_reactors(uuid, text);
CREATE OR REPLACE FUNCTION public.get_message_reactors(message_id uuid, reaction text)
RETURNS TABLE(user_id uuid, display_name text, photo text)
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT
    mr.user_id::uuid AS user_id,
    public.mask_full_name(u.name) AS display_name,
    (SELECT jsonb_array_elements_text(up.photos) LIMIT 1) AS photo
  FROM public.message_reactions mr
  LEFT JOIN public.users u ON u.id = mr.user_id
  LEFT JOIN public.user_profiles up ON up.user_id = mr.user_id
  WHERE mr.message_id = $1 AND mr.reaction = $2;
$$;

-- ============================================================
-- STEP 22: Rewrite admin_list_verification_users for new schema
-- ============================================================
DROP FUNCTION IF EXISTS public.admin_list_verification_users(text, text, integer, integer);
CREATE OR REPLACE FUNCTION public.admin_list_verification_users(
  p_status text DEFAULT NULL,
  p_query text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  name text,
  verification_status text,
  is_verified boolean,
  profile_photo_path text,
  verification_photo_path text,
  verification_submitted_at timestamptz,
  verification_reviewed_at timestamptz,
  verification_reviewer_id uuid,
  verification_reviewer_name text,
  verification_similarity_score numeric,
  verification_ai_analysis jsonb,
  verification_auto_rejected boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_status text;
  v_query text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_status := NULLIF(trim(p_status), '');
  v_query := NULLIF(trim(p_query), '');

  RETURN QUERY
  SELECT
    u.id,
    u.name,
    u.verification_status,
    u.is_verified,
    (
      SELECT p
      FROM jsonb_array_elements_text(up.photos) AS p
      WHERE NULLIF(btrim(p), '') IS NOT NULL
      LIMIT 1
    ) AS profile_photo_path,
    u.verification_photo_path,
    u.verification_submitted_at,
    u.verification_reviewed_at,
    u.verification_reviewer_id,
    ru.name AS verification_reviewer_name,
    u.verification_similarity_score,
    u.verification_ai_analysis,
    u.verification_auto_rejected
  FROM public.users u
  LEFT JOIN public.user_profiles up ON up.user_id = u.id
  LEFT JOIN public.users ru
    ON ru.id = u.verification_reviewer_id
  WHERE (v_status IS NULL OR u.verification_status = v_status)
    AND (
      v_query IS NULL OR
      u.id::text ILIKE '%' || v_query || '%' OR
      COALESCE(u.name, '') ILIKE '%' || v_query || '%' OR
      COALESCE(u.verification_status, '') ILIKE '%' || v_query || '%'
    )
  ORDER BY u.verification_submitted_at DESC NULLS LAST, u.id DESC
  LIMIT GREATEST(LEAST(COALESCE(p_limit, 100), 500), 1)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
END;
$$;

-- ============================================================
-- STEP 23: Rewrite cleanup_orphan_profile_photos for new schema
-- ============================================================
DROP FUNCTION IF EXISTS public.cleanup_orphan_profile_photos(int);
CREATE OR REPLACE FUNCTION public.cleanup_orphan_profile_photos(p_min_age_minutes int DEFAULT 1440)
RETURNS TABLE (deleted_count int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_threshold timestamptz;
  v_deleted int := 0;
BEGIN
  IF p_min_age_minutes IS NULL OR p_min_age_minutes < 0 THEN
    RAISE EXCEPTION 'p_min_age_minutes must be >= 0';
  END IF;

  v_threshold := now() - make_interval(mins => p_min_age_minutes);

  WITH referenced AS (
    SELECT DISTINCT value AS name
    FROM public.user_profiles up
    CROSS JOIN LATERAL jsonb_array_elements_text(up.photos) AS value
    WHERE up.photos IS NOT NULL
      AND value IS NOT NULL
      AND btrim(value) <> ''
  )
  DELETE FROM storage.objects o
  WHERE o.bucket_id = 'profile-photos'
    AND o.created_at < v_threshold
    AND NOT EXISTS (
      SELECT 1
      FROM referenced r
      WHERE r.name = o.name
    );

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  deleted_count := v_deleted;
  RETURN NEXT;
END;
$$;

-- ============================================================
-- STEP 24: Rewrite check_profile_bio_uniqueness for new schema
--          bio now on user_profiles
-- ============================================================
DROP FUNCTION IF EXISTS public.check_profile_bio_uniqueness(uuid, text);
CREATE OR REPLACE FUNCTION public.check_profile_bio_uniqueness(
  p_user_id uuid,
  p_bio text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_normalized_bio text;
BEGIN
  v_normalized_bio := public.normalize_profile_bio_text(p_bio);

  IF v_normalized_bio IS NULL THEN
    RETURN true;
  END IF;

  RETURN NOT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.user_id <> p_user_id
      AND public.bio_texts_too_similar(up.bio, p_bio)
  );
END;
$$;

-- ============================================================
-- STEP 25: Rewrite enforce_unique_profile_bio trigger for new schema
--          Move trigger from users to user_profiles
-- ============================================================
DROP TRIGGER IF EXISTS trg_enforce_unique_profile_bio ON public.users;

DROP FUNCTION IF EXISTS public.enforce_unique_profile_bio();
CREATE OR REPLACE FUNCTION public.enforce_unique_profile_bio()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_old_normalized text;
  v_new_normalized text;
BEGIN
  v_new_normalized := public.normalize_profile_bio_text(NEW.bio);

  IF TG_OP = 'UPDATE' THEN
    v_old_normalized := public.normalize_profile_bio_text(OLD.bio);
    IF v_new_normalized IS NOT DISTINCT FROM v_old_normalized THEN
      RETURN NEW;
    END IF;
  END IF;

  IF v_new_normalized IS NULL THEN
    RETURN NEW;
  END IF;

  IF NOT public.check_profile_bio_uniqueness(NEW.user_id, NEW.bio) THEN
    RAISE EXCEPTION 'bio_already_in_use'
      USING ERRCODE = 'P0001',
            DETAIL = 'This bio is already being used by another profile.';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_unique_profile_bio
BEFORE INSERT OR UPDATE OF bio ON public.user_profiles
FOR EACH ROW
EXECUTE FUNCTION public.enforce_unique_profile_bio();

-- Drop the old index on users (bio moved to user_profiles)
DROP INDEX IF EXISTS public.idx_users_normalized_bio_lookup;

-- Recreate index on user_profiles
CREATE INDEX idx_user_profiles_normalized_bio_lookup
  ON public.user_profiles (public.normalize_profile_bio_text(bio))
  WHERE bio IS NOT NULL AND btrim(bio) <> '';

-- ============================================================
-- STEP 26: Rewrite check_unread_notifications for new schema
--          profile_data dropped from user_profiles, so name now
--          comes from users.name
-- ============================================================
DROP FUNCTION IF EXISTS check_unread_notifications(UUID);
DROP FUNCTION IF EXISTS check_unread_notifications(UUID, UUID);

DROP FUNCTION IF EXISTS check_unread_notifications(uuid, uuid);
CREATE OR REPLACE FUNCTION check_unread_notifications(p_user_id UUID, p_message_id UUID DEFAULT NULL)
RETURNS TABLE (
    unread_matches_count INTEGER,
    unread_messages_count INTEGER,
    latest_match_name TEXT,
    latest_message_sender TEXT,
    latest_message_content TEXT,
    latest_message_id UUID,
    latest_match_id UUID,
    latest_message_sender_id UUID,
    translation_enabled BOOLEAN,
    translation_language TEXT,
    translation_available BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_unread_matches INTEGER := 0;
    v_unread_messages INTEGER := 0;
    v_latest_match_name TEXT;
    v_latest_message_sender TEXT;
    v_latest_message_content TEXT;
    v_latest_message_id UUID;
    v_latest_match_id UUID;
    v_latest_sender_id UUID;
    v_translation_enabled BOOLEAN;
    v_translation_language TEXT;
    v_translation_available BOOLEAN;
BEGIN
    SET search_path = 'public';

    -- If a specific message ID is provided (from Realtime), fetch it directly
    IF p_message_id IS NOT NULL THEN
        SELECT
            public.mask_full_name(u.name),
            CASE
                WHEN cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null' THEN cm.content_translated
                ELSE cm.content_original
            END,
            cm.id,
            cm.match_id,
            cm.sender_id,
            COALESCE(c.translation_enabled, false),
            c.translation_language,
            (cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null')
        INTO v_latest_message_sender, v_latest_message_content, v_latest_message_id, v_latest_match_id, v_latest_sender_id, v_translation_enabled, v_translation_language, v_translation_available
        FROM chat_messages cm
        LEFT JOIN users u ON u.id = cm.sender_id
        LEFT JOIN chats c ON c.match_id = cm.match_id AND c.user_id = p_user_id
        WHERE cm.id = p_message_id;

        IF FOUND THEN
            v_unread_messages := 1;
            RETURN QUERY SELECT
                0,
                1,
                NULL::TEXT,
                v_latest_message_sender,
                v_latest_message_content,
                v_latest_message_id,
                v_latest_match_id,
                v_latest_sender_id,
                v_translation_enabled,
                v_translation_language,
                v_translation_available;
            RETURN;
        END IF;
    END IF;

    -- Fallback to polling logic (check recent unread)

    -- 1. Count unread matches (last 2 minutes)
    SELECT COUNT(*)::INTEGER
    INTO v_unread_matches
    FROM matches m
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      AND m.created_at > (NOW() - INTERVAL '2 minutes');

    -- Get the name of the most recent match
    IF v_unread_matches > 0 THEN
        SELECT
            public.mask_full_name(u.name),
            m.id
        INTO v_latest_match_name, v_latest_match_id
        FROM matches m
        LEFT JOIN public.users u ON u.id = CASE
            WHEN m.user1_id = p_user_id THEN m.user2_id
            ELSE m.user1_id
        END
        WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
          AND m.created_at > (NOW() - INTERVAL '2 minutes')
        ORDER BY m.created_at DESC
        LIMIT 1;
    END IF;

    -- 2. Count unread messages (received in last 2 minutes and unread)
    SELECT COUNT(*)::INTEGER
    INTO v_unread_messages
    FROM chat_messages cm
    JOIN matches m ON cm.match_id = m.id
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      AND cm.sender_id != p_user_id
      AND cm.read_at IS NULL
      AND cm.created_at > (NOW() - INTERVAL '2 minutes');

    -- Get latest message details with translation info
    IF v_unread_messages > 0 THEN
        SELECT
            public.mask_full_name(u.name),
            CASE
                WHEN cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null' THEN cm.content_translated
                ELSE cm.content_original
            END,
            cm.id,
            cm.match_id,
            cm.sender_id,
            COALESCE(c.translation_enabled, false),
            c.translation_language,
            (cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null')
        INTO v_latest_message_sender, v_latest_message_content, v_latest_message_id, v_latest_match_id, v_latest_sender_id, v_translation_enabled, v_translation_language, v_translation_available
        FROM chat_messages cm
        JOIN matches m ON cm.match_id = m.id
        LEFT JOIN users u ON u.id = cm.sender_id
        LEFT JOIN chats c ON c.match_id = cm.match_id AND c.user_id = p_user_id
        WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
          AND cm.sender_id != p_user_id
          AND cm.read_at IS NULL
          AND cm.created_at > (NOW() - INTERVAL '2 minutes')
        ORDER BY cm.created_at DESC
        LIMIT 1;
    END IF;

    RETURN QUERY SELECT
        COALESCE(v_unread_matches, 0),
        COALESCE(v_unread_messages, 0),
        v_latest_match_name,
        v_latest_message_sender,
        v_latest_message_content,
        v_latest_message_id,
        v_latest_match_id,
        v_latest_sender_id,
        v_translation_enabled,
        v_translation_language,
        v_translation_available;
END;
$$;

GRANT EXECUTE ON FUNCTION check_unread_notifications(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION check_unread_notifications(UUID, UUID) TO anon;

COMMIT;

