BEGIN;

INSERT INTO public.translations (locale, key, value)
VALUES
  ('en', 'adminVerificationReviewedBy', 'Reviewed by'),
  ('es', 'adminVerificationReviewedBy', 'Revisado por'),
  ('he', 'adminVerificationReviewedBy', 'נבדק על ידי'),
  ('en', 'adminVerificationReviewerAi', 'AI'),
  ('es', 'adminVerificationReviewerAi', 'IA'),
  ('he', 'adminVerificationReviewerAi', 'בינה מלאכותית')
ON CONFLICT (locale, key) DO UPDATE
SET value = EXCLUDED.value;

COMMIT;
