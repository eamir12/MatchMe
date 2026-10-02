-- Migration: Clean phantom empty interest categories (e.g. {"mentorship":[],"startups":[],"dates":[]} or {"fitness":["fitness"]})
-- Fixes ghost rows like "Dates: Not set / Not set" in Match Inspector caused by empty/echo entries.
-- Keeps only categories with at least one effective sub-interest after stripping category-as-sub echo and blanks.
BEGIN;

-- Helper: strip category echo and blanks from a single interest map
CREATE OR REPLACE FUNCTION public.clean_interest_map(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  result jsonb := '{}'::jsonb;
  k text;
  v jsonb;
  filtered jsonb;
  norm_k text;
BEGIN
  IF p IS NULL OR p = '{}'::jsonb THEN
    RETURN '{}'::jsonb;
  END IF;
  FOR k, v IN SELECT * FROM jsonb_each(p) LOOP
    IF jsonb_typeof(v) != 'array' THEN
      CONTINUE;
    END IF;
    norm_k := lower(replace(replace(trim(k), '_', ''), ' ', ''));
    SELECT COALESCE(jsonb_agg(elem ORDER BY elem), '[]'::jsonb) INTO filtered
    FROM jsonb_array_elements_text(v) AS elem
    WHERE trim(elem) <> ''
      AND lower(replace(replace(trim(elem), '_', ''), ' ', '')) <> norm_k;
    IF jsonb_array_length(filtered) > 0 THEN
      result := result || jsonb_build_object(k, filtered);
    END IF;
  END LOOP;
  RETURN result;
END;
$$;

-- Clean personal_interests
UPDATE public.user_profiles
SET personal_interests = public.clean_interest_map(personal_interests),
    updated_at = now()
WHERE personal_interests IS NOT NULL
  AND personal_interests <> '{}'::jsonb
  AND public.clean_interest_map(personal_interests) <> personal_interests;

-- Clean business_interests
UPDATE public.user_profiles
SET business_interests = public.clean_interest_map(business_interests),
    updated_at = now()
WHERE business_interests IS NOT NULL
  AND business_interests <> '{}'::jsonb
  AND public.clean_interest_map(business_interests) <> business_interests;

-- Optional: keep helper for future use or drop it
-- DROP FUNCTION IF EXISTS public.clean_interest_map(jsonb);

COMMIT;
