INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileSocialLinkOpenFailed', 'Could not open this link. Check your connection and try again.'),
  ('es', 'profileSocialLinkOpenFailed', 'No se pudo abrir este enlace. Comprueba tu conexión e inténtalo de nuevo.'),
  ('he', 'profileSocialLinkOpenFailed', 'לא ניתן היה לפתוח את הקישור. בדוק את החיבור ונסה שוב.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
