-- Migration: Standardize interests table keys + translation_keys
-- Purpose: Only 3 rows use legacy 'parent::child' key format
--   (dancing::salsa, dancing::tango, dancing::line_dancing).
--   All other ~200 children use bare slugs (ballroom, karaoke, ...) with
--   parent_id as the hierarchy source (which is what the app groups by).
--   The '::' in the key is what caused the "Dancing - Salsa" display bug.
-- Also fixes 2 translation_key mismatches:
--   venture_capital -> interest.vc (abbreviation)
--   dancing::line_dancing -> interest.dancing.line (slug mismatch)
-- Target standard:
--   key             = bare globally-unique slug, no '::'
--   translation_key = interest.<slug> for top-level,
--                     interest.<parent>.<slug> for nested children
-- Safety:
--   - New translation rows are INSERTed copying old values; old rows are KEPT
--     for backward compat with cached clients.
--   - user_profiles JSONB is migrated via exact quoted-string replace, so both
--     object keys and array values are fixed.
BEGIN;

-- 1) Rename legacy '::' keys to bare slugs (idempotent guards).
UPDATE public.interests
SET key = 'salsa', updated_at = now()
WHERE key = 'dancing::salsa'
  AND NOT EXISTS (SELECT 1 FROM public.interests WHERE key = 'salsa');

UPDATE public.interests
SET key = 'tango', updated_at = now()
WHERE key = 'dancing::tango'
  AND NOT EXISTS (SELECT 1 FROM public.interests WHERE key = 'tango');

UPDATE public.interests
SET key = 'line_dancing', updated_at = now()
WHERE key = 'dancing::line_dancing'
  AND NOT EXISTS (SELECT 1 FROM public.interests WHERE key = 'line_dancing');

-- 2) Fix translation_key mismatches (run after renames above).
UPDATE public.interests
SET translation_key = 'interest.venture_capital', updated_at = now()
WHERE key = 'venture_capital'
  AND translation_key <> 'interest.venture_capital';

UPDATE public.interests
SET translation_key = 'interest.dancing.line_dancing', updated_at = now()
WHERE key = 'line_dancing'
  AND translation_key <> 'interest.dancing.line_dancing';

-- 3) Seed new translation rows by copying old values; keep old rows.
-- venture_capital
INSERT INTO public.translations (locale, key, value)
SELECT locale, 'interest.venture_capital', value
FROM public.translations
WHERE key = 'interest.vc'
ON CONFLICT (locale, key) DO NOTHING;

-- line_dancing (nested)
INSERT INTO public.translations (locale, key, value)
SELECT locale, 'interest.dancing.line_dancing', value
FROM public.translations
WHERE key = 'interest.dancing.line'
ON CONFLICT (locale, key) DO NOTHING;

-- Fallback: ensure en/es/he exist even if old rows were missing.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'interest.venture_capital', 'Venture Capital'),
  ('es', 'interest.venture_capital', 'Capital de Riesgo'),
  ('he', 'interest.venture_capital', 'הון סיכון'),
  ('en', 'interest.dancing.line_dancing', 'Line Dancing'),
  ('es', 'interest.dancing.line_dancing', 'Baile en Línea'),
  ('he', 'interest.dancing.line_dancing', 'ריקוד שורות')
ON CONFLICT (locale, key) DO NOTHING;

-- 4) Migrate stored user selections (exact quoted match => safe for keys + array values).
-- personal_interests
UPDATE public.user_profiles
SET personal_interests = replace(personal_interests::text, '"dancing::salsa"', '"salsa"')::jsonb
WHERE personal_interests::text LIKE '%"dancing::salsa"%';

UPDATE public.user_profiles
SET personal_interests = replace(personal_interests::text, '"dancing::tango"', '"tango"')::jsonb
WHERE personal_interests::text LIKE '%"dancing::tango"%';

UPDATE public.user_profiles
SET personal_interests = replace(personal_interests::text, '"dancing::line_dancing"', '"line_dancing"')::jsonb
WHERE personal_interests::text LIKE '%"dancing::line_dancing"%';

-- business_interests (dancing is social, but update defensively in case of mis-bucketed rows)
UPDATE public.user_profiles
SET business_interests = replace(business_interests::text, '"dancing::salsa"', '"salsa"')::jsonb
WHERE business_interests::text LIKE '%"dancing::salsa"%';

UPDATE public.user_profiles
SET business_interests = replace(business_interests::text, '"dancing::tango"', '"tango"')::jsonb
WHERE business_interests::text LIKE '%"dancing::tango"%';

UPDATE public.user_profiles
SET business_interests = replace(business_interests::text, '"dancing::line_dancing"', '"line_dancing"')::jsonb
WHERE business_interests::text LIKE '%"dancing::line_dancing"%';

COMMIT;
