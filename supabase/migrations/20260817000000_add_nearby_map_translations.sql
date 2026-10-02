INSERT INTO translations (locale, key, value) VALUES
  ('en', 'homeNearbyMap', 'Nearby Map'),
  ('en', 'homeNearbyMapDesc', 'See who is around you within your match radius.'),
  ('en', 'homeNearbyMapRadius', 'Your currently selected radius: {radius}'),
  ('es', 'homeNearbyMap', 'Mapa de Cercanos'),
  ('es', 'homeNearbyMapDesc', 'Descubre quién está cerca de ti dentro de tu radio de coincidencia.'),
  ('es', 'homeNearbyMapRadius', 'Tu radio seleccionado actualmente: {radius}'),
  ('he', 'homeNearbyMap', 'מפה סמוכה'),
  ('he', 'homeNearbyMapDesc', 'ראה מי נמצא סביבך בתוך רדיוס ההתאמות שלך.'),
  ('he', 'homeNearbyMapRadius', 'הרדיוס שבחרת כעת: {radius}')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value;
