-- Migration: Restrict the height preference filter to the Romantic intent only
-- Date: 2026-09-26
-- Purpose: Height is only collected from users who picked the Romantic intent
--   (lib/screens/profile/profile_wizard_screen.dart gates the height field on
--   hasRomanticIntent, and the height range sliders on isRomantic). Enforce the
--   same rule inside the matching logic itself so a height restriction can never
--   block a Friendship, Activity Partner or Business/Networking match, even if a
--   stale non-romantic entry survives in intent_preferences->'height_preferences'.
--
--   Every matching path (proximity/continuous, event, retroactive) funnels
--   through public.are_filters_compatible, so gating there is authoritative.

BEGIN;

------------------------------------------------------------------------------
-- 1) Helper: is this intent a Romantic intent (main key or a "romantic::" sub-intent)?
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._is_romantic_intent(p_intent TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_key TEXT;
BEGIN
    IF p_intent IS NULL THEN
        RETURN FALSE;
    END IF;
    v_key := LOWER(BTRIM(p_intent));
    IF v_key = '' THEN
        RETURN FALSE;
    END IF;
    -- Sub-intents are stored as "romantic::<sub_key>"; strip the suffix.
    v_key := SPLIT_PART(v_key, '::', 1);
    RETURN v_key = 'romantic';
END;
$$;

COMMENT ON FUNCTION public._is_romantic_intent(TEXT) IS
    'True when the intent key is the Romantic intent (or one of its sub-intents). Height preferences apply to Romantic matching only.';

GRANT EXECUTE ON FUNCTION public._is_romantic_intent(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public._is_romantic_intent(TEXT) TO anon;

------------------------------------------------------------------------------
-- 2) check_preference_filter — an empty height filter means "no restriction".
--    Previously only a SQL NULL short-circuited to TRUE, so an empty JSONB
--    object (e.g. COALESCE(prefs -> 'height_preferences' -> intent, '{}'))
--    still fell into the height branch and rejected candidates with no height
--    on disk even though no range had been configured.
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_preference_filter(
    p_filters JSONB,
    p_candidate JSONB,
    p_candidate_height INTEGER,
    p_filter_type TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_vals TEXT[];
    v_filter_val TEXT;
BEGIN
    IF p_filters IS NULL THEN
        RETURN TRUE;
    END IF;

    IF p_filter_type = 'lifestyle' THEN
        -- Smoking
        v_vals := _filter_values(p_filters, 'smoking');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'smoking') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'smoking') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

        -- Drinking
        v_vals := _filter_values(p_filters, 'drinking');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'drinking') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'drinking') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

        -- Diet (stored as 'diets' key)
        v_vals := _filter_values(p_filters, 'diets');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'diet') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'diet') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

        -- Exercise
        v_vals := _filter_values(p_filters, 'exercise');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'exercise') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'exercise') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

    ELSIF p_filter_type = 'family' THEN
        -- Has children (stored as boolean string in DB, filter uses 'yes'/'no')
        v_vals := _filter_values(p_filters, 'has_children');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'has_children') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF 'yes' = ANY(v_vals) AND (p_candidate ->> 'has_children')::boolean IS DISTINCT FROM TRUE THEN
                RETURN FALSE;
            END IF;
            IF 'no' = ANY(v_vals) AND (p_candidate ->> 'has_children')::boolean IS DISTINCT FROM FALSE THEN
                RETURN FALSE;
            END IF;
        END IF;

        -- Wants children
        v_vals := _filter_values(p_filters, 'wants_children');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'wants_children') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'wants_children') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

    ELSIF p_filter_type = 'religion' THEN
        -- Religions (stored as 'religions' key)
        v_vals := _filter_values(p_filters, 'religions');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'religion') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'religion') = ANY (v_vals)) THEN
                RETURN FALSE;
            END IF;
        END IF;

    ELSIF p_filter_type = 'height' THEN
        -- No range configured → height is not a criterion at all.
        IF NOT (p_filters ? 'min') AND NOT (p_filters ? 'max') THEN
            RETURN TRUE;
        END IF;
        -- A range is configured, so the candidate must have a height in range.
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

    RETURN TRUE;
END;
$$;

