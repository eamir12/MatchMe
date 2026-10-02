-- Migration: Update matching functions to use app_profile_options table
-- Date: 2026-07-08
-- Purpose: The check_preference_filter helper now queries the
--   app_profile_options table to find which profile_values correspond to
--   each filter_value, rather than using hardcoded comparison logic.
--   This means admins can add/edit options in the table and matching
--   automatically adapts.

BEGIN;

-------------------------------------------------------------------------------
-- 1) Replace check_preference_filter — now STABLE, queries mapping table
-------------------------------------------------------------------------------
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
    v_strict BOOLEAN;
    v_field_key TEXT;
    v_filter_val TEXT;
    v_matching_profile_values TEXT[];
BEGIN
    IF p_filters IS NULL THEN
        RETURN TRUE;
    END IF;

    -- Determine the field_key and resolve single-value vs multi-value
    IF p_filter_type = 'lifestyle' THEN
        -- Smoking (single value)
        v_strict := COALESCE((p_filters ->> 'smoking_strict')::boolean, FALSE);
        IF v_strict THEN
            v_filter_val := p_filters ->> 'smoking';
            IF v_filter_val IS NOT NULL AND v_filter_val <> 'any' THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'smoking') IS NULL THEN
                    RETURN FALSE;
                END IF;
                SELECT ARRAY_AGG(LOWER(profile_value))
                INTO v_matching_profile_values
                FROM app_profile_options
                WHERE field_key = 'smoking' AND filter_value = v_filter_val AND profile_value IS NOT NULL;
                IF NOT (LOWER(p_candidate ->> 'smoking') = ANY (v_matching_profile_values)) THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

        -- Drinking (single value)
        v_strict := COALESCE((p_filters ->> 'drinking_strict')::boolean, FALSE);
        IF v_strict THEN
            v_filter_val := p_filters ->> 'drinking';
            IF v_filter_val IS NOT NULL AND v_filter_val <> 'any' THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'drinking') IS NULL THEN
                    RETURN FALSE;
                END IF;
                SELECT ARRAY_AGG(LOWER(profile_value))
                INTO v_matching_profile_values
                FROM app_profile_options
                WHERE field_key = 'drinking' AND filter_value = v_filter_val AND profile_value IS NOT NULL;
                IF NOT (LOWER(p_candidate ->> 'drinking') = ANY (v_matching_profile_values)) THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

        -- Diets (multi-select)
        v_strict := COALESCE((p_filters ->> 'diet_strict')::boolean, FALSE);
        IF v_strict THEN
            IF p_filters -> 'diets' IS NOT NULL AND jsonb_array_length(p_filters -> 'diets') > 0 THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'diet') IS NULL THEN
                    RETURN FALSE;
                END IF;
                -- Check if any selected filter value maps to the candidate's profile value
                SELECT COUNT(*) > 0 INTO v_strict
                FROM app_profile_options
                WHERE field_key = 'diet'
                  AND filter_value IN (SELECT jsonb_array_elements_text(p_filters -> 'diets'))
                  AND profile_value IS NOT NULL
                  AND LOWER(profile_value) = LOWER(p_candidate ->> 'diet');
                IF NOT v_strict THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

        -- Exercise (single value)
        v_strict := COALESCE((p_filters ->> 'exercise_strict')::boolean, FALSE);
        IF v_strict THEN
            v_filter_val := p_filters ->> 'exercise';
            IF v_filter_val IS NOT NULL AND v_filter_val <> 'any' THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'exercise') IS NULL THEN
                    RETURN FALSE;
                END IF;
                SELECT ARRAY_AGG(LOWER(profile_value))
                INTO v_matching_profile_values
                FROM app_profile_options
                WHERE field_key = 'exercise' AND filter_value = v_filter_val AND profile_value IS NOT NULL;
                IF NOT (LOWER(p_candidate ->> 'exercise') = ANY (v_matching_profile_values)) THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

    ELSIF p_filter_type = 'family' THEN
        -- Has children (single value: 'any', 'yes', 'no')
        v_strict := COALESCE((p_filters ->> 'has_children_strict')::boolean, FALSE);
        IF v_strict THEN
            v_filter_val := p_filters ->> 'has_children';
            IF v_filter_val IS NOT NULL AND v_filter_val <> 'any' THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'has_children') IS NULL THEN
                    RETURN FALSE;
                END IF;
                -- has_children is stored as boolean; filter uses 'yes'/'no' strings
                IF v_filter_val = 'yes' AND (p_candidate ->> 'has_children')::boolean IS DISTINCT FROM TRUE THEN
                    RETURN FALSE;
                END IF;
                IF v_filter_val = 'no' AND (p_candidate ->> 'has_children')::boolean IS DISTINCT FROM FALSE THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

        -- Wants children (multi-select)
        v_strict := COALESCE((p_filters ->> 'wants_children_strict')::boolean, FALSE);
        IF v_strict THEN
            IF p_filters -> 'wants_children' IS NOT NULL AND jsonb_array_length(p_filters -> 'wants_children') > 0 THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'wants_children') IS NULL THEN
                    RETURN FALSE;
                END IF;
                SELECT COUNT(*) > 0 INTO v_strict
                FROM app_profile_options
                WHERE field_key = 'wants_children'
                  AND filter_value IN (SELECT jsonb_array_elements_text(p_filters -> 'wants_children'))
                  AND profile_value IS NOT NULL
                  AND LOWER(profile_value) = LOWER(p_candidate ->> 'wants_children');
                IF NOT v_strict THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

    ELSIF p_filter_type = 'religion' THEN
        -- Religions (multi-select)
        v_strict := COALESCE((p_filters ->> 'strict')::boolean, FALSE);
        IF v_strict THEN
            IF p_filters -> 'religions' IS NOT NULL AND jsonb_array_length(p_filters -> 'religions') > 0 THEN
                IF p_candidate IS NULL OR (p_candidate ->> 'religion') IS NULL THEN
                    RETURN FALSE;
                END IF;
                SELECT COUNT(*) > 0 INTO v_strict
                FROM app_profile_options
                WHERE field_key = 'religion'
                  AND filter_value IN (SELECT jsonb_array_elements_text(p_filters -> 'religions'))
                  AND profile_value IS NOT NULL
                  AND LOWER(profile_value) = LOWER(p_candidate ->> 'religion');
                IF NOT v_strict THEN
                    RETURN FALSE;
                END IF;
            END IF;
        END IF;

    ELSIF p_filter_type = 'height' THEN
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
-- 2) Replace are_filters_compatible — now STABLE (calls STABLE function)
-------------------------------------------------------------------------------
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
GRANT EXECUTE ON FUNCTION public.are_filters_compatible(JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.are_filters_compatible(JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, INTEGER, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, JSONB, TEXT) TO anon;

COMMIT;
