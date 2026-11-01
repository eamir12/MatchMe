-- Filter sheet section title for the new gender filter on Matches and Chats.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'listFilterGenderSection', 'Gender'),
  ('es', 'listFilterGenderSection', 'Género'),
  ('he', 'listFilterGenderSection', 'מגדר')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
