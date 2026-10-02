INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'eventMatchedAttendeesCount', '{count} of your matches attending'),
  ('en', 'eventMatchedAttendeesOnly', 'Only people you’ve matched with are shown—not the full attendee list.'),
  ('es', 'eventMatchedAttendeesCount', '{count} de tus coincidencias asisten'),
  ('es', 'eventMatchedAttendeesOnly', 'Solo se muestran las personas con las que tienes coincidencia, no la lista completa de asistentes.'),
  ('he', 'eventMatchedAttendeesCount', '{count} מההתאמות שלך משתתפים'),
  ('he', 'eventMatchedAttendeesOnly', 'מוצגים רק אנשים שיש איתם התאמה — לא רשימת המשתתפים המלאה.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
