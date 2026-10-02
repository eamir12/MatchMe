-- Migration: Separate Enforcement Mode Per Intent and Per Feature
-- Date: 2026-06-30
-- Purpose: Convert `users.strict_gender_age_enforcement` from a single BOOLEAN to a
--   JSONB structure that stores per-intent AND per-feature (gender / age) enforcement.
--   New shape:
--     {
--       "<intent_key>": { "gender": <bool>, "age": <bool> },
--       ...
--     }
--   Existing values are migrated automatically: the previous global boolean is
--   applied to BOTH the "gender" and "age" features across all of the user's
--   currently active intents (falling back to all known intents from the
--   `intents` table if the user has none active).
--
--   The matching functions are redefined to honor the new structure, including a
--   "Flexible" priority rule: a flexible match (one that would have been blocked
--   by a strict rule) is only allowed between two users for a shared intent if
--   NEITHER user has any "Compliant" candidate nearby for that intent. A
--   "Compliant" candidate for user U is one that satisfies BOTH U's gender and
--   age preferences for that intent (regardless of U's strict flags).

BEGIN;

--------------------------------------------------------------------------------
-- 1) Alter the column type and backfill existing values
--------------------------------------------------------------------------------

-- Ensure the column is JSONB. The USING expression must work for the
-- existing (pre-conversion) data types. We go through ::text to bridge from
-- the old BOOLEAN type to JSONB; a boolean is rendered as "true" / "false"
-- and an already-migrated JSONB value is rendered as its JSON text — both
-- parse back to a valid JSONB value.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'users'
          AND column_name = 'strict_gender_age_enforcement'
          AND data_type <> 'jsonb'
    ) THEN
        ALTER TABLE public.users
            ALTER COLUMN strict_gender_age_enforcement DROP DEFAULT;
        ALTER TABLE public.users
            ALTER COLUMN strict_gender_age_enforcement TYPE JSONB
            USING COALESCE(strict_gender_age_enforcement::text::jsonb, '{}'::jsonb);
    END IF;
END $$;

ALTER TABLE public.users
    ALTER COLUMN strict_gender_age_enforcement SET DEFAULT '{}'::jsonb;

