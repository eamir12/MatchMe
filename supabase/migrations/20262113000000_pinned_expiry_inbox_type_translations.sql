-- Seed the pinned-expiry inbox type label (en/es/he). Safe to re-run.
-- The notification inbox labels each row from _typeLabelKey
-- (lib/screens/notifications/notification_inbox_screen.dart). Pinned
-- home-base warnings are stored with type 'pinned_expiry', but they shared
-- 'inboxTypeMatchExpiry' ("Match expiring"), which mislabels them. New key
-- 'inboxTypePinnedExpiry' gives them their own category label; the visual
-- (timer icon) is unchanged.

INSERT INTO public.translations (locale, key, value) VALUES

  ('en', 'inboxTypePinnedExpiry', $$Pinned location expiring$$),
  ('es', 'inboxTypePinnedExpiry', $$Ubicación fijada por caducar$$),
  ('he', 'inboxTypePinnedExpiry', $$הנעיצה עומדת לפוג$$)

ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
