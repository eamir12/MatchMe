BEGIN;

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'eventLinkOptionalLabel', 'Event Link (Optional)'),
  ('en', 'calendarSyncFilterImportableOnly', 'Show importable only'),
  ('en', 'calendarSyncNoEventsMatchFilters', 'No events match the current filters.'),
  ('en', 'calendarSyncCannotImportBadge', 'Can''t import'),
  ('en', 'calendarSyncMissingLocationOrLinkHint', 'This event is missing both a physical location and an event link, so it cannot be imported.'),
  ('en', 'calendarSyncImportRequiresLocationOrLink', 'This event does not have either an event link or a physical location and therefore cannot be imported.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES
  ('es', 'eventLinkOptionalLabel', 'Enlace del evento (opcional)'),
  ('es', 'calendarSyncFilterImportableOnly', 'Mostrar solo importables'),
  ('es', 'calendarSyncNoEventsMatchFilters', 'Ningún evento coincide con los filtros actuales.'),
  ('es', 'calendarSyncCannotImportBadge', 'No se puede importar'),
  ('es', 'calendarSyncMissingLocationOrLinkHint', 'A este evento le faltan tanto una ubicación física como un enlace del evento, por lo que no se puede importar.'),
  ('es', 'calendarSyncImportRequiresLocationOrLink', 'Este evento no tiene ni un enlace del evento ni una ubicación física y por eso no se puede importar.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES
  ('he', 'eventLinkOptionalLabel', 'קישור לאירוע (אופציונלי)'),
  ('he', 'calendarSyncFilterImportableOnly', 'להציג רק אירועים שניתנים לייבוא'),
  ('he', 'calendarSyncNoEventsMatchFilters', 'אין אירועים שתואמים למסננים הנוכחיים.'),
  ('he', 'calendarSyncCannotImportBadge', 'לא ניתן לייבא'),
  ('he', 'calendarSyncMissingLocationOrLinkHint', 'לאירוע הזה אין גם מיקום פיזי וגם קישור לאירוע, ולכן אי אפשר לייבא אותו.'),
  ('he', 'calendarSyncImportRequiresLocationOrLink', 'לאירוע הזה אין קישור לאירוע או מיקום פיזי, ולכן אי אפשר לייבא אותו.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