------------------------------------------------------------------------------
-- 3) are_filters_compatible — height is only evaluated for Romantic.
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.are_filters_compatible(
    p_user_a_lifestyle    JSONB,
    p_user_a_family       JSONB,
    p_user_a_religion     JSONB,
    p_user_a_height       INTEGER,
    p_user_b_lifestyle    JSONB,
    p_user_b_family       JSONB,
    p_user_b_religion     JSONB,
    p_user_b_height       INTEGER,
    p_user_b_lifestyle_filters JSONB,
    p_user_b_family_filters    JSONB,
    p_user_b_religion_filters  JSONB,
    p_user_b_height_prefs      JSONB,
    p_user_a_lifestyle_filters JSONB,
    p_user_a_family_filters    JSONB,
    p_user_a_religion_filters  JSONB,
    p_user_a_height_prefs      JSONB,
    p_intent TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
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
    v_enforce_height BOOLEAN;
BEGIN
    v_b_lifestyle_filters := CASE WHEN p_user_b_lifestyle_filters ? p_intent
        THEN p_user_b_lifestyle_filters -> p_intent ELSE NULL END;
    v_b_family_filters := CASE WHEN p_user_b_family_filters ? p_intent
        THEN p_user_b_family_filters -> p_intent ELSE NULL END;
    v_b_religion_filters := CASE WHEN p_user_b_religion_filters ? p_intent
        THEN p_user_b_religion_filters -> p_intent ELSE NULL END;

    v_a_lifestyle_filters := CASE WHEN p_user_a_lifestyle_filters ? p_intent
        THEN p_user_a_lifestyle_filters -> p_intent ELSE NULL END;
    v_a_family_filters := CASE WHEN p_user_a_family_filters ? p_intent
        THEN p_user_a_family_filters -> p_intent ELSE NULL END;
    v_a_religion_filters := CASE WHEN p_user_a_religion_filters ? p_intent
        THEN p_user_a_religion_filters -> p_intent ELSE NULL END;

    IF NOT public.check_preference_filter(v_b_lifestyle_filters, p_user_a_lifestyle, p_user_a_height, 'lifestyle') THEN
        RETURN FALSE;
    END IF;
    IF NOT public.check_preference_filter(v_b_family_filters, p_user_a_family, p_user_a_height, 'family') THEN
        RETURN FALSE;
    END IF;
    IF NOT public.check_preference_filter(v_b_religion_filters, p_user_a_religion, p_user_a_height, 'religion') THEN
        RETURN FALSE;
    END IF;

    IF NOT public.check_preference_filter(v_a_lifestyle_filters, p_user_b_lifestyle, p_user_b_height, 'lifestyle') THEN
        RETURN FALSE;
    END IF;
    IF NOT public.check_preference_filter(v_a_family_filters, p_user_b_family, p_user_b_height, 'family') THEN
        RETURN FALSE;
    END IF;
    IF NOT public.check_preference_filter(v_a_religion_filters, p_user_b_religion, p_user_b_height, 'religion') THEN
        RETURN FALSE;
    END IF;

    -- Height is only a matching criterion for the Romantic intent. For
    -- friendship / activity_partner / business_networking it is ignored
    -- outright, so neither a saved range nor a missing height can block a match.
    v_enforce_height := public._is_romantic_intent(p_intent);
    IF v_enforce_height THEN
        v_b_height_prefs := CASE WHEN p_user_b_height_prefs ? p_intent
            THEN p_user_b_height_prefs -> p_intent ELSE NULL END;
        v_a_height_prefs := CASE WHEN p_user_a_height_prefs ? p_intent
            THEN p_user_a_height_prefs -> p_intent ELSE NULL END;

        IF NOT public.check_preference_filter(v_b_height_prefs, NULL, p_user_a_height, 'height') THEN
            RETURN FALSE;
        END IF;
        IF NOT public.check_preference_filter(v_a_height_prefs, NULL, p_user_b_height, 'height') THEN
            RETURN FALSE;
        END IF;
    END IF;

    RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_preference_filter(JSONB, JSONB, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_preference_filter(JSONB, JSONB, INTEGER, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.are_filters_compatible(JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.are_filters_compatible(JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, TEXT) TO anon;

------------------------------------------------------------------------------
-- 4) Data hygiene: drop height_preferences entries stored under a
--    non-romantic intent. Those were only ever reachable because the filter
--    was intent-scoped rather than intent-restricted; keeping them would make
--    the admin match inspector report stale height blockers.
------------------------------------------------------------------------------
UPDATE public.user_profiles
SET intent_preferences = jsonb_set(
        COALESCE(intent_preferences, '{}'::jsonb),
        '{height_preferences}',
        COALESCE(
            NULLIF(
                (
                    SELECT jsonb_object_agg(hp.key, hp.value)
                    FROM jsonb_each(COALESCE(intent_preferences -> 'height_preferences', '{}'::jsonb)) AS hp(key, value)
                    WHERE public._is_romantic_intent(hp.key)
                ),
                '{}'::jsonb
            ),
            '{}'::jsonb
        ),
        true
    )
WHERE COALESCE(intent_preferences -> 'height_preferences', '{}'::jsonb) <> '{}'::jsonb
  AND EXISTS (
        SELECT 1
        FROM jsonb_object_keys(COALESCE(intent_preferences -> 'height_preferences', '{}'::jsonb)) AS hp_key
        WHERE NOT public._is_romantic_intent(hp_key)
    );

COMMIT;
