-- Migration: Seed translations for event extraction validation
-- Purpose: Add localized error messages for non-event content validation

BEGIN;

-- English translations
INSERT INTO translations (locale, key, value)
VALUES
  ('en', 'eventExtractionNotEventContent', 'The provided file or link does not contain event information. Please share an event ticket, flyer, or event page.'),
  ('en', 'eventExtractionInvalidFormat', 'Unable to extract event details. Please try uploading a clearer image or different event source.'),
  ('en', 'eventExtractionMissingRequiredData', 'Could not find event date or title. Please provide a document with clear event information.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (locale, key, value)
VALUES
  ('es', 'eventExtractionNotEventContent', 'El archivo o enlace proporcionado no contiene información de eventos. Por favor, comparta un ticket de evento, folleto o página de evento.'),
  ('es', 'eventExtractionInvalidFormat', 'No se pueden extraer los detalles del evento. Intente cargar una imagen más clara o una fuente de evento diferente.'),
  ('es', 'eventExtractionMissingRequiredData', 'No se pudo encontrar la fecha o el título del evento. Por favor, proporcione un documento con información clara del evento.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (locale, key, value)
VALUES
  ('he', 'eventExtractionNotEventContent', 'הקובץ או הקישור שנשלח אינם מכילים מידע על אירועים. נא שתף כרטיס אירוע, עלון או עמוד אירוע.'),
  ('he', 'eventExtractionInvalidFormat', 'לא ניתן לחלץ פרטי אירוע. נסה להעלות תמונה ברורה יותר או מקור אירוע שונה.'),
  ('he', 'eventExtractionMissingRequiredData', 'לא ניתן היה למצוא תאריך או כותרת אירוע. אנא הספק מסמך עם מידע ברור על האירוע.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
