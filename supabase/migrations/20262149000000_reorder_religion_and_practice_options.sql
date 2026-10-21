-- Migration: Order the religion "Other" option last and the practice
--          frequency options from least often to most often.
-- Date: 2026-10-21
-- Purpose:
--   * "Other" is the catch-all option: it is the choice for users who do not
--     want any of the options listed above it, so it must always be the last
--     option of the list (for religions and for each religion's branches).
--   * The practice frequency question is answered on a scale that goes from
--     least often to most often:
--     rarely_or_never, few_times_a_year, monthly, weekly, daily.

BEGIN;

-- Religion: the catch-all "Other" option always goes last.
UPDATE public.app_profile_options
SET profile_sort_order = 9999,
    filter_sort_order = 9999
WHERE field_key = 'religion'
  AND option_key = 'other';

-- Denominations: each "other" branch is the catch-all of its religion.
UPDATE public.app_profile_options
SET profile_sort_order = 9999,
    filter_sort_order = 9999
WHERE field_key = 'denomination'
  AND right(option_key, 6) = '__other';

-- Practice frequency: least often -> most often.
UPDATE public.app_profile_options
SET profile_sort_order = 1,
    filter_sort_order = 1
WHERE field_key = 'practice'
  AND option_key = 'rarely_or_never';

UPDATE public.app_profile_options
SET profile_sort_order = 2,
    filter_sort_order = 2
WHERE field_key = 'practice'
  AND option_key = 'few_times_a_year';

UPDATE public.app_profile_options
SET profile_sort_order = 3,
    filter_sort_order = 3
WHERE field_key = 'practice'
  AND option_key = 'monthly';

UPDATE public.app_profile_options
SET profile_sort_order = 4,
    filter_sort_order = 4
WHERE field_key = 'practice'
  AND option_key = 'weekly';

UPDATE public.app_profile_options
SET profile_sort_order = 5,
    filter_sort_order = 5
WHERE field_key = 'practice'
  AND option_key = 'daily';

COMMIT;
