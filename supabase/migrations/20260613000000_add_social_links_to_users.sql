-- Add social link columns to users table
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS linkedin_url TEXT,
  ADD COLUMN IF NOT EXISTS instagram_url TEXT;

-- Seed translations for social link labels
BEGIN;

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'profileSocialLinks', 'Social Links'),
  ('en', 'profileSocialLinksSubtitle', 'Add links to your social profiles.'),
  ('en', 'profileInstagramUrl', 'Instagram Profile (URL)'),
  ('en', 'profileInstagramUrlHint', 'https://instagram.com/yourusername'),
  ('en', 'profileLinkedinUrl', 'LinkedIn Profile (URL)'),
  ('en', 'profileLinkedinUrlHint', 'https://linkedin.com/in/yourprofile')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES
  ('es', 'profileSocialLinks', 'Enlaces sociales'),
  ('es', 'profileSocialLinksSubtitle', 'Añade enlaces a tus perfiles sociales.'),
  ('es', 'profileInstagramUrl', 'Perfil de Instagram (URL)'),
  ('es', 'profileInstagramUrlHint', 'https://instagram.com/tuusuario'),
  ('es', 'profileLinkedinUrl', 'Perfil de LinkedIn (URL)'),
  ('es', 'profileLinkedinUrlHint', 'https://linkedin.com/in/tuperfil')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES
  ('he', 'profileSocialLinks', 'קישורים חברתיים'),
  ('he', 'profileSocialLinksSubtitle', 'הוסף קישורים לפרופילים החברתיים שלך.'),
  ('he', 'profileInstagramUrl', 'פרופיל אינסטגרם (URL)'),
  ('he', 'profileInstagramUrlHint', 'https://instagram.com/השם_שלך'),
  ('he', 'profileLinkedinUrl', 'פרופיל לינקדאין (URL)'),
  ('he', 'profileLinkedinUrlHint', 'https://linkedin.com/in/הפרופיל_שלך')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
