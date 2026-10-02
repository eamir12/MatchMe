BEGIN;

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'calendarSyncEventImportFailed', 'Could not import {title}: {reason}'),
  ('en', 'eventAddFailedAuth', 'Could not import this event because you are no longer signed in.'),
  ('en', 'eventAddFailedDuplicate', 'Could not import this event because it is already in your events.'),
  ('en', 'eventAddFailedPermission', 'Could not import this event because the database denied permission to save it.'),
  ('en', 'eventAddFailedMissingDependency', 'Could not import this event because a required related record was missing.'),
  ('en', 'eventAddFailedInvalidData', 'Could not import this event because some event details were not accepted.'),
  ('en', 'eventAddFailedPastEvent', 'Could not import this event because its start time is in the past.'),
  ('en', 'eventAddFailedDatabase', 'Could not import this event because the database rejected the save request.'),
  ('en', 'eventAddFailedNetwork', 'Could not import this event because the network request failed.'),
  ('en', 'eventAddFailedUnknown', 'Could not import this event because of an unknown import error.'),
  ('en', 'eventSaveFailedWithReason', 'Could not save this event: {reason}')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES
  ('es', 'calendarSyncEventImportFailed', 'No se pudo importar {title}: {reason}'),
  ('es', 'eventAddFailedAuth', 'No se pudo importar este evento porque tu sesión ya no está iniciada.'),
  ('es', 'eventAddFailedDuplicate', 'No se pudo importar este evento porque ya está en tus eventos.'),
  ('es', 'eventAddFailedPermission', 'No se pudo importar este evento porque la base de datos rechazó el permiso para guardarlo.'),
  ('es', 'eventAddFailedMissingDependency', 'No se pudo importar este evento porque faltaba un registro relacionado obligatorio.'),
  ('es', 'eventAddFailedInvalidData', 'No se pudo importar este evento porque algunos detalles del evento no fueron aceptados.'),
  ('es', 'eventAddFailedPastEvent', 'No se pudo importar este evento porque su hora de inicio ya pasó.'),
  ('es', 'eventAddFailedDatabase', 'No se pudo importar este evento porque la base de datos rechazó la solicitud de guardado.'),
  ('es', 'eventAddFailedNetwork', 'No se pudo importar este evento porque falló la solicitud de red.'),
  ('es', 'eventAddFailedUnknown', 'No se pudo importar este evento debido a un error de importación desconocido.'),
  ('es', 'eventSaveFailedWithReason', 'No se pudo guardar este evento: {reason}')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES
  ('he', 'calendarSyncEventImportFailed', 'לא ניתן לייבא את {title}: {reason}'),
  ('he', 'eventAddFailedAuth', 'לא ניתן לייבא את האירוע הזה כי אינך מחובר/ת יותר.'),
  ('he', 'eventAddFailedDuplicate', 'לא ניתן לייבא את האירוע הזה כי הוא כבר קיים ברשימת האירועים שלך.'),
  ('he', 'eventAddFailedPermission', 'לא ניתן לייבא את האירוע הזה כי למסד הנתונים אין הרשאה לשמור אותו.'),
  ('he', 'eventAddFailedMissingDependency', 'לא ניתן לייבא את האירוע הזה כי חסרה רשומה קשורה שנדרשת לשמירה.'),
  ('he', 'eventAddFailedInvalidData', 'לא ניתן לייבא את האירוע הזה כי חלק מפרטי האירוע לא התקבלו.'),
  ('he', 'eventAddFailedPastEvent', 'לא ניתן לייבא את האירוע הזה כי שעת ההתחלה שלו כבר עברה.'),
  ('he', 'eventAddFailedDatabase', 'לא ניתן לייבא את האירוע הזה כי מסד הנתונים דחה את בקשת השמירה.'),
  ('he', 'eventAddFailedNetwork', 'לא ניתן לייבא את האירוע הזה כי בקשת הרשת נכשלה.'),
  ('he', 'eventAddFailedUnknown', 'לא ניתן לייבא את האירוע הזה בגלל שגיאת ייבוא לא ידועה.'),
  ('he', 'eventSaveFailedWithReason', 'לא ניתן לשמור את האירוע הזה: {reason}')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
