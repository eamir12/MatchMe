-- Migration: Add "religiosity" (degree religious or spiritual) profile question
--   and matching filter.
-- Date: 2026-10-20
-- Purpose:
--   * New app_profile_options field `religiosity` for the profile wizard
--     question "How religious or spiritual are you?" and the Beliefs filter.
--   * Stored inside the existing user_profiles.religion JSONB map under the
--     `religiosity` key (no new column needed).
--   * Filter values live inside intent_preferences.religion_filters -> intent
--     under the `religiosity` array, exactly like `religions`.
--   * check_preference_filter now enforces the religiosity filter so the
--     server-side matching (proximity/event/retro) honours it.
-- English fallbacks are in lib/providers/locale_provider.dart::
--   _defaultTranslations.

BEGIN;

------------------------------------------------------------------------------
-- 1) Seed app_profile_options for religiosity
------------------------------------------------------------------------------
INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('religiosity', 'any_religiosity', NULL, 'any',
   '',                             'settingsReligiosityAny',             0, 1),
  ('religiosity', 'very_religious', 'Very religious', 'very religious',
   'religiosityVeryReligious',     'religiosityVeryReligious',           1, 2),
  ('religiosity', 'moderately_religious', 'Moderately religious', 'moderately religious',
   'religiosityModeratelyReligious', 'religiosityModeratelyReligious',   2, 3),
  ('religiosity', 'spiritual_not_religious', 'Spiritual but not religious', 'spiritual but not religious',
   'religiositySpiritualNotReligious', 'religiositySpiritualNotReligious', 3, 4),
  ('religiosity', 'not_religious', 'Not religious', 'not religious',
   'religiosityNotReligious',      'religiosityNotReligious',            4, 5),
  ('religiosity', 'prefer_not_to_say', 'Prefer not to say', NULL,
   'religiosityPreferNotToSay',    '',                                   5, 0)
ON CONFLICT (field_key, option_key) DO NOTHING;

------------------------------------------------------------------------------
-- 2) Translations (en/es/he)
------------------------------------------------------------------------------
INSERT INTO public.translations (locale, key, value) VALUES
  -- English
  ('en', 'profileReligiosity', $$Religiousness$$),
  ('en', 'profileWizardReligiosityQuestion', $$How religious or spiritual are you?$$),
  ('en', 'profileWizardReligionSubtitle',
   $$Share your religious affiliation and how religious or spiritual you are, or skip if you prefer not to say.$$),
  ('en', 'settingsReligiosity', $$Religiousness$$),
  ('en', 'settingsReligiosityAny', $$Any$$),
  ('en', 'religiosityVeryReligious', $$Very religious$$),
  ('en', 'religiosityModeratelyReligious', $$Moderately religious$$),
  ('en', 'religiositySpiritualNotReligious', $$Spiritual but not religious$$),
  ('en', 'religiosityNotReligious', $$Not religious$$),
  ('en', 'religiosityPreferNotToSay', $$Prefer not to say$$),
  ('en', 'religiosityNotSpecified', $$Not specified$$),
  ('en', 'voiceGuidanceStepReligion',
   $$Choose your religious background and how religious or spiritual you are, then tap Next.$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Spanish
  ('es', 'profileReligiosity', $$Religiosidad$$),
  ('es', 'profileWizardReligiosityQuestion', $$¿Qué tan religioso o espiritual eres?$$),
  ('es', 'profileWizardReligionSubtitle',
   $$Comparte tu afiliación religiosa y qué tan religioso o espiritual eres, o omite si prefieres no decirlo.$$),
  ('es', 'settingsReligiosity', $$Religiosidad$$),
  ('es', 'settingsReligiosityAny', $$Cualquiera$$),
  ('es', 'religiosityVeryReligious', $$Muy religioso$$),
  ('es', 'religiosityModeratelyReligious', $$Moderadamente religioso$$),
  ('es', 'religiositySpiritualNotReligious', $$Espiritual pero no religioso$$),
  ('es', 'religiosityNotReligious', $$No religioso$$),
  ('es', 'religiosityPreferNotToSay', $$Prefiero no decirlo$$),
  ('es', 'religiosityNotSpecified', $$Sin especificar$$),
  ('es', 'voiceGuidanceStepReligion',
   $$Elige tu religión y qué tan religioso o espiritual eres, luego toca Siguiente.$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Hebrew
  ('he', 'profileReligiosity', $$מידת הדתיות$$),
  ('he', 'profileWizardReligiosityQuestion', $$מהי מידת הדתיות או הרוחניות שלך?$$),
  ('he', 'profileWizardReligionSubtitle',
   $$שתף את ההשתייכות הדתית שלך ואת מידת הדתיות או הרוחניות שלך, או דלג אם אתה מעדיף לא לומר.$$),
  ('he', 'settingsReligiosity', $$מידת הדתיות$$),
  ('he', 'settingsReligiosityAny', $$הכל$$),
  ('he', 'religiosityVeryReligious', $$דתי מאוד$$),
  ('he', 'religiosityModeratelyReligious', $$דתי במידה בינונית$$),
  ('he', 'religiositySpiritualNotReligious', $$רוחני אך לא דתי$$),
  ('he', 'religiosityNotReligious', $$לא דתי$$),
  ('he', 'religiosityPreferNotToSay', $$מעדיף לא לומר$$),
  ('he', 'religiosityNotSpecified', $$לא צוין$$),
  ('he', 'voiceGuidanceStepReligion',
   $$בחר את הרקע הדתי שלך ואת מידת הדתיות או הרוחניות שלך, ואז הקש הבא.$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

------------------------------------------------------------------------------
-- 3) check_preference_filter — enforce the religiosity filter alongside the
--    religion filter (both live under the same per-intent filter map).
--    Based on the canonical version in
--    20262067000000_restrict_height_filter_to_romantic_intent.sql.
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

        -- Religiosity / degree religious or spiritual (stored as
        -- 'religiosity' key inside the same candidate religion map)
        v_vals := _filter_values(p_filters, 'religiosity');
        IF v_vals IS NOT NULL AND array_length(v_vals, 1) > 0 THEN
            IF p_candidate IS NULL OR (p_candidate ->> 'religiosity') IS NULL THEN
                RETURN FALSE;
            END IF;
            IF NOT (LOWER(p_candidate ->> 'religiosity') = ANY (v_vals)) THEN
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

GRANT EXECUTE ON FUNCTION public.check_preference_filter(JSONB, JSONB, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_preference_filter(JSONB, JSONB, INTEGER, TEXT) TO anon;

COMMIT;
