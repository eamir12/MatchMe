INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'nearbyLocationLoading', 'Finding your location…'),
  ('en', 'nearbyProfileErrorMessage', 'We couldn’t load your matching radius. Try again.'),
  ('en', 'nearbyLocationUnavailableTitle', 'We couldn’t find your location'),
  ('en', 'nearbyLocationUnavailableMessage', 'Allow location access or try again. The Nearby Map uses an approximate location, never your exact position.'),
  ('en', 'nearbyLocationOfflineMessage', 'Reconnect to load the Nearby Map.'),
  ('es', 'nearbyLocationLoading', 'Buscando tu ubicación…'),
  ('es', 'nearbyProfileErrorMessage', 'No pudimos cargar tu radio de coincidencia. Inténtalo de nuevo.'),
  ('es', 'nearbyLocationUnavailableTitle', 'No pudimos encontrar tu ubicación'),
  ('es', 'nearbyLocationUnavailableMessage', 'Permite el acceso a la ubicación o inténtalo de nuevo. El mapa cercano usa una ubicación aproximada, nunca tu posición exacta.'),
  ('es', 'nearbyLocationOfflineMessage', 'Reconéctate para cargar el mapa cercano.'),
  ('he', 'nearbyLocationLoading', 'מאתרים את המיקום שלך…'),
  ('he', 'nearbyProfileErrorMessage', 'לא ניתן לטעון את רדיוס ההתאמה. נסו שוב.'),
  ('he', 'nearbyLocationUnavailableTitle', 'לא הצלחנו למצוא את המיקום שלך'),
  ('he', 'nearbyLocationUnavailableMessage', 'אפשר לאפשר גישה למיקום או לנסות שוב. מפת הקרבה משתמשת במיקום משוער, לא במיקום המדויק שלך.'),
  ('he', 'nearbyLocationOfflineMessage', 'התחברו מחדש כדי לטעון את מפת הקרבה.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
