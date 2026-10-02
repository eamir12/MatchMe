BEGIN;

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'eventAddRejectedPrivateEvent', 'Could not import this event because it appears to be private or personal.'),
  ('en', 'eventAddRejectedCouldNotVerifyPublic', 'Could not import this event because we could not verify that it is public and joinable by other users.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES
  ('es', 'eventAddRejectedPrivateEvent', 'No se pudo importar este evento porque parece ser privado o personal.'),
  ('es', 'eventAddRejectedCouldNotVerifyPublic', 'No se pudo importar este evento porque no pudimos verificar que sea público y que otros usuarios puedan unirse.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO translations (locale, key, value) VALUES
  ('he', 'eventAddRejectedPrivateEvent', 'לא ניתן לייבא את האירוע הזה כי הוא נראה פרטי או אישי.'),
  ('he', 'eventAddRejectedCouldNotVerifyPublic', 'לא ניתן לייבא את האירוע הזה כי לא הצלחנו לוודא שהוא ציבורי ושמשתמשים אחרים יכולים להצטרף אליו.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
