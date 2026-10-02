INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'homeAllCaughtUp', 'You’re all caught up — MatchMe is working in the background.'),
  ('es', 'homeAllCaughtUp', 'Ya estás al día: MatchMe sigue trabajando en segundo plano.'),
  ('he', 'homeAllCaughtUp', 'הכול מעודכן — MatchMe ממשיך לעבוד ברקע.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
