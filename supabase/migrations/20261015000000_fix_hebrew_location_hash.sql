-- Migration: Hebrew "Location #N" must render "#" to the right of the digits in RTL,
-- so the value is 'מיקום {count}#' (renders "מיקום 1#"), not 'מיקום #{count}'.
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'matchLocationOccurrence', 'מיקום {count}#')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
