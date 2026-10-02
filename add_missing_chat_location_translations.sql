-- Add missing chat-reply and location translations
-- Languages: en (English), es (Spanish), he (Hebrew)
--
-- Key meanings (from code usage):
--   chatReplyYou: sender label "You" shown in the reply-quote header when the
--     quoted message was sent by the current user (chat_screen.dart, e.g.
--     "Replying to You" and the quote bubble header). Fallback in code: 'You'.
--   chatReplyOriginalUnavailable: placeholder text in the quote bubble when the
--     original quoted message can't be loaded (deleted/unavailable).
--     Fallback in code: 'Original message unavailable'.
--   matchLocationSingle: singular mini-map header ("Location", no number) used
--     when a match has only one location, vs. matchLocationOccurrence
--     ("Location #{count}" / "Ubicación n.º {count}" / "מיקום {count}#").
--     Fallback in code: 'Location'.

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'chatReplyYou', 'You'),
  ('es', 'chatReplyYou', 'Tú'),
  ('he', 'chatReplyYou', 'את/ה'),

  ('en', 'chatReplyOriginalUnavailable', 'Original message unavailable'),
  ('es', 'chatReplyOriginalUnavailable', 'Mensaje original no disponible'),
  ('he', 'chatReplyOriginalUnavailable', 'ההודעה המקורית אינה זמינה'),

  ('en', 'matchLocationSingle', 'Location'),
  ('es', 'matchLocationSingle', 'Ubicación'),
  ('he', 'matchLocationSingle', 'מיקום')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
