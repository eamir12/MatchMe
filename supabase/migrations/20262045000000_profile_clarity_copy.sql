INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profilePhotoPreviewLabel', 'Photo {index}'),
  ('en', 'profileLoadErrorTitle', 'We couldn’t load your profile'),
  ('en', 'profileLoadErrorMessage', 'Check your connection and try again.'),
  ('es', 'profilePhotoPreviewLabel', 'Foto {index}'),
  ('es', 'profileLoadErrorTitle', 'No pudimos cargar tu perfil'),
  ('es', 'profileLoadErrorMessage', 'Comprueba tu conexión e inténtalo de nuevo.'),
  ('he', 'profilePhotoPreviewLabel', 'תמונה {index}'),
  ('he', 'profileLoadErrorTitle', 'לא ניתן לטעון את הפרופיל שלך'),
  ('he', 'profileLoadErrorMessage', 'בדקו את החיבור ונסו שוב.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
