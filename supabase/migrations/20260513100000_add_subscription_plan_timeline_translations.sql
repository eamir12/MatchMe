-- Migration: Add Subscription Timeline Translations
-- Description: Adds translation keys for the new subscription plan timeline UI on the paywall screen

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'subscriptionPlan', 'Subscription Plan'),
  ('en', 'subscriptionCurrent', 'CURRENT'),
  ('en', 'subscriptionUpNext', 'UP NEXT'),
  ('en', 'subscriptionLater', 'LATER'),
  ('en', 'subscriptionTotalRemaining', '{duration} total remaining'),

  ('es', 'subscriptionPlan', 'Plan de Suscripción'),
  ('es', 'subscriptionCurrent', 'ACTUAL'),
  ('es', 'subscriptionUpNext', 'SIGUIENTE'),
  ('es', 'subscriptionLater', 'DESPUÉS'),
  ('es', 'subscriptionTotalRemaining', '{duration} restante total'),

  ('he', 'subscriptionPlan', 'תוכנית מנוי'),
  ('he', 'subscriptionCurrent', 'נוכחי'),
  ('he', 'subscriptionUpNext', 'הבא בתור'),
  ('he', 'subscriptionLater', 'מאוחר יותר'),
  ('he', 'subscriptionTotalRemaining', 'סך הכל נותר: {duration}')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
