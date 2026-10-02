-- Migration: Add "Any" filter option for diet and religion
-- Date: 2026-07-08

BEGIN;

INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('diet', 'any_diet', NULL, 'any',
   '', 'settingsDietAny', 0, 0),
  ('religion', 'any_religion', NULL, 'any',
   '', 'settingsReligionAny', 0, 0)
ON CONFLICT (field_key, option_key) DO NOTHING;

COMMIT;
