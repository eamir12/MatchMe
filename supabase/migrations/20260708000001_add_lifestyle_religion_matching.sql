-- Migration: Add Lifestyle/Family/Religion/Height Filter Checks to Matching
-- Date: 2026-07-08
-- Purpose: Incorporate the per-intent preference filters (diet, wants_children,
--   religion, height, smoking, drinking, exercise, has_children) into the
--   server-side matching functions so that auto-matches respect these filters.

BEGIN;

-------------------------------------------------------------------------------
-- 1) Helper: check a single candidate against one user's filter block for an intent
-------------------------------------------------------------------------------
-- Returns TRUE if the candidate passes ALL the user's filters for the given
-- intent. Empty/missing filter values mean "Any" — always passes.
--
-- Parameters:
--   p_filters      — a single intent's filter block (e.g. the value of
--                     lifestyle_filters->'romantic') — includes both the value
--                     and the strict flags.
--   p_candidate    — the candidate user's actual attribute map (e.g. lifestyle,
--                     family, or religion map), or NULL for height (passed as
--                     p_candidate_height).
--   p_candidate_height — separate height param (actual users.height column).
--   p_filter_type  — one of: 'lifestyle', 'family', 'religion', 'height'
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_preference_filter(
    p_filters JSONB,
    p_candidate JSONB,
    p_candidate_height INTEGER,
    p_filter_type TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_strict BOOLEAN;
    v_values JSONB;
    v_candidate_val TEXT;
BEGIN
    IF p_filters IS NULL THEN
        RETURN TRUE;
    END IF;

    IF p_filter_type = 'lifestyle' THEN
        -- Smoking: single value ('any', 'never', 'ok')
        v_strict := COALESCE((p_filters ->> 'smoking_strict')::boolean, FALSE);
        IF v_strict THEN
            v_values := to_jsonb(p_filters ->> 'smoking');
            IF v_values IS NOT NULL AND v_values <> '"any"'::jsonb THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'smoking') IS NULL THEN
                    RETURN FALSE;
                END IF;
                IF LOWER(p_candidate ->> 'smoking') <> ALL (ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_values, '[]'::jsonb)))) THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

        -- Drinking: single value ('any', 'never', 'ok')
        v_strict := COALESCE((p_filters ->> 'drinking_strict')::boolean, FALSE);
        IF v_strict THEN
            v_values := to_jsonb(p_filters ->> 'drinking');
            IF v_values IS NOT NULL AND v_values <> '"any"'::jsonb THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'drinking') IS NULL THEN
                    RETURN FALSE;
                END IF;
                IF LOWER(p_candidate ->> 'drinking') <> ALL (ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_values, '[]'::jsonb)))) THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

        -- Diets: multi-select list (empty = any)
        v_strict := COALESCE((p_filters ->> 'diet_strict')::boolean, FALSE);
        IF v_strict THEN
            v_values := p_filters -> 'diets';
            IF v_values IS NOT NULL AND jsonb_array_length(v_values) > 0 THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'diet') IS NULL THEN
                    RETURN FALSE;
                END IF;
                IF NOT (v_values ? LOWER(p_candidate ->> 'diet')) THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

        -- Exercise: single value ('any', 'active', 'not_active')
        v_strict := COALESCE((p_filters ->> 'exercise_strict')::boolean, FALSE);
        IF v_strict THEN
            v_values := to_jsonb(p_filters ->> 'exercise');
            IF v_values IS NOT NULL AND v_values <> '"any"'::jsonb THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'exercise') IS NULL THEN
                    RETURN FALSE;
                END IF;
                IF LOWER(p_candidate ->> 'exercise') <> ALL (ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_values, '[]'::jsonb)))) THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

    ELSIF p_filter_type = 'family' THEN
        -- Has children: single value ('any', 'yes', 'no')
        v_strict := COALESCE((p_filters ->> 'has_children_strict')::boolean, FALSE);
        IF v_strict THEN
            v_values := to_jsonb(p_filters ->> 'has_children');
            IF v_values IS NOT NULL AND v_values <> '"any"'::jsonb THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'has_children') IS NULL THEN
                    RETURN FALSE;
                END IF;
                -- Candidate's has_children is stored as boolean in DB
                -- Convert to 'yes'/'no' for comparison
                IF (p_filters ->> 'has_children') = 'yes' AND (p_candidate ->> 'has_children')::boolean IS DISTINCT FROM TRUE THEN
                    RETURN FALSE;
                END IF;
                IF (p_filters ->> 'has_children') = 'no' AND (p_candidate ->> 'has_children')::boolean IS DISTINCT FROM FALSE THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

        -- Wants children: multi-select list (empty = any)
        v_strict := COALESCE((p_filters ->> 'wants_children_strict')::boolean, FALSE);
        IF v_strict THEN
            v_values := p_filters -> 'wants_children';
            IF v_values IS NOT NULL AND jsonb_array_length(v_values) > 0 THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'wants_children') IS NULL THEN
                    RETURN FALSE;
                END IF;
                IF NOT (v_values ? LOWER(p_candidate ->> 'wants_children')) THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

    ELSIF p_filter_type = 'religion' THEN
        -- Religions: multi-select list (empty = any)
        v_strict := COALESCE((p_filters ->> 'strict')::boolean, FALSE);
        IF v_strict THEN
            v_values := p_filters -> 'religions';
            IF v_values IS NOT NULL AND jsonb_array_length(v_values) > 0 THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'religion') IS NULL THEN
                    RETURN FALSE;
                END IF;
                IF NOT (v_values ? LOWER(p_candidate ->> 'religion')) THEN
                    RETURN FALSE;
                END IF;
            END IF;

            -- Same religion only flag (if true, candidate must match user's own religion)
            IF COALESCE((p_filters ->> 'same_religion')::boolean, FALSE) THEN
                -- This check requires knowing the user's own religion, which is
                -- NOT available in this function. The caller must handle 'same_religion'.
                NULL;
            END IF;
        END IF;

    ELSIF p_filter_type = 'height' THEN
        -- Height range with min/max
        v_strict := COALESCE((p_filters ->> 'strict')::boolean, FALSE);
        IF v_strict THEN
            IF p_candidate_height IS NULL THEN
                RETURN FALSE;
            END IF;
            IF (p_filters ? 'min') AND p_candidate_height < (p_filters ->> 'min')::numeric THEN
                RETURN FALSE;
            END IF;
            IF (p_filters ? 'max') AND p_candidate_height > (p_filters ->> 'max')::numeric THEN
                RETURN FALSE;
            END IF;
        END IF;
    END IF;

    RETURN TRUE;
END;
$$;

-------------------------------------------------------------------------------
-- 2) Helper: check all filter categories for both directions
-------------------------------------------------------------------------------
-- Checks whether user_a's profile satisfies user_b's filter preferences
-- (and vice versa) for a given intent key.
CREATE OR REPLACE FUNCTION public.are_filters_compatible(
    p_user_a_lifestyle    JSONB,
    p_user_a_family       JSONB,
    p_user_a_religion     JSONB,
    p_user_a_height       INTEGER,
    p_user_b_lifestyle    JSONB,
    p_user_b_family       JSONB,
    p_user_b_religion     JSONB,
    p_user_b_height       INTEGER,
    p_user_b_lifestyle_filters JSONB,   -- full lifestyle_filters column for user_b
    p_user_b_family_filters    JSONB,   -- full family_filters column for user_b
    p_user_b_religion_filters  JSONB,   -- full religion_filters column for user_b
    p_user_b_height_prefs      JSONB,   -- full height_preferences column for user_b
    p_user_a_lifestyle_filters JSONB,   -- full lifestyle_filters column for user_a
    p_user_a_family_filters    JSONB,   -- full family_filters column for user_a
    p_user_a_religion_filters  JSONB,   -- full religion_filters column for user_a
    p_user_a_height_prefs      JSONB,   -- full height_preferences column for user_a
    p_intent TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_b_lifestyle_filters JSONB;
    v_b_family_filters JSONB;
    v_b_religion_filters JSONB;
    v_b_height_prefs JSONB;
    v_a_lifestyle_filters JSONB;
    v_a_family_filters JSONB;
    v_a_religion_filters JSONB;
    v_a_height_prefs JSONB;
BEGIN
    -- Extract filters for the specific intent (or NULL if no filter block exists)
    v_b_lifestyle_filters := CASE WHEN p_user_b_lifestyle_filters ? p_intent
        THEN p_user_b_lifestyle_filters -> p_intent ELSE NULL END;
    v_b_family_filters := CASE WHEN p_user_b_family_filters ? p_intent
        THEN p_user_b_family_filters -> p_intent ELSE NULL END;
    v_b_religion_filters := CASE WHEN p_user_b_religion_filters ? p_intent
        THEN p_user_b_religion_filters -> p_intent ELSE NULL END;
    v_b_height_prefs := CASE WHEN p_user_b_height_prefs ? p_intent
        THEN p_user_b_height_prefs -> p_intent ELSE NULL END;

    v_a_lifestyle_filters := CASE WHEN p_user_a_lifestyle_filters ? p_intent
        THEN p_user_a_lifestyle_filters -> p_intent ELSE NULL END;
    v_a_family_filters := CASE WHEN p_user_a_family_filters ? p_intent
        THEN p_user_a_family_filters -> p_intent ELSE NULL END;
    v_a_religion_filters := CASE WHEN p_user_a_religion_filters ? p_intent
        THEN p_user_a_religion_filters -> p_intent ELSE NULL END;
    v_a_height_prefs := CASE WHEN p_user_a_height_prefs ? p_intent
        THEN p_user_a_height_prefs -> p_intent ELSE NULL END;

    -- Check: does user_a (candidate) satisfy user_b's filters?
    IF NOT public.check_preference_filter(v_b_lifestyle_filters, p_user_a_lifestyle, p_user_a_height, 'lifestyle') THEN
        RETURN FALSE;
    END IF;
    IF NOT public.check_preference_filter(v_b_family_filters, p_user_a_family, p_user_a_height, 'family') THEN
        RETURN FALSE;
    END IF;
    IF NOT public.check_preference_filter(v_b_religion_filters, p_user_a_religion, p_user_a_height, 'religion') THEN
        RETURN FALSE;
    END IF;
    IF NOT public.check_preference_filter(v_b_height_prefs, NULL, p_user_a_height, 'height') THEN
        RETURN FALSE;
    END IF;

    -- Check: does user_b (candidate) satisfy user_a's filters?
    IF NOT public.check_preference_filter(v_a_lifestyle_filters, p_user_b_lifestyle, p_user_b_height, 'lifestyle') THEN
        RETURN FALSE;
    END IF;
    IF NOT public.check_preference_filter(v_a_family_filters, p_user_b_family, p_user_b_height, 'family') THEN
        RETURN FALSE;
    END IF;
    IF NOT public.check_preference_filter(v_a_religion_filters, p_user_b_religion, p_user_b_height, 'religion') THEN
        RETURN FALSE;
    END IF;
    IF NOT public.check_preference_filter(v_a_height_prefs, NULL, p_user_b_height, 'height') THEN
        RETURN FALSE;
    END IF;

    RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_preference_filter(JSONB, JSONB, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_preference_filter(JSONB, JSONB, INTEGER, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.are_filters_compatible(JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.are_filters_compatible(JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, TEXT) TO anon;

-------------------------------------------------------------------------------
-- 3) Redefine perform_continuous_user_matching with filter checks
-------------------------------------------------------------------------------
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
    -- Filter compatibility variables
    current_user_lifestyle    JSONB;
    current_user_family       JSONB;
    current_user_religion     JSONB;
    current_user_height       INTEGER;
    other_user_lifestyle      JSONB;
    other_user_family         JSONB;
    other_user_religion       JSONB;
    other_user_height         INTEGER;
    current_user_lifestyle_filters JSONB;
    current_user_family_filters    JSONB;
    current_user_religion_filters  JSONB;
    current_user_height_prefs      JSONB;
    other_user_lifestyle_filters   JSONB;
    other_user_family_filters      JSONB;
    other_user_religion_filters    JSONB;
    other_user_height_prefs        JSONB;
    filters_compatible BOOLEAN := FALSE;
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
            strict_gender_age_enforcement,
            lifestyle,
            family,
            religion,
            height,
            lifestyle_filters,
            family_filters,
            religion_filters,
            height_preferences
        INTO current_user_gender, current_user_dob,
             current_user_gender_prefs, current_user_age_prefs, current_user_enforcement,
             current_user_lifestyle, current_user_family, current_user_religion,
             current_user_height,
             current_user_lifestyle_filters, current_user_family_filters,
             current_user_religion_filters, current_user_height_prefs
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
                   gender_preferences, age_preferences, strict_gender_age_enforcement,
                   lifestyle, family, religion, height,
                   lifestyle_filters, family_filters, religion_filters, height_preferences
            INTO other_user_intents, other_user_gender, other_user_dob,
                 other_user_gender_prefs, other_user_age_prefs, other_user_enforcement,
                 other_user_lifestyle, other_user_family, other_user_religion,
                 other_user_height,
                 other_user_lifestyle_filters, other_user_family_filters,
                 other_user_religion_filters, other_user_height_prefs
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
            pair_allowed := FALSE;
            <<intent_enforcement_loop>>
            FOREACH shared_intent IN ARRAY shared_intents LOOP
                a_strict_gender := public.get_enforcement_flag(other_user_enforcement, shared_intent, 'gender');
                a_strict_age    := public.get_enforcement_flag(other_user_enforcement, shared_intent, 'age');
                b_strict_gender := public.get_enforcement_flag(current_user_enforcement, shared_intent, 'gender');
                b_strict_age    := public.get_enforcement_flag(current_user_enforcement, shared_intent, 'age');

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

                -- Check lifestyle/family/religion/height filter compatibility
                filters_compatible := public.are_filters_compatible(
                    current_user_lifestyle, current_user_family,
                    current_user_religion, current_user_height,
                    other_user_lifestyle, other_user_family,
                    other_user_religion, other_user_height,
                    other_user_lifestyle_filters, other_user_family_filters,
                    other_user_religion_filters, other_user_height_prefs,
                    current_user_lifestyle_filters, current_user_family_filters,
                    current_user_religion_filters, current_user_height_prefs,
                    shared_intent
                );

                IF a_gender_ok AND a_age_ok AND b_gender_ok AND b_age_ok AND filters_compatible THEN
                    pair_allowed := TRUE;
                    EXIT intent_enforcement_loop;
                END IF;

                -- At least one side is strict and failing, so this is a flexible match.
                -- Allow it only if NEITHER side has a compliant candidate elsewhere.
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

-------------------------------------------------------------------------------
-- 4) Redefine perform_event_matching with filter checks
-------------------------------------------------------------------------------
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
    -- Filter compatibility variables
    user_a_lifestyle    JSONB;
    user_a_family       JSONB;
    user_a_religion     JSONB;
    user_a_height       INTEGER;
    user_b_lifestyle    JSONB;
    user_b_family       JSONB;
    user_b_religion     JSONB;
    user_b_height       INTEGER;
    user_a_lifestyle_filters JSONB;
    user_a_family_filters    JSONB;
    user_a_religion_filters  JSONB;
    user_a_height_prefs      JSONB;
    user_b_lifestyle_filters JSONB;
    user_b_family_filters    JSONB;
    user_b_religion_filters  JSONB;
    user_b_height_prefs      JSONB;
    filters_compatible BOOLEAN := FALSE;
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
               strict_gender_age_enforcement,
               lifestyle, family, religion, height,
               lifestyle_filters, family_filters, religion_filters, height_preferences
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
        user_a_lifestyle := user_a_data.lifestyle;
        user_a_family := user_a_data.family;
        user_a_religion := user_a_data.religion;
        user_a_height := user_a_data.height;
        user_a_lifestyle_filters := user_a_data.lifestyle_filters;
        user_a_family_filters := user_a_data.family_filters;
        user_a_religion_filters := user_a_data.religion_filters;
        user_a_height_prefs := user_a_data.height_preferences;
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
                   strict_gender_age_enforcement,
                   lifestyle, family, religion, height,
                   lifestyle_filters, family_filters, religion_filters, height_preferences
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
            user_b_lifestyle := user_b_data.lifestyle;
            user_b_family := user_b_data.family;
            user_b_religion := user_b_data.religion;
            user_b_height := user_b_data.height;
            user_b_lifestyle_filters := user_b_data.lifestyle_filters;
            user_b_family_filters := user_b_data.family_filters;
            user_b_religion_filters := user_b_data.religion_filters;
            user_b_height_prefs := user_b_data.height_preferences;
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

            -- Per-intent enforcement check.
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

                -- Check lifestyle/family/religion/height filter compatibility
                filters_compatible := public.are_filters_compatible(
                    user_a_lifestyle, user_a_family,
                    user_a_religion, user_a_height,
                    user_b_lifestyle, user_b_family,
                    user_b_religion, user_b_height,
                    user_b_lifestyle_filters, user_b_family_filters,
                    user_b_religion_filters, user_b_height_prefs,
                    user_a_lifestyle_filters, user_a_family_filters,
                    user_a_religion_filters, user_a_height_prefs,
                    shared_intent
                );

                IF a_gender_ok AND a_age_ok AND b_gender_ok AND b_age_ok AND filters_compatible THEN
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
