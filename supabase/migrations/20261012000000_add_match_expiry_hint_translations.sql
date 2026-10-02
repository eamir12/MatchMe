-- Migration: Actionable match expiry hint (tells user how to save the match)
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'matchExpiryHint', 'Time left to send a message before match disappears: {duration}')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'matchExpiryHint', 'נותר זמן לשלוח הודעה לפני שההתאמה תיעלם: {duration}')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'matchExpiryHint', 'Tiempo restante para enviar un mensaje antes de que desaparezca la conexión: {duration}')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
