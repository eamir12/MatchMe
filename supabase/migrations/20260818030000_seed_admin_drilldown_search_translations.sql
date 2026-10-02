-- Seed admin drilldown search translations (en/es/he). Safe to re-run.
-- New keys used by the drilldown search box added to all metrics.

INSERT INTO public.translations (locale, key, value) VALUES

  ('en', 'adminDrilldownSearchAllHint', $$Search...$$),
  ('es', 'adminDrilldownSearchAllHint', $$Buscar...$$),
  ('he', 'adminDrilldownSearchAllHint', $$חיפוש...$$),

  ('en', 'adminDrilldownNoMatches', $$No matches for "{query}"$$),
  ('es', 'adminDrilldownNoMatches', $$Sin coincidencias para "{query}"$$),
  ('he', 'adminDrilldownNoMatches', $$אין תוצאות עבור "{query}"$$)

ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;