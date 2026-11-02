-- 20262223000000_sort_latest_activity_label.sql
--
-- The Matches list now defaults to "latest activity first" (what was last
-- exchanged, newest first) instead of "newest match first", and "Newest"
-- stays as an option. The new order needs its own label in every locale the
-- app serves, because the sort chips are DB-driven like every other string.
--
-- en/es/he only: those are the three locales in public.translations. Hebrew
-- agrees with the feminine noun פעילות ("אחרונה", not "אחרון").

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'sortLatestActivity', 'Latest activity'),
  ('es', 'sortLatestActivity', 'Actividad más reciente'),
  ('he', 'sortLatestActivity', 'פעילות אחרונה')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
