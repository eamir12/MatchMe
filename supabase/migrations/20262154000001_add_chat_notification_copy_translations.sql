-- Chat notification copy for the surfaces that build a card themselves.
--
-- push-message composes the tray copy in supabase/functions/_shared/
-- chat_notification_copy.ts, but Android also draws a card when no push
-- landed (force-stop, offline at delivery) and the Realtime path hands the
-- native service a message without a backlog count. Those cards are built from
-- the app's own translation table, so the same sentences have to exist as rows.
--
-- Keep these values in step with _chatStrings in chat_notification_copy.ts: a
-- card drawn from a push and a card drawn locally must not read differently.
--
-- Convention (see 20262148000000_add_plural_translations.sql): the base key
-- holds the "other" form, `<key>_one` the singular and `<key>_two` the Hebrew
-- dual. `{count}` and `{name}` stay as tokens - the service fills them when it
-- builds the card.
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'pushMessagesTitle', '{count} messages from {name}'),
  ('en', 'pushMessagesTitle_one', '{count} message from {name}'),
  ('en', 'pushOpenToReadBody', '{count} unread - open to read'),
  ('en', 'pushOpenToReadBody_one', '1 unread - open to read')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'pushMessagesTitle', '{count} mensajes de {name}'),
  ('es', 'pushMessagesTitle_one', '{count} mensaje de {name}'),
  ('es', 'pushOpenToReadBody', '{count} mensajes sin leer: abre para leer'),
  ('es', 'pushOpenToReadBody_one', '1 mensaje sin leer: abre para leer')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'pushMessagesTitle', '{count} הודעות מאת {name}'),
  ('he', 'pushMessagesTitle_one', 'הודעה מאת {name}'),
  ('he', 'pushMessagesTitle_two', 'שתי הודעות מאת {name}'),
  ('he', 'pushOpenToReadBody', '{count} הודעות לא נקראו - פתח כדי לקרוא'),
  ('he', 'pushOpenToReadBody_one', 'הודעה אחת לא נקראה - פתח כדי לקרוא'),
  ('he', 'pushOpenToReadBody_two', 'שתי הודעות לא נקראו - פתח כדי לקרוא')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
