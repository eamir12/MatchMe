-- Add missing paywall bottom section translations
-- Keys: paywallTermsAndPrivacy
-- Languages: English (en), Spanish (es), Hebrew (he)

INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'paywallTermsAndPrivacy', 'By subscribing you agree to our Terms and Privacy Policy', NOW(), NOW()),
  ('es', 'paywallTermsAndPrivacy', 'Al suscribirte, aceptas nuestros Términos y Política de Privacidad', NOW(), NOW()),
  ('he', 'paywallTermsAndPrivacy', 'בהרשמה אתה מסכים לתנאים ולמדיניות הפרטיות שלנו', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE
SET
  value = EXCLUDED.value,
  updated_at = NOW();
