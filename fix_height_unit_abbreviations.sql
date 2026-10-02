-- Fix abbreviated height units: ft -> feet, in -> inches, cm -> centimeters
-- (plus es/he equivalents: pulg -> pulgadas, cm -> centímetros, ס"מ/ס״מ -> סנטימטרים)
-- Run this against the live Supabase DB to update current abbreviated values.
-- Table assumed: public.translations (locale, key, value)

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Unit suffixes / toggle labels
  ('en', 'settingsHeightCm', $$centimeters$$),
  ('es', 'settingsHeightCm', $$centímetros$$),
  ('he', 'settingsHeightCm', $$סנטימטרים$$),

  ('en', 'profileHeightCm', $$centimeters$$),
  ('es', 'profileHeightCm', $$centímetros$$),
  ('he', 'profileHeightCm', $$סנטימטרים$$),

  ('en', 'profileHeightUnitCm', $$centimeters$$),
  ('es', 'profileHeightUnitCm', $$centímetros$$),
  ('he', 'profileHeightUnitCm', $$סנטימטרים$$),

  ('en', 'profileHeightUnitFeet', $$feet$$),
  ('es', 'profileHeightUnitFeet', $$pies$$),
  ('he', 'profileHeightUnitFeet', $$רגל$$),

  ('en', 'profileHeightUnitInches', $$inches$$),
  ('es', 'profileHeightUnitInches', $$pulgadas$$),
  ('he', 'profileHeightUnitInches', $$אינטש$$),

  -- Composite formats
  ('en', 'profileHeightFeetInches', $${feet} feet {inches} inches$$),
  ('es', 'profileHeightFeetInches', $${feet} pies {inches} pulgadas$$),
  ('he', 'profileHeightFeetInches', $${feet} רגל {inches} אינטש$$),

  ('en', 'profileHeightInCm', $${cm} centimeters$$),
  ('es', 'profileHeightInCm', $${cm} centímetros$$),
  ('he', 'profileHeightInCm', $${cm} סנטימטרים$$),

  -- Hints / validation messages
  ('en', 'profileEditHeightHint', $$Height in centimeters (for example, 170)$$),
  ('es', 'profileEditHeightHint', $$Altura en centímetros (por ejemplo, 170)$$),
  ('he', 'profileEditHeightHint', $$גובה בסנטימטרים (למשל 170)$$),

  ('en', 'profileEditHeightInvalid', $$Height must be between 100 and 250 centimeters$$),
  ('es', 'profileEditHeightInvalid', $$La altura debe estar entre 100 y 250 centímetros$$),
  ('he', 'profileEditHeightInvalid', $$הגובה חייב להיות בין 100 ל-250 סנטימטרים$$),

  ('en', 'profileEditHeightInvalidFeet', $$Height must be between 3 feet 4 inches and 8 feet 2 inches$$),
  ('es', 'profileEditHeightInvalidFeet', $$La altura debe estar entre 3 pies 4 pulgadas y 8 pies 2 pulgadas$$),
  ('he', 'profileEditHeightInvalidFeet', $$הגובה חייב להיות בין 3 רגל 4 אינטש ל-8 רגל 2 אינטש$$),

  -- Match inspector
  ('en', 'matchInspectorHeightUnit', $$centimeters$$),
  ('es', 'matchInspectorHeightUnit', $$centímetros$$),
  ('he', 'matchInspectorHeightUnit', $$סנטימטרים$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;

-- Verification (should return 0 rows after the fix):
-- SELECT locale, key, value FROM public.translations
-- WHERE (key IN ('settingsHeightCm','profileHeightCm','profileHeightUnitCm','matchInspectorHeightUnit')
--        AND value IN ('cm', 'ס"מ', 'ס״מ'))
--    OR (key = 'profileHeightUnitFeet' AND value = 'ft')
--    OR (key = 'profileHeightUnitInches' AND value IN ('in', 'pulg'))
--    OR (key = 'profileHeightFeetInches' AND (value LIKE '% ft %' OR value LIKE '% in' OR value LIKE '%pulg%'))
--    OR (key = 'profileHeightInCm' AND value LIKE '% cm')
--    OR (key IN ('profileEditHeightHint','profileEditHeightInvalid') AND value LIKE '% cm%')
--    OR (key = 'profileEditHeightInvalidFeet' AND (value LIKE '% ft %' OR value LIKE '% in %' OR value LIKE '%pulg%'));
