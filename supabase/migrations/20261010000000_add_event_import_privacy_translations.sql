-- Migration: Localized translations for calendar-import privacy blocking
--
-- Companion to the import-picker privacy classification work:
-- events that the source calendar marks private/non-busy, or whose title
-- looks personal, are greyed out with a per-reason explanation instead of
-- failing only at save time.
--
-- English fallbacks already live in Dart (locale_provider.dart
-- _defaultTranslations); this ensures en/he/es rows exist in the
-- translations table.
--
-- The two `eventAddRejected*` keys already existed in code; their en/he/es
-- rows are added with DO NOTHING so any existing DB values are preserved.
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- New per-reason import-block strings (source of truth for all locales)
  ('en', 'calendarSyncCannotImportPrivateBadge', 'Private'),
  ('en', 'calendarSyncCannotImportPrivateHint', 'This event is marked private or “free” in your calendar, so it can’t be shared publicly.'),
  ('en', 'calendarSyncImportBlockedPrivate', 'Can’t import: this event is marked private in your calendar, so it can’t be shared with other users.'),
  ('en', 'calendarSyncCannotImportPersonalBadge', 'Looks personal'),
  ('en', 'calendarSyncCannotImportPersonalHint', 'This looks like a personal appointment rather than a public event others can join.'),
  ('en', 'calendarSyncImportBlockedPersonal', 'Can’t import: this looks like a personal event rather than a public one other users can join.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'calendarSyncCannotImportPrivateBadge', 'פרטי'),
  ('he', 'calendarSyncCannotImportPrivateHint', 'האירוע מסומן ביומן שלך כפרטי או כפנוי, ולכן לא ניתן לשתף אותו בפומבי.'),
  ('he', 'calendarSyncImportBlockedPrivate', 'לא ניתן לייבא: האירוע מסומן כפרטי ביומן שלך, ולכן אין אפשרות לשתף אותו עם משתמשים אחרים.'),
  ('he', 'calendarSyncCannotImportPersonalBadge', 'נראה אישי'),
  ('he', 'calendarSyncCannotImportPersonalHint', 'נראה שזהו אירוע אישי ולא אירוע ציבורי שאחרים יכולים להצטרף אליו.'),
  ('he', 'calendarSyncImportBlockedPersonal', 'לא ניתן לייבא: נראה שזהו אירוע אישי ולא אירוע ציבורי שמשתמשים אחרים יכולים להצטרף אליו.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'calendarSyncCannotImportPrivateBadge', 'Privado'),
  ('es', 'calendarSyncCannotImportPrivateHint', 'Este evento está marcado como privado o «libre» en tu calendario, por lo que no se puede compartir públicamente.'),
  ('es', 'calendarSyncImportBlockedPrivate', 'No se puede importar: este evento está marcado como privado en tu calendario, por lo que no se puede compartir con otros usuarios.'),
  ('es', 'calendarSyncCannotImportPersonalBadge', 'Parece personal'),
  ('es', 'calendarSyncCannotImportPersonalHint', 'Esto parece una cita personal en lugar de un evento público al que otros puedan unirse.'),
  ('es', 'calendarSyncImportBlockedPersonal', 'No se puede importar: esto parece un evento personal en lugar de uno público al que otros usuarios puedan unirse.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Pre-existing save-rejection reason keys, now also used as fragments in
-- the import failure summary. en fallbacks exist in code; don't overwrite
-- any existing DB rows.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'eventAddRejectedPersonalOrPrivate', 'it looks like a personal or private calendar item'),
  ('en', 'eventAddRejectedPrivateEvent', 'Could not import this event because it appears to be private or personal.'),
  ('he', 'eventAddRejectedPersonalOrPrivate', 'נראה שזהו פריט יומן אישי או פרטי'),
  ('he', 'eventAddRejectedPrivateEvent', 'לא ניתן לייבא את האירוע כי נראה שהוא פרטי או אישי.'),
  ('es', 'eventAddRejectedPersonalOrPrivate', 'parece un elemento personal o privado del calendario'),
  ('es', 'eventAddRejectedPrivateEvent', 'No se pudo importar este evento porque parece ser privado o personal.')
ON CONFLICT (locale, key) DO NOTHING;

COMMIT;
