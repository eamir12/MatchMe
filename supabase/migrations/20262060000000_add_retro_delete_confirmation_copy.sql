INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'settingsRetroDeleteNowConfirm', 'This permanently deletes your saved places from this device and the server. You will not be able to recover them.'),
  ('es', 'settingsRetroDeleteNowConfirm', 'Esto elimina permanentemente tus lugares guardados de este dispositivo y del servidor. No podrás recuperarlos.'),
  ('he', 'settingsRetroDeleteNowConfirm', 'פעולה זו תמחק לצמיתות את המקומות השמורים מהמכשיר ומהשרת. לא תוכל לשחזר אותם.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
