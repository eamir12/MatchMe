-- Seed translations for the per-intent / per-feature enforcement labels
-- (en/es/he). Safe to re-run.

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'settingsGenderRequirementsEnforcement', $$Gender requirements enforcement$$),
  ('es', 'settingsGenderRequirementsEnforcement', $$Cumplimiento de requisitos de género$$),
  ('he', 'settingsGenderRequirementsEnforcement', $$אכיפת דרישות מגדר$$),

  ('en', 'settingsAgeRequirementsEnforcement', $$Age requirements enforcement$$),
  ('es', 'settingsAgeRequirementsEnforcement', $$Cumplimiento de requisitos de edad$$),
  ('he', 'settingsAgeRequirementsEnforcement', $$אכיפת דרישות גיל$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
