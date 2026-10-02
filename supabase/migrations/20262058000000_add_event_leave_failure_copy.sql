INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'eventLeaveConfirmBodyWithName', 'Leave "{eventName}"? This removes only your MatchMe attendance and event matches. Other attendees keep the event.'),
  ('en', 'eventLeaveFailed', 'Could not leave this event. You are still listed as attending.'),
  ('en', 'settingsSharedEventMatchingUpdateFailed', 'Failed to update shared event matching'),
  ('es', 'eventLeaveConfirmBodyWithName', '¿Salir de "{eventName}"? Esto solo elimina tu asistencia y tus coincidencias del evento en MatchMe. Los demás asistentes conservan el evento.'),
  ('es', 'eventLeaveFailed', 'No se pudo salir de este evento. Todavía figuras como asistente.'),
  ('es', 'settingsSharedEventMatchingUpdateFailed', 'No se pudo actualizar la coincidencia de eventos compartidos'),
  ('he', 'eventLeaveConfirmBodyWithName', 'לעזוב את „{eventName}"? פעולה זו תסיר רק את ההשתתפות שלך ואת התאמות האירוע שלך ב‑MatchMe. משתתפים אחרים ימשיכו לקבל את האירוע.'),
  ('he', 'eventLeaveFailed', 'לא ניתן היה לעזוב את האירוע. את/ה עדיין מפורט/ת כמשתתפ/ת.'),
  ('he', 'settingsSharedEventMatchingUpdateFailed', 'עדכון התאמת האירועים המשותפת נכשל')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
