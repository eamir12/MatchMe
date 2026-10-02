-- Migration: Create app_profile_options table for dynamic profile/filter options
-- Date: 2026-07-08
-- Purpose: Replace hardcoded option lists for lifestyle, family, religion,
--   and education fields with a database-backed table so admins can add/edit/
--   delete options without releasing a new app version.
--
-- Each row represents one conceptual option for a given field. The profile_value
-- is what gets stored in the user's profile column; the filter_value is what
-- gets stored in the filter preferences. Multiple rows can share the same
-- filter_value (e.g. "Sometimes" and "Regularly" both map to filter "ok").
-- Rows with NULL profile_value are filter-only; rows with NULL filter_value are
-- profile-only.

BEGIN;

CREATE TABLE IF NOT EXISTS public.app_profile_options (
  id SERIAL PRIMARY KEY,
  field_key TEXT NOT NULL,
  option_key TEXT NOT NULL,
  profile_value TEXT,
  filter_value TEXT,
  profile_display_key TEXT NOT NULL DEFAULT '',
  filter_display_key TEXT NOT NULL DEFAULT '',
  profile_sort_order INTEGER NOT NULL DEFAULT 0,
  filter_sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(field_key, option_key)
);

CREATE INDEX IF NOT EXISTS idx_app_profile_options_field_key
  ON public.app_profile_options(field_key);

COMMENT ON TABLE public.app_profile_options IS
  'Dynamic option definitions for profile and filter fields. '
  'Mapping: profile_value is stored in user profile columns; '
  'filter_value is stored in filter preference columns. '
  'Multiple profile_values can share a filter_value for matching.';

-------------------------------------------------------------------------------
-- Seed data: smoking
-------------------------------------------------------------------------------
INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('smoking', 'never',       'Never',     'never',
   'lifestyleSmokingNever',  'settingsSmokingNever',  1, 2),
  ('smoking', 'sometimes',   'Sometimes', 'ok',
   'lifestyleSmokingSometimes', '',                    2, 0),
  ('smoking', 'regularly',   'Regularly', 'ok',
   'lifestyleSmokingRegularly', '',                    3, 0),
  ('smoking', 'any_smoking', NULL,        'any',
   '',                        'settingsSmokingAny',    0, 1),
  ('smoking', 'ok_smoking',  NULL,        'ok',
   '',                        'settingsSmokingOk',     0, 3)
ON CONFLICT (field_key, option_key) DO NOTHING;

-------------------------------------------------------------------------------
-- Seed data: drinking
-------------------------------------------------------------------------------
INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('drinking', 'never',        'Never',     'never',
   'lifestyleDrinkingNever',   'settingsDrinkingNever',  1, 2),
  ('drinking', 'socially',     'Socially',  'ok',
   'lifestyleDrinkingSocially', '',                       2, 0),
  ('drinking', 'regularly',    'Regularly', 'ok',
   'lifestyleDrinkingRegularly', '',                      3, 0),
  ('drinking', 'any_drinking', NULL,        'any',
   '',                         'settingsDrinkingAny',    0, 1),
  ('drinking', 'ok_drinking',  NULL,        'ok',
   '',                         'settingsDrinkingOk',     0, 3)
ON CONFLICT (field_key, option_key) DO NOTHING;

-------------------------------------------------------------------------------
-- Seed data: diet
-------------------------------------------------------------------------------
INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('diet', 'anything',    'Anything',   NULL,
   'lifestyleDietAnything', '',                         1, 0),
  ('diet', 'vegetarian',  'Vegetarian', 'vegetarian',
   'lifestyleDietVegetarian', 'settingsDietVegetarian', 2, 1),
  ('diet', 'vegan',       'Vegan',      'vegan',
   'lifestyleDietVegan',      'settingsDietVegan',      3, 2),
  ('diet', 'halal',       'Halal',      'halal',
   'lifestyleDietHalal',      'settingsDietHalal',      4, 3),
  ('diet', 'kosher',      'Kosher',     'kosher',
   'lifestyleDietKosher',     'settingsDietKosher',     5, 4)
ON CONFLICT (field_key, option_key) DO NOTHING;

-------------------------------------------------------------------------------
-- Seed data: exercise
-------------------------------------------------------------------------------
INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('exercise', 'never',        'Never',     'not_active',
   'lifestyleExerciseNever',   '',                          1, 0),
  ('exercise', 'sometimes',    'Sometimes', 'active',
   'lifestyleExerciseSometimes', '',                        2, 0),
  ('exercise', 'regularly',    'Regularly', 'active',
   'lifestyleExerciseRegularly', '',                        3, 0),
  ('exercise', 'daily',        'Daily',     'active',
   'lifestyleExerciseDaily',    '',                          4, 0),
  ('exercise', 'any_exercise', NULL,        'any',
   '',                          'settingsExerciseAny',      0, 1),
  ('exercise', 'active_exercise', NULL,     'active',
   '',                          'settingsExerciseActive',   0, 2),
  ('exercise', 'not_active_exercise', NULL, 'not_active',
   '',                          'settingsExerciseNotActive',0, 3)
ON CONFLICT (field_key, option_key) DO NOTHING;

-------------------------------------------------------------------------------
-- Seed data: has_children (stored as boolean string in profile)
-------------------------------------------------------------------------------
INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('has_children', 'yes',          'true',  'yes',
   'profileYes',                   'settingsHasChildrenYes', 1, 2),
  ('has_children', 'no',           'false', 'no',
   'profileNo',                    'settingsHasChildrenNo',  2, 3),
  ('has_children', 'prefer_not',   '',      NULL,
   'familyPreferNotToSay',         '',                        3, 0),
  ('has_children', 'any_children', NULL,    'any',
   '',                             'settingsHasChildrenAny', 0, 1)
ON CONFLICT (field_key, option_key) DO NOTHING;

-------------------------------------------------------------------------------
-- Seed data: wants_children
-------------------------------------------------------------------------------
INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('wants_children', 'yes',           'Yes',          'yes',
   'profileYes',                      'settingsWantsChildrenYes', 1, 1),
  ('wants_children', 'no',            'No',           'no',
   'profileNo',                       'settingsWantsChildrenNo',  2, 2),
  ('wants_children', 'open',          'Open to it',   'open',
   'familyOpenToIt',                  'settingsWantsChildrenOpen',3, 3),
  ('wants_children', 'not_sure',      'Not sure',     NULL,
   'familyNotSure',                   '',                          4, 0),
  ('wants_children', 'any_wants',     NULL,           'any',
   '',                                'settingsWantsChildrenAny',0, 0)
ON CONFLICT (field_key, option_key) DO NOTHING;

-------------------------------------------------------------------------------
-- Seed data: religion
-------------------------------------------------------------------------------
INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('religion', 'christianity', 'Christianity', 'christianity',
   'religionChristianity',  'religionChristianity',  1, 1),
  ('religion', 'islam',       'Islam',        'islam',
   'religionIslam',         'religionIslam',         2, 2),
  ('religion', 'hinduism',    'Hinduism',     'hinduism',
   'religionHinduism',      'religionHinduism',      3, 3),
  ('religion', 'buddhism',    'Buddhism',     'buddhism',
   'religionBuddhism',      'religionBuddhism',      4, 4),
  ('religion', 'judaism',     'Judaism',      'judaism',
   'religionJudaism',       'religionJudaism',       5, 5),
  ('religion', 'other',       'Other',        'other',
   'religionOther',         'religionOther',         6, 6)
ON CONFLICT (field_key, option_key) DO NOTHING;

-------------------------------------------------------------------------------
-- Seed data: education (profile only, no filter)
-------------------------------------------------------------------------------
INSERT INTO public.app_profile_options
  (field_key, option_key, profile_value, filter_value,
   profile_display_key, filter_display_key,
   profile_sort_order, filter_sort_order)
VALUES
  ('education', 'high_school', 'High School', NULL,
   'educationHighSchool', '',  1, 0),
  ('education', 'associate',   'Associate',   NULL,
   'educationAssociate',   '',  2, 0),
  ('education', 'bachelor',    'Bachelor',    NULL,
   'educationBachelor',    '',  3, 0),
  ('education', 'master',      'Master',      NULL,
   'educationMaster',      '',  4, 0),
  ('education', 'phd',         'PhD',         NULL,
   'educationPhd',         '',  5, 0),
  ('education', 'other_edu',   'Other',       NULL,
   'educationOther',       '',  6, 0)
ON CONFLICT (field_key, option_key) DO NOTHING;

------------------------------------------------------------------------------
-- RLS: public read, service_role write
------------------------------------------------------------------------------
ALTER TABLE public.app_profile_options ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read app_profile_options"
  ON public.app_profile_options
  FOR SELECT
  USING (true);

CREATE POLICY "Only service_role can insert app_profile_options"
  ON public.app_profile_options
  FOR INSERT
  TO service_role
  WITH CHECK (true);

CREATE POLICY "Only service_role can update app_profile_options"
  ON public.app_profile_options
  FOR UPDATE
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Only service_role can delete app_profile_options"
  ON public.app_profile_options
  FOR DELETE
  TO service_role
  USING (true);

COMMIT;
