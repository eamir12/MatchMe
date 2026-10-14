-- Seed admin drilldown pinned-badge translations (en/es/he). Safe to re-run.
-- Keys used by the LIVE drilldowns' is_pinned column (20262111): a pinned
-- home-base location is now visibly indicated so admins can tell pinned
-- (available, not heartbeating) users apart from genuinely live ones.
-- English fallbacks also exist in main.dart _defaultTranslations.

INSERT INTO public.translations (locale, key, value) VALUES

  ('en', 'adminDrilldownPinned', $$Pinned$$),
  ('es', 'adminDrilldownPinned', $$Ubicación fija$$),
  ('he', 'adminDrilldownPinned', $$מיקום מעוגן$$),

  ('en', 'adminDrilldownPinnedActive', $$Pinned home-base location is active$$),
  ('es', 'adminDrilldownPinnedActive', $$La ubicación fija de base está activa$$),
  ('he', 'adminDrilldownPinnedActive', $$מיקום המעוגן פעיל$$),

  ('en', 'adminDrilldownPinnedNone', $$No pinned location$$),
  ('es', 'adminDrilldownPinnedNone', $$Sin ubicación fija$$),
  ('he', 'adminDrilldownPinnedNone', $$אין מיקום מעוגן$$)

ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
