-- Migration: Make filter options identical to profile options (1:1 mapping)
-- Date: 2026-07-08
-- Purpose: Each profile value now maps to its own unique filter value so
--   the filter UI shows the same options as the profile UI. The old
--   aggregated mapping (e.g. Sometimes→ok, Regularly→ok) is removed.

BEGIN;

-- ── Smoking: 1:1 mapping ──
UPDATE public.app_profile_options
SET filter_value = 'sometimes',
    filter_display_key = 'lifestyleSmokingSometimes'
WHERE field_key = 'smoking' AND option_key = 'sometimes';

UPDATE public.app_profile_options
SET filter_value = 'regularly',
    filter_display_key = 'lifestyleSmokingRegularly'
WHERE field_key = 'smoking' AND option_key = 'regularly';

DELETE FROM public.app_profile_options
WHERE field_key = 'smoking' AND option_key = 'ok_smoking';

-- ── Drinking: 1:1 mapping ──
UPDATE public.app_profile_options
SET filter_value = 'socially',
    filter_display_key = 'lifestyleDrinkingSocially'
WHERE field_key = 'drinking' AND option_key = 'socially';

UPDATE public.app_profile_options
SET filter_value = 'regularly',
    filter_display_key = 'lifestyleDrinkingRegularly'
WHERE field_key = 'drinking' AND option_key = 'regularly';

DELETE FROM public.app_profile_options
WHERE field_key = 'drinking' AND option_key = 'ok_drinking';

-- ── Exercise: 1:1 mapping ──
UPDATE public.app_profile_options
SET filter_value = 'never',
    filter_display_key = 'lifestyleExerciseNever'
WHERE field_key = 'exercise' AND option_key = 'never';

UPDATE public.app_profile_options
SET filter_value = 'sometimes',
    filter_display_key = 'lifestyleExerciseSometimes'
WHERE field_key = 'exercise' AND option_key = 'sometimes';

UPDATE public.app_profile_options
SET filter_value = 'regularly',
    filter_display_key = 'lifestyleExerciseRegularly'
WHERE field_key = 'exercise' AND option_key = 'regularly';

UPDATE public.app_profile_options
SET filter_value = 'daily',
    filter_display_key = 'lifestyleExerciseDaily'
WHERE field_key = 'exercise' AND option_key = 'daily';

DELETE FROM public.app_profile_options
WHERE field_key = 'exercise' AND option_key IN ('active_exercise', 'not_active_exercise');

COMMIT;
