-- Add keys missing from the base sync migration.
-- These were added to locale_provider.dart after the base migration.
-- Idempotent: safe to re-run (ON CONFLICT DO UPDATE).
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'mapLegendOnlineInRadius', 'Online in your radius'),
  ('en', 'mapLegendOnlineCountries', 'Online by country'),
  ('en', 'onlineToggleExplained', 'When you go offline, other members cannot see you or match with you. Tap to come back online anytime.'),
  ('en', 'onlineStatusOnline', 'Online'),
  ('en', 'onlineStatusOffline', 'Offline'),
  ('es', 'mapLegendOnlineInRadius', 'En línea en tu radio'),
  ('es', 'mapLegendOnlineCountries', 'En línea por país'),
  ('es', 'onlineToggleExplained', 'Cuando estás desconectado, otros miembros no pueden verte ni coincidir contigo. Toca para volver a estar en línea en cualquier momento.'),
  ('es', 'onlineStatusOnline', 'En línea'),
  ('es', 'onlineStatusOffline', 'Desconectado'),
  ('he', 'mapLegendOnlineInRadius', 'מקוון ברדיוס שלך'),
  ('he', 'mapLegendOnlineCountries', 'מקוון לפי מדינה'),
  ('he', 'onlineToggleExplained', 'כשאתה מושבת, חברים אחרים לא יכולים לראות אותך או להתאים איתך. גע כדי לחזור למקוון בכל עת.'),
  ('he', 'onlineStatusOnline', 'מקוון'),
  ('he', 'onlineStatusOffline', 'מנותק')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
