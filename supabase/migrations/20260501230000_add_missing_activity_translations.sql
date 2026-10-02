-- Add missing activity/interest translation keys
-- These keys are used for activity/interest categories in the app

BEGIN;

-- Insert for English (en)
INSERT INTO translations (key, value, locale) VALUES
  ('movies', 'Movies', 'en'),
  ('walks', 'Walks', 'en'),
  ('board_games', 'Board Games', 'en'),
  ('coffee_meetups', 'Coffee Meetups', 'en'),
  ('hiking_trails', 'Hiking Trails', 'en'),
  ('traveling', 'Traveling', 'en'),
  ('live_music', 'Live Music', 'en'),
  ('music_and_art', 'Music & Art', 'en'),
  ('study_and_learning', 'Study & Learning', 'en')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Insert for Spanish (es)
INSERT INTO translations (key, value, locale) VALUES
  ('movies', 'Películas', 'es'),
  ('walks', 'Paseos', 'es'),
  ('board_games', 'Juegos de Mesa', 'es'),
  ('coffee_meetups', 'Encuentros de Café', 'es'),
  ('hiking_trails', 'Senderos de Montaña', 'es'),
  ('traveling', 'Viajes', 'es'),
  ('live_music', 'Música en Vivo', 'es'),
  ('music_and_art', 'Música y Arte', 'es'),
  ('study_and_learning', 'Estudio y Aprendizaje', 'es')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- Insert for Hebrew (he)
INSERT INTO translations (key, value, locale) VALUES
  ('movies', 'סרטים', 'he'),
  ('walks', 'טיולים', 'he'),
  ('board_games', 'משחקי לוח', 'he'),
  ('coffee_meetups', 'מפגשי קפה', 'he'),
  ('hiking_trails', 'שבילי הליכה', 'he'),
  ('traveling', 'נסיעות', 'he'),
  ('live_music', 'מוזיקה חיה', 'he'),
  ('music_and_art', 'מוזיקה ואמנות', 'he'),
  ('study_and_learning', 'לימוד ולמידה', 'he')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
