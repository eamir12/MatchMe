-- Migration: Simplify matching — remove per-field strict flags, handle array format for all fields
-- Date: 2026-07-08
-- Purpose: The old system had per-field *_strict booleans that the UI no longer sets.
--   Now each field's filter is an array of values. 'any' or empty means "don't filter";
--   specific values mean "must match one of these". Backward compat handles old
--   single-string format where the UI used to store e.g. "smoking": "never".

BEGIN;

------------------------------------------------------------------------------
-- 1) Replace check_preference_filter — no strict flags, all fields as arrays
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
        -- Height: min/max range (always enforced when present)
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
-- 2) Helper: extract filter values as text[], handling both array and single-string formats.
--    Returns NULL when the filter is 'any'/empty (i.e. no filtering).
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

    -- Array format (new)
    IF jsonb_typeof(v_raw) = 'array' THEN
        IF jsonb_array_length(v_raw) = 0 THEN
            RETURN NULL;
        END IF;
        -- If the only element is 'any', treat as no filter
        IF jsonb_array_length(v_raw) = 1 AND (v_raw ->> 0) = 'any' THEN
            RETURN NULL;
        END IF;
        RETURN ARRAY(SELECT jsonb_array_elements_text(v_raw) WHERE jsonb_array_elements_text <> 'any');
    END IF;

    -- Single string format (old backward compat)
    v_val := p_filters ->> p_key;
    IF v_val IS NULL OR v_val = 'any' THEN
        RETURN NULL;
    END IF;
    RETURN ARRAY[v_val];
END;
$$;

------------------------------------------------------------------------------
-- 3) Replace are_filters_compatible — calls updated check_preference_filter
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
BEGIN
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
GRANT EXECUTE ON FUNCTION public._filter_values(JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public._filter_values(JSONB, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.are_filters_compatible(JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.are_filters_compatible(JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, TEXT) TO anon;

COMMIT;
