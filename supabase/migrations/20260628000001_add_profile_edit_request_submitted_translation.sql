INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileEditRequestSubmitted', 'Request submitted successfully.'),
  ('es', 'profileEditRequestSubmitted', 'Solicitud enviada correctamente.'),
  ('he', 'profileEditRequestSubmitted', 'הבקשה נשלחה בהצלחה.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
