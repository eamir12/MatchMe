BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('navHome', 'Home', 'en'),
  ('navMatches', 'Matches', 'en'),
  ('navChats', 'Chats', 'en'),
  ('navProfile', 'Profile', 'en'),
  ('homeRecentMatches', 'Recent Matches', 'en'),
  ('homeRecentChats', 'Recent Chats', 'en'),
  ('homeNoMatches', 'No recent matches', 'en'),
  ('homeNoChats', 'No recent chats', 'en'),
  ('youAreOffline', 'You are offline', 'en'),
  ('profileAgeLabel', 'Age', 'en'),
  ('profileGender', 'Gender', 'en'),
  ('tierFree', 'Free', 'en'),
  ('tierPlus', 'Plus', 'en'),
  ('tierGold', 'Gold', 'en'),
  ('tierPlatinum', 'Platinum', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO translations (key, value, locale) VALUES
  ('navHome', 'Inicio', 'es'),
  ('navMatches', 'Matches', 'es'),
  ('navChats', 'Chats', 'es'),
  ('navProfile', 'Perfil', 'es'),
  ('homeRecentMatches', 'Matches recientes', 'es'),
  ('homeRecentChats', 'Chats recientes', 'es'),
  ('homeNoMatches', 'No hay matches recientes', 'es'),
  ('homeNoChats', 'No hay chats recientes', 'es'),
  ('youAreOffline', 'Estas sin conexion', 'es'),
  ('profileAgeLabel', 'Edad', 'es'),
  ('profileGender', 'Genero', 'es'),
  ('tierFree', 'Gratis', 'es'),
  ('tierPlus', 'Plus', 'es'),
  ('tierGold', 'Gold', 'es'),
  ('tierPlatinum', 'Platinum', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO translations (key, value, locale) VALUES
  ('navHome', 'בית', 'he'),
  ('navMatches', 'התאמות', 'he'),
  ('navChats', 'צ׳אטים', 'he'),
  ('navProfile', 'פרופיל', 'he'),
  ('homeRecentMatches', 'התאמות אחרונות', 'he'),
  ('homeRecentChats', 'צ׳אטים אחרונים', 'he'),
  ('homeNoMatches', 'אין התאמות אחרונות', 'he'),
  ('homeNoChats', 'אין צ׳אטים אחרונים', 'he'),
  ('youAreOffline', 'את/ה לא מחובר/ת', 'he'),
  ('profileAgeLabel', 'גיל', 'he'),
  ('profileGender', 'מגדר', 'he'),
  ('tierFree', 'חינם', 'he'),
  ('tierPlus', 'פלוס', 'he'),
  ('tierGold', 'זהב', 'he'),
  ('tierPlatinum', 'פלטינום', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

COMMIT;
