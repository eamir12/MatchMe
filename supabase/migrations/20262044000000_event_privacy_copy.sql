INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'eventPublicDisclosureTitle', 'Public event details'),
  ('en', 'eventPublicDisclosureBody', 'If Shared Event Matching is on, the public event name, date, venue, and link you enter can be used to find people attending the same event. Don’t add private details.'),
  ('en', 'eventPublicDisclosureConfirmTitle', 'Save this public event?'),
  ('en', 'eventPublicDisclosureConfirmBody', 'These event details will be available for shared-event matching. Continue only if this is a public event you want others to discover.'),
  ('es', 'eventPublicDisclosureTitle', 'Detalles públicos del evento'),
  ('es', 'eventPublicDisclosureBody', 'Si la coincidencia de eventos compartidos está activada, el nombre, la fecha, el lugar y el enlace públicos del evento pueden usarse para encontrar personas que asistirán al mismo evento. No añadas datos privados.'),
  ('es', 'eventPublicDisclosureConfirmTitle', '¿Guardar este evento público?'),
  ('es', 'eventPublicDisclosureConfirmBody', 'Estos detalles estarán disponibles para la coincidencia de eventos compartidos. Continúa solo si es un evento público que quieres que otras personas descubran.'),
  ('he', 'eventPublicDisclosureTitle', 'פרטי אירוע ציבוריים'),
  ('he', 'eventPublicDisclosureBody', 'אם התאמת אירועים משותפים פעילה, שם האירוע, התאריך, המקום והקישור הציבוריים שתזינו יכולים לשמש למציאת אנשים שמגיעים לאותו אירוע. אין להוסיף פרטים פרטיים.'),
  ('he', 'eventPublicDisclosureConfirmTitle', 'לשמור את האירוע הציבורי?'),
  ('he', 'eventPublicDisclosureConfirmBody', 'פרטי האירוע יהיו זמינים להתאמת אירועים משותפים. אפשר להמשיך רק אם זהו אירוע ציבורי שברצונכם שאחרים יגלו.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
