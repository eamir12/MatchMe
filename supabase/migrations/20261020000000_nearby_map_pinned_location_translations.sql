INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'homeNearbyMapPinAction', 'Pin current location'),
  ('en', 'homeNearbyMapPinnedLocation', 'Your location is currently pinned{label}.'),
  ('en', 'homeNearbyMapPinnedToLabel', 'to'),
  ('he', 'homeNearbyMapPinAction', 'הצמד את המיקום הנוכחי'),
  ('he', 'homeNearbyMapPinnedLocation', 'המיקום שלך מוצמד כרגע{label}.'),
  ('he', 'homeNearbyMapPinnedToLabel', 'ל'),
  ('es', 'homeNearbyMapPinAction', 'Fijar ubicación actual'),
  ('es', 'homeNearbyMapPinnedLocation', 'Tu ubicación está fijada actualmente{label}.'),
  ('es', 'homeNearbyMapPinnedToLabel', 'a')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