-- Backfill legacy boolean values into the new per-intent / per-feature shape.
-- For every user, seed every known intent key (taken from `intents.key` or
-- the user's `active_modes` text[]) with both features set to the previous
-- boolean value. We only overwrite users that still hold a legacy boolean or
-- empty/null value to avoid clobbering data that was saved after this
-- migration was already in effect.
UPDATE public.users u
SET strict_gender_age_enforcement = COALESCE((
    SELECT jsonb_object_agg(intent_key, jsonb_build_object('gender', legacy_bool, 'age', legacy_bool))
    FROM (
        SELECT DISTINCT intent_key
        FROM (
            -- Use the user's currently active modes (text[] column)
            SELECT unnest(u.active_modes) AS intent_key
            UNION
            -- As a safety net, also include every known intent key from the intents table
            SELECT i.key::text AS intent_key
            FROM public.intents i
        ) all_intents
        WHERE intent_key IS NOT NULL AND intent_key <> ''
    ) intents_seed
), '{}'::jsonb)
FROM (
    SELECT id,
           CASE
               WHEN strict_gender_age_enforcement IS NULL THEN false
               WHEN jsonb_typeof(strict_gender_age_enforcement) = 'boolean'
                   THEN (strict_gender_age_enforcement #>> '{}')::boolean
               ELSE NULL
           END AS legacy_bool
    FROM public.users
) legacy
WHERE u.id = legacy.id
  AND legacy.legacy_bool IS NOT NULL;

-- Add a GIN index for fast JSONB lookups in the matching functions
CREATE INDEX IF NOT EXISTS idx_users_strict_gender_age_enforcement
    ON public.users USING gin(strict_gender_age_enforcement);

--------------------------------------------------------------------------------
-- 2) Helper: evaluate if a candidate is "compliant" for a given user and intent
--------------------------------------------------------------------------------
-- A "compliant" candidate for user U is one who satisfies BOTH U's gender and
-- age preferences for the given intent. If U has no preferences for the intent
-- (neither gender nor age), the function returns FALSE so that the caller can
-- treat the user as having "no compliant candidates" — which is the correct
-- semantic for the "Flexible priority" rule: a user with no preferences is
-- considered fully open, and the strict/flexible toggle has no meaning for them.
--
-- If U has at least one preference (gender OR age) for the intent, the
-- candidate is compliant only when it satisfies the preferences that ARE set.
--
-- Two overloads are provided: one that takes the user's preferences as JSONB
-- (preferred, to avoid an extra DB roundtrip when the caller already has them
-- in memory) and one that fetches them by user id.
CREATE OR REPLACE FUNCTION public.is_compliant_candidate(
    p_gender_prefs JSONB,
    p_age_prefs JSONB,
    p_candidate_gender TEXT,
    p_candidate_dob DATE,
    p_intent TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_candidate_age INTEGER;
    v_has_gender_pref BOOLEAN;
    v_has_age_pref BOOLEAN;
BEGIN
    v_has_gender_pref := COALESCE(p_gender_prefs ? p_intent, FALSE);
    v_has_age_pref := COALESCE(p_age_prefs ? p_intent, FALSE);

    -- If the user has no preferences at all for the intent, the user is
    -- considered fully open and therefore has no "compliant candidates" in
    -- the prioritization sense. Return FALSE.
    IF NOT v_has_gender_pref AND NOT v_has_age_pref THEN
        RETURN FALSE;
    END IF;

    -- Gender check (only enforced if the user actually has a gender preference
    -- for the intent)
    IF v_has_gender_pref THEN
        IF p_candidate_gender IS NULL THEN
            RETURN FALSE;
        END IF;
        IF NOT (p_gender_prefs -> p_intent) ? p_candidate_gender THEN
            RETURN FALSE;
        END IF;
    END IF;

    -- Age check (only enforced if the user actually has an age preference for
    -- the intent)
    IF v_has_age_pref THEN
        IF p_candidate_dob IS NULL THEN
            RETURN FALSE;
        END IF;
        v_candidate_age := EXTRACT(YEAR FROM AGE(p_candidate_dob));
        IF jsonb_array_length(p_age_prefs -> p_intent) >= 2 THEN
            IF v_candidate_age < (p_age_prefs -> p_intent ->> 0)::numeric
               OR v_candidate_age > (p_age_prefs -> p_intent ->> 1)::numeric THEN
                RETURN FALSE;
            END IF;
        END IF;
    END IF;

    RETURN TRUE;
END;
$$;

-- Backwards-compatible overload: fetches the user's preferences internally.
CREATE OR REPLACE FUNCTION public.is_compliant_candidate(
    p_user_id UUID,
    p_candidate_gender TEXT,
    p_candidate_dob DATE,
    p_intent TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_gender_prefs JSONB;
    v_age_prefs JSONB;
BEGIN
    SELECT gender_preferences, age_preferences
    INTO v_gender_prefs, v_age_prefs
    FROM public.users
    WHERE id = p_user_id;

    RETURN public.is_compliant_candidate(
        v_gender_prefs,
        v_age_prefs,
        p_candidate_gender,
        p_candidate_dob,
        p_intent
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_compliant_candidate(JSONB, JSONB, TEXT, DATE, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_compliant_candidate(JSONB, JSONB, TEXT, DATE, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.is_compliant_candidate(UUID, TEXT, DATE, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_compliant_candidate(UUID, TEXT, DATE, TEXT) TO anon;

--------------------------------------------------------------------------------
-- 3) Helper: read a per-feature strict flag, defaulting to FALSE
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_enforcement_flag(
    p_enforcement JSONB,
    p_intent TEXT,
    p_feature TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_intent_block JSONB;
BEGIN
    IF p_enforcement IS NULL THEN
        RETURN FALSE;
    END IF;
    v_intent_block := p_enforcement -> p_intent;
    IF v_intent_block IS NULL OR jsonb_typeof(v_intent_block) <> 'object' THEN
        RETURN FALSE;
    END IF;
    RETURN COALESCE((v_intent_block ->> p_feature)::boolean, FALSE);
END;
$$;

--------------------------------------------------------------------------------
-- 4) Redefine perform_continuous_user_matching
--------------------------------------------------------------------------------
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
    current_user_intents TEXT[];
    current_user_interests JSONB;
    other_user_intents TEXT[];
    other_user_interests JSONB;
    shared_intents TEXT[];
    has_shared_interest BOOLEAN := FALSE;
    interest_category TEXT;
    total_users_processed INTEGER := 0;
    total_matches_created INTEGER := 0;
    has_matching_sub_intent BOOLEAN := FALSE;
    shared_intent TEXT;
    current_sub_intents TEXT[];
    other_sub_intents TEXT[];
    current_user_enforcement JSONB;
    other_user_enforcement JSONB;
    current_user_gender_prefs JSONB;
    current_user_age_prefs JSONB;
    other_user_gender_prefs JSONB;
    other_user_age_prefs JSONB;
    other_user_gender TEXT;
    other_user_dob DATE;
    current_user_gender TEXT;
    current_user_dob DATE;
    other_user_age INTEGER;
    current_user_age INTEGER;
    a_strict_gender BOOLEAN;
    a_strict_age BOOLEAN;
    b_strict_gender BOOLEAN;
    b_strict_age BOOLEAN;
    a_gender_ok BOOLEAN;
    a_age_ok BOOLEAN;
    b_gender_ok BOOLEAN;
    b_age_ok BOOLEAN;
    pair_allowed BOOLEAN := FALSE;
    a_has_compliant BOOLEAN;
    b_has_compliant BOOLEAN;
BEGIN
    SET search_path = 'public';

    FOR user_record IN
        SELECT
            ul.user_id, ul.latitude, ul.longitude, u.active_modes,
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

        -- Load profile/preferences for the current user once per outer iteration
        SELECT
            gender,
            date_of_birth,
            gender_preferences,
            age_preferences,
            strict_gender_age_enforcement
        INTO current_user_gender, current_user_dob,
             current_user_gender_prefs, current_user_age_prefs, current_user_enforcement
        FROM users
        WHERE id = user_record.user_id;

        IF current_user_dob IS NOT NULL THEN
            current_user_age := EXTRACT(YEAR FROM AGE(current_user_dob));
        ELSE
            current_user_age := NULL;
        END IF;

        SELECT profile_data->'interests' INTO current_user_interests
        FROM user_profiles
        WHERE user_id = user_record.user_id AND profile_data ? 'interests'
        LIMIT 1;

        current_user_intents := user_record.active_modes;

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

            SELECT active_modes, gender, date_of_birth,
                   gender_preferences, age_preferences, strict_gender_age_enforcement
            INTO other_user_intents, other_user_gender, other_user_dob,
                 other_user_gender_prefs, other_user_age_prefs, other_user_enforcement
            FROM users
            WHERE id = nearby_user_record.user_id
              AND (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
                AND COALESCE(user_visibility_setting,false) = TRUE
                AND COALESCE(system_visibility_status,'visible') = 'visible');

            IF other_user_intents IS NULL OR array_length(other_user_intents, 1) = 0 THEN
                CONTINUE;
            END IF;

            IF other_user_dob IS NOT NULL THEN
                other_user_age := EXTRACT(YEAR FROM AGE(other_user_dob));
            ELSE
                other_user_age := NULL;
            END IF;

            SELECT ARRAY(
                SELECT intent
                FROM unnest(current_user_intents) as t(intent)
                WHERE intent = ANY(other_user_intents)
            ) INTO shared_intents;

            IF array_length(shared_intents, 1) IS NULL OR array_length(shared_intents, 1) = 0 THEN
                CONTINUE;
            END IF;

            -- Check shared sub-intents per shared main intent
            has_matching_sub_intent := FALSE;
            <<sub_intent_loop>>
            FOREACH shared_intent IN ARRAY shared_intents LOOP
                current_sub_intents := ARRAY(
                    SELECT jsonb_array_elements_text(up.profile_data->'sub_intent')
                    FROM user_profiles up
                    WHERE up.user_id = user_record.user_id
                      AND up.intent_type = shared_intent
                      AND up.profile_data ? 'sub_intent'
                );

                other_sub_intents := ARRAY(
                    SELECT jsonb_array_elements_text(up.profile_data->'sub_intent')
                    FROM user_profiles up
                    WHERE up.user_id = nearby_user_record.user_id
                      AND up.intent_type = shared_intent
                      AND up.profile_data ? 'sub_intent'
                );

                -- If either user has no sub-intent, open to all within this intent
                IF array_length(current_sub_intents, 1) IS NULL
                   OR array_length(other_sub_intents, 1) IS NULL THEN
                    has_matching_sub_intent := TRUE;
                    EXIT sub_intent_loop;
                END IF;

                IF current_sub_intents && other_sub_intents THEN
                    has_matching_sub_intent := TRUE;
                    EXIT sub_intent_loop;
                END IF;
            END LOOP sub_intent_loop;

            IF NOT has_matching_sub_intent THEN
                CONTINUE;
            END IF;

            -- For each shared intent, verify gender/age enforcement compatibility.
            -- A pair is allowed if at least one shared intent lets the two users
            -- match (full compliance OR flexible with no compliant candidates).
            pair_allowed := FALSE;
            <<intent_enforcement_loop>>
            FOREACH shared_intent IN ARRAY shared_intents LOOP
                -- Resolve per-feature strict flags for both sides. Note that
                -- "a_strict_*" reflects what the OTHER user (B) requires of A.
                a_strict_gender := public.get_enforcement_flag(other_user_enforcement, shared_intent, 'gender');
                a_strict_age    := public.get_enforcement_flag(other_user_enforcement, shared_intent, 'age');
                b_strict_gender := public.get_enforcement_flag(current_user_enforcement, shared_intent, 'gender');
                b_strict_age    := public.get_enforcement_flag(current_user_enforcement, shared_intent, 'age');

                -- A's perspective: does current_user (A) satisfy other_user's (B) preferences?
                a_gender_ok := (
                    NOT a_strict_gender
                    OR NOT (other_user_gender_prefs ? shared_intent)
                    OR (other_user_gender_prefs -> shared_intent) ? current_user_gender
                );
                a_age_ok := (
                    NOT a_strict_age
                    OR NOT (other_user_age_prefs ? shared_intent)
                    OR current_user_age IS NULL
                    OR (
                        jsonb_array_length(other_user_age_prefs -> shared_intent) >= 2
                        AND current_user_age >= (other_user_age_prefs -> shared_intent ->> 0)::numeric
                        AND current_user_age <= (other_user_age_prefs -> shared_intent ->> 1)::numeric
                    )
                );

                -- B's perspective: does other_user (B) satisfy current_user's (A) preferences?
                b_gender_ok := (
                    NOT b_strict_gender
                    OR NOT (current_user_gender_prefs ? shared_intent)
                    OR (current_user_gender_prefs -> shared_intent) ? other_user_gender
                );
                b_age_ok := (
                    NOT b_strict_age
                    OR NOT (current_user_age_prefs ? shared_intent)
                    OR other_user_age IS NULL
                    OR (
                        jsonb_array_length(current_user_age_prefs -> shared_intent) >= 2
                        AND other_user_age >= (current_user_age_prefs -> shared_intent ->> 0)::numeric
                        AND other_user_age <= (current_user_age_prefs -> shared_intent ->> 1)::numeric
                    )
                );

                IF a_gender_ok AND a_age_ok AND b_gender_ok AND b_age_ok THEN
                    pair_allowed := TRUE;
                    EXIT intent_enforcement_loop;
                END IF;

                -- At least one side is strict and failing, so this is a flexible match.
                -- Allow it only if NEITHER side has a compliant candidate elsewhere.
                -- Has current_user got any compliant candidate nearby for this intent?
                SELECT EXISTS (
                    SELECT 1
                    FROM find_nearby_users(
                        user_record.user_id, user_record.latitude, user_record.longitude,
                        (user_record.match_radius_default / 1000.0)::DOUBLE PRECISION
                    ) nb
                    INNER JOIN users u2 ON u2.id = nb.user_id
                    WHERE nb.user_id <> nearby_user_record.user_id
                      AND public.is_compliant_candidate(
                          current_user_gender_prefs,
                          current_user_age_prefs,
                          u2.gender,
                          u2.date_of_birth,
                          shared_intent
                      )
                ) INTO a_has_compliant;

                -- Has other_user got any compliant candidate nearby for this intent?
                SELECT EXISTS (
                    SELECT 1
                    FROM find_nearby_users(
                        nearby_user_record.user_id,
                        (SELECT latitude FROM user_locations WHERE user_id = nearby_user_record.user_id),
                        (SELECT longitude FROM user_locations WHERE user_id = nearby_user_record.user_id),
                        (SELECT (match_radius_default / 1000.0)::DOUBLE PRECISION FROM users WHERE id = nearby_user_record.user_id)
                    ) nb
                    INNER JOIN users u2 ON u2.id = nb.user_id
                    WHERE nb.user_id <> user_record.user_id
                      AND public.is_compliant_candidate(
                          other_user_gender_prefs,
                          other_user_age_prefs,
                          u2.gender,
                          u2.date_of_birth,
                          shared_intent
                      )
                ) INTO b_has_compliant;

                IF NOT a_has_compliant AND NOT b_has_compliant THEN
                    pair_allowed := TRUE;
                    EXIT intent_enforcement_loop;
                END IF;
            END LOOP intent_enforcement_loop;

            IF NOT pair_allowed THEN
                CONTINUE;
            END IF;

            SELECT profile_data->'interests' INTO other_user_interests
            FROM user_profiles
            WHERE user_id = nearby_user_record.user_id AND profile_data ? 'interests'
            LIMIT 1;

            has_shared_interest := FALSE;
            IF current_user_interests IS NOT NULL AND other_user_interests IS NOT NULL THEN
                FOR interest_category IN SELECT jsonb_object_keys(current_user_interests) INTERSECT SELECT jsonb_object_keys(other_user_interests) LOOP
                    IF jsonb_array_length(current_user_interests->interest_category) > 0 AND jsonb_array_length(other_user_interests->interest_category) > 0 THEN
                        IF EXISTS (
                            SELECT 1
                            FROM jsonb_array_elements_text(current_user_interests->interest_category) as i1
                            WHERE i1 IN (SELECT jsonb_array_elements_text(other_user_interests->interest_category))
                        ) THEN
                            has_shared_interest := TRUE;
                            EXIT;
                        END IF;
                    END IF;
                END LOOP;
            END IF;

            IF has_shared_interest THEN
                INSERT INTO matches (user1_id, user2_id, matched_intent, match_type, created_at)
                VALUES (
                    LEAST(user_record.user_id, nearby_user_record.user_id),
                    GREATEST(user_record.user_id, nearby_user_record.user_id),
                    shared_intents[1], 'proximity', NOW()
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

--------------------------------------------------------------------------------
-- 5) Redefine perform_event_matching
--------------------------------------------------------------------------------
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
    user_a_data RECORD;
    user_b_data RECORD;
    user_a_interests JSONB;
    user_b_interests JSONB;
    shared_intents TEXT[];
    has_shared_interest BOOLEAN := FALSE;
    shared_interest_category TEXT;
    existing_match_id UUID;
    has_matching_sub_intent BOOLEAN := FALSE;
    shared_intent TEXT;
    user_a_sub_intents TEXT[];
    user_b_sub_intents TEXT[];
    user_a_enforcement JSONB;
    user_b_enforcement JSONB;
    user_a_gender_prefs JSONB;
    user_a_age_prefs JSONB;
    user_b_gender_prefs JSONB;
    user_b_age_prefs JSONB;
    user_a_gender TEXT;
    user_a_dob DATE;
    user_b_gender TEXT;
    user_b_dob DATE;
    user_a_age INTEGER;
    user_b_age INTEGER;
    a_strict_gender BOOLEAN;
    a_strict_age BOOLEAN;
    b_strict_gender BOOLEAN;
    b_strict_age BOOLEAN;
    a_gender_ok BOOLEAN;
    a_age_ok BOOLEAN;
    b_gender_ok BOOLEAN;
    b_age_ok BOOLEAN;
    pair_allowed BOOLEAN := FALSE;
    a_has_compliant BOOLEAN;
    b_has_compliant BOOLEAN;
BEGIN
    SET search_path = 'public';

    FOR event_attendee IN
        SELECT DISTINCT ea.user_id
        FROM event_attendees ea
        WHERE ea.event_id = p_event_id
    LOOP
        attendee_a_id := event_attendee.user_id;

        SELECT active_modes, user_visibility_setting, shared_event_matching_enabled,
               gender, date_of_birth, gender_preferences, age_preferences,
               strict_gender_age_enforcement
        INTO user_a_data
        FROM users WHERE id = attendee_a_id;

        IF user_a_data IS NULL OR NOT user_a_data.shared_event_matching_enabled THEN
            CONTINUE;
        END IF;

        user_a_gender := user_a_data.gender;
        user_a_dob := user_a_data.date_of_birth;
        user_a_gender_prefs := user_a_data.gender_preferences;
        user_a_age_prefs := user_a_data.age_preferences;
        user_a_enforcement := user_a_data.strict_gender_age_enforcement;
        IF user_a_dob IS NOT NULL THEN
            user_a_age := EXTRACT(YEAR FROM AGE(user_a_dob));
        ELSE
            user_a_age := NULL;
        END IF;

        SELECT COALESCE(jsonb_object_agg(category, interests), '{}'::jsonb)
        INTO user_a_interests
        FROM (
            SELECT
                interest_entry.key AS category,
                interest_entry.value AS interests
            FROM user_profiles up
            CROSS JOIN LATERAL jsonb_each(up.profile_data->'interests') AS interest_entry(key, value)
            WHERE up.user_id = attendee_a_id
              AND up.profile_data ? 'interests'
              AND jsonb_typeof(up.profile_data->'interests') = 'object'
              AND jsonb_typeof(interest_entry.value) = 'array'
        ) interests_data;

        FOR other_attendee IN
            SELECT DISTINCT ea2.user_id FROM event_attendees ea2
            WHERE ea2.event_id = p_event_id AND ea2.user_id != attendee_a_id
        LOOP
            attendee_b_id := other_attendee.user_id;
            IF attendee_a_id >= attendee_b_id THEN CONTINUE; END IF;

            IF EXISTS (
                SELECT 1 FROM public.unmatched_pairs up
                WHERE up.user1_id = attendee_a_id AND up.user2_id = attendee_b_id
            ) THEN
                CONTINUE;
            END IF;

            SELECT id INTO existing_match_id FROM matches
            WHERE (user1_id = attendee_a_id AND user2_id = attendee_b_id)
               OR (user1_id = attendee_b_id AND user2_id = attendee_a_id)
            LIMIT 1;
            IF existing_match_id IS NOT NULL THEN CONTINUE; END IF;

            SELECT active_modes, user_visibility_setting, shared_event_matching_enabled,
                   gender, date_of_birth, gender_preferences, age_preferences,
                   strict_gender_age_enforcement
            INTO user_b_data
            FROM users WHERE id = attendee_b_id;
            IF user_b_data IS NULL OR NOT user_b_data.shared_event_matching_enabled THEN
                CONTINUE;
            END IF;

            user_b_gender := user_b_data.gender;
            user_b_dob := user_b_data.date_of_birth;
            user_b_gender_prefs := user_b_data.gender_preferences;
            user_b_age_prefs := user_b_data.age_preferences;
            user_b_enforcement := user_b_data.strict_gender_age_enforcement;
            IF user_b_dob IS NOT NULL THEN
                user_b_age := EXTRACT(YEAR FROM AGE(user_b_dob));
            ELSE
                user_b_age := NULL;
            END IF;

            SELECT ARRAY(
                SELECT intent FROM unnest(user_a_data.active_modes) AS t(intent)
                WHERE intent = ANY(user_b_data.active_modes)
            ) INTO shared_intents;

            IF shared_intents IS NULL OR array_length(shared_intents, 1) IS NULL THEN
                CONTINUE;
            END IF;

            -- Check shared sub-intents per shared main intent
            has_matching_sub_intent := FALSE;
            <<sub_intent_loop>>
            FOREACH shared_intent IN ARRAY shared_intents LOOP
                user_a_sub_intents := ARRAY(
                    SELECT jsonb_array_elements_text(up.profile_data->'sub_intent')
                    FROM user_profiles up
                    WHERE up.user_id = attendee_a_id AND up.intent_type = shared_intent
                      AND up.profile_data ? 'sub_intent'
                );
                user_b_sub_intents := ARRAY(
                    SELECT jsonb_array_elements_text(up.profile_data->'sub_intent')
                    FROM user_profiles up
                    WHERE up.user_id = attendee_b_id AND up.intent_type = shared_intent
                      AND up.profile_data ? 'sub_intent'
                );

                IF array_length(user_a_sub_intents, 1) IS NULL
                   OR array_length(user_b_sub_intents, 1) IS NULL THEN
                    has_matching_sub_intent := TRUE;
                    EXIT sub_intent_loop;
                END IF;

                IF user_a_sub_intents && user_b_sub_intents THEN
                    has_matching_sub_intent := TRUE;
                    EXIT sub_intent_loop;
                END IF;
            END LOOP sub_intent_loop;

            IF NOT has_matching_sub_intent THEN
                CONTINUE;
            END IF;

            -- Per-intent enforcement check. A pair is allowed for a shared
            -- intent if BOTH sides fully satisfy each other's strict rules
            -- for that intent, OR (if at least one side is flexible) NEITHER
            -- side has any compliant candidate elsewhere in the event.
            pair_allowed := FALSE;
            <<intent_enforcement_loop>>
            FOREACH shared_intent IN ARRAY shared_intents LOOP
                a_strict_gender := public.get_enforcement_flag(user_b_enforcement, shared_intent, 'gender');
                a_strict_age    := public.get_enforcement_flag(user_b_enforcement, shared_intent, 'age');
                b_strict_gender := public.get_enforcement_flag(user_a_enforcement, shared_intent, 'gender');
                b_strict_age    := public.get_enforcement_flag(user_a_enforcement, shared_intent, 'age');

                a_gender_ok := (
                    NOT a_strict_gender
                    OR NOT (user_b_gender_prefs ? shared_intent)
                    OR (user_b_gender_prefs -> shared_intent) ? user_a_gender
                );
                a_age_ok := (
                    NOT a_strict_age
                    OR NOT (user_b_age_prefs ? shared_intent)
                    OR user_a_age IS NULL
                    OR (
                        jsonb_array_length(user_b_age_prefs -> shared_intent) >= 2
                        AND user_a_age >= (user_b_age_prefs -> shared_intent ->> 0)::numeric
                        AND user_a_age <= (user_b_age_prefs -> shared_intent ->> 1)::numeric
                    )
                );

                b_gender_ok := (
                    NOT b_strict_gender
                    OR NOT (user_a_gender_prefs ? shared_intent)
                    OR (user_a_gender_prefs -> shared_intent) ? user_b_gender
                );
                b_age_ok := (
                    NOT b_strict_age
                    OR NOT (user_a_age_prefs ? shared_intent)
                    OR user_b_age IS NULL
                    OR (
                        jsonb_array_length(user_a_age_prefs -> shared_intent) >= 2
                        AND user_b_age >= (user_a_age_prefs -> shared_intent ->> 0)::numeric
                        AND user_b_age <= (user_a_age_prefs -> shared_intent ->> 1)::numeric
                    )
                );

                IF a_gender_ok AND a_age_ok AND b_gender_ok AND b_age_ok THEN
                    pair_allowed := TRUE;
                    EXIT intent_enforcement_loop;
                END IF;

                -- Flexible match check
                SELECT EXISTS (
                    SELECT 1
                    FROM event_attendees ea
                    INNER JOIN users u2 ON u2.id = ea.user_id
                    WHERE ea.event_id = p_event_id
                      AND ea.user_id <> attendee_b_id
                      AND ea.user_id <> attendee_a_id
                      AND public.is_compliant_candidate(
                          user_a_gender_prefs,
                          user_a_age_prefs,
                          u2.gender,
                          u2.date_of_birth,
                          shared_intent
                      )
                ) INTO a_has_compliant;

                SELECT EXISTS (
                    SELECT 1
                    FROM event_attendees ea
                    INNER JOIN users u2 ON u2.id = ea.user_id
                    WHERE ea.event_id = p_event_id
                      AND ea.user_id <> attendee_a_id
                      AND ea.user_id <> attendee_b_id
                      AND public.is_compliant_candidate(
                          user_b_gender_prefs,
                          user_b_age_prefs,
                          u2.gender,
                          u2.date_of_birth,
                          shared_intent
                      )
                ) INTO b_has_compliant;

                IF NOT a_has_compliant AND NOT b_has_compliant THEN
                    pair_allowed := TRUE;
                    EXIT intent_enforcement_loop;
                END IF;
            END LOOP intent_enforcement_loop;

            IF NOT pair_allowed THEN
                CONTINUE;
            END IF;

            SELECT COALESCE(jsonb_object_agg(category, interests), '{}'::jsonb)
            INTO user_b_interests
            FROM (
                SELECT
                    interest_entry.key AS category,
                    interest_entry.value AS interests
                FROM user_profiles up
                CROSS JOIN LATERAL jsonb_each(up.profile_data->'interests') AS interest_entry(key, value)
                WHERE up.user_id = attendee_b_id
                  AND up.profile_data ? 'interests'
                  AND jsonb_typeof(up.profile_data->'interests') = 'object'
                  AND jsonb_typeof(interest_entry.value) = 'array'
            ) interests_data;

            has_shared_interest := FALSE;
            FOR shared_interest_category IN SELECT jsonb_object_keys(user_a_interests) LOOP
                IF user_a_interests ? shared_interest_category AND user_b_interests ? shared_interest_category THEN
                    IF EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(user_a_interests->shared_interest_category) AS user_a_interest
                        WHERE user_a_interest = ANY(SELECT jsonb_array_elements_text(user_b_interests->shared_interest_category))
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

COMMIT;
