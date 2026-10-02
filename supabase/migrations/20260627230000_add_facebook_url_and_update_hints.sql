-- Add facebook_url column to users table
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS facebook_url TEXT;

-- Seed translations for Facebook profile link
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileFacebookUrl', 'Facebook Profile (URL)'),
  ('en', 'profileFacebookUrlHint', 'https://facebook.com/yourusername'),
  ('es', 'profileFacebookUrl', 'Perfil de Facebook (URL)'),
  ('es', 'profileFacebookUrlHint', 'https://facebook.com/tuusuario'),
  ('he', 'profileFacebookUrl', 'פרופיל פייסבוק (URL)'),
  ('he', 'profileFacebookUrlHint', 'https://facebook.com/שםהמשתמש')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
