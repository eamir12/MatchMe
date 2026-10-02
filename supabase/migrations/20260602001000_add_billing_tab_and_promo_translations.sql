-- Migration: Add Billing Tab and Promo Indicator Translations
-- Description: Adds translation keys for the new billing screen tabs (Active / Scheduled / Completed),
--              the empty-state messages for each tab, the "FREE" amount label for promo-redeemed
--              subscriptions, and the "Promo" badge label shown next to the tier title.

INSERT INTO public.translations (locale, key, value) VALUES
  -- English
  ('en', 'billingEmptyActive',     'No active subscriptions.'),
  ('en', 'billingEmptyCompleted',  'No completed subscriptions yet.'),
  ('en', 'billingEmptyScheduled',  'No scheduled subscriptions.'),
  ('en', 'billingFree',            'Free'),
  ('en', 'billingPromoBadge',      'Promo'),
  ('en', 'billingTabActive',       'Active'),
  ('en', 'billingTabCompleted',    'Completed'),
  ('en', 'billingTabScheduled',    'Scheduled'),

  -- Spanish
  ('es', 'billingEmptyActive',     'Sin suscripciones activas.'),
  ('es', 'billingEmptyCompleted',  'Aún no hay suscripciones completadas.'),
  ('es', 'billingEmptyScheduled',  'Sin suscripciones programadas.'),
  ('es', 'billingFree',            'Gratis'),
  ('es', 'billingPromoBadge',      'Promo'),
  ('es', 'billingTabActive',       'Activas'),
  ('es', 'billingTabCompleted',    'Completadas'),
  ('es', 'billingTabScheduled',    'Programadas'),

  -- Hebrew
  ('he', 'billingEmptyActive',     'אין מנויים פעילים.'),
  ('he', 'billingEmptyCompleted',  'אין עדיין מנויים שהושלמו.'),
  ('he', 'billingEmptyScheduled',  'אין מנויים מתוכננים.'),
  ('he', 'billingFree',            'חינם'),
  ('he', 'billingPromoBadge',      'פרומו'),
  ('he', 'billingTabActive',       'פעילים'),
  ('he', 'billingTabCompleted',    'הושלמו'),
  ('he', 'billingTabScheduled',    'מתוכננים')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
