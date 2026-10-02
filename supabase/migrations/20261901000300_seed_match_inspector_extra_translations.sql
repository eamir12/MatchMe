-- Seed extra Match Inspector translations for normalized & localized display
-- Adds short labels, prefs, match types. Ensures he/es have proper values, with en fallback.
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchInspectorShortA', 'A'),
  ('es', 'matchInspectorShortA', 'A'),
  ('he', 'matchInspectorShortA', 'א'''),
  ('en', 'matchInspectorShortB', 'B'),
  ('es', 'matchInspectorShortB', 'B'),
  ('he', 'matchInspectorShortB', 'ב'''),
  ('en', 'matchInspectorPrefs', 'Prefs'),
  ('es', 'matchInspectorPrefs', 'Prefs'),
  ('he', 'matchInspectorPrefs', 'העדפות'),
  ('en', 'matchInspectorMatchTypeProximity', 'Proximity'),
  ('es', 'matchInspectorMatchTypeProximity', 'Proximidad'),
  ('he', 'matchInspectorMatchTypeProximity', 'קרבה'),
  ('en', 'matchInspectorMatchTypeEvent', 'Event'),
  ('es', 'matchInspectorMatchTypeEvent', 'Evento'),
  ('he', 'matchInspectorMatchTypeEvent', 'אירוע')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Seed missing Hebrew translations for interests that appear untranslated in inspector
-- (fallback to English is allowed per spec, but we provide proper Hebrew for the most visible ones)
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'interest.volunteering', 'התנדבות'),
  ('he', 'interest.volunteering.animals', 'הצלת בעלי חיים'),
  ('he', 'interest.volunteering.community', 'שירות קהילתי'),
  ('he', 'interest.cooking.grilling', 'על האש'),
  ('he', 'interest.dancing', 'ריקוד'),
  ('he', 'interest.fitness', 'כושר'),
  ('he', 'interest.fitness.gym', 'חדר כושר'),
  ('he', 'Volunteering', 'התנדבות'),
  ('he', 'Animal', 'חיה'),
  ('he', 'Grilling', 'על האש'),
  ('he', 'Dancing', 'ריקוד'),
  ('he', 'Fitness', 'כושר'),
  ('he', 'rescue', 'חילוץ'),
  ('he', 'Volunteering: Animal', 'התנדבות: חיה')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
