-- Seed admin dashboard live/drilldown/map translations (en/es/he). Safe to re-run.
-- These keys exist in main.dart _defaultTranslations (English fallback) but were
-- missing from the Supabase translations table, causing English text in the
-- Hebrew/Spanish admin UI.

INSERT INTO public.translations (locale, key, value) VALUES

  ('en', 'adminDashboardLive', $$LIVE$$),
  ('es', 'adminDashboardLive', $$EN VIVO$$),
  ('he', 'adminDashboardLive', $$לייב$$),

  ('en', 'adminDashboardLastRefreshed', $$Last refreshed: {time}$$),
  ('es', 'adminDashboardLastRefreshed', $$Última actualización: {time}$$),
  ('he', 'adminDashboardLastRefreshed', $$עודכן לאחרונה: {time}$$),

  ('en', 'adminDrilldownOfflineNotCached', $$No cached data available. Connect to the internet to load details.$$),
  ('es', 'adminDrilldownOfflineNotCached', $$No hay datos en caché disponibles. Conéctese a internet para cargar los detalles.$$),
  ('he', 'adminDrilldownOfflineNotCached', $$אין נתוני מטמון זמינים. התחברו לאינטרנט כדי לטעון פרטים.$$),

  ('en', 'adminDrilldownMap', $$Map$$),
  ('es', 'adminDrilldownMap', $$Mapa$$),
  ('he', 'adminDrilldownMap', $$מפה$$),

  ('en', 'adminDrilldownNoLocation', $$No location available$$),
  ('es', 'adminDrilldownNoLocation', $$Ubicación no disponible$$),
  ('he', 'adminDrilldownNoLocation', $$אין מיקום זמין$$),

  ('en', 'adminDrilldownNoUsersMatch', $$No users matching "{query}"$$),
  ('es', 'adminDrilldownNoUsersMatch', $$No hay usuarios que coincidan con "{query}"$$),
  ('he', 'adminDrilldownNoUsersMatch', $$אין משתמשים התואמים ל-"{query}"$$),

  ('en', 'adminDrilldownSearchHint', $$Search by name or ID...$$),
  ('es', 'adminDrilldownSearchHint', $$Buscar por nombre o ID...$$),
  ('he', 'adminDrilldownSearchHint', $$חיפוש לפי שם או מזהה...$$),

  ('en', 'adminDrilldownShowOnMap', $$Show on map$$),
  ('es', 'adminDrilldownShowOnMap', $$Mostrar en el mapa$$),
  ('he', 'adminDrilldownShowOnMap', $$הצג במפה$$),

  ('en', 'adminDrilldownViewOnMap', $$View on Map$$),
  ('es', 'adminDrilldownViewOnMap', $$Ver en el mapa$$),
  ('he', 'adminDrilldownViewOnMap', $$צפייה במפה$$),

  ('en', 'adminMapFailedToLoad', $$Failed to load locations$$),
  ('es', 'adminMapFailedToLoad', $$No se pudieron cargar las ubicaciones$$),
  ('he', 'adminMapFailedToLoad', $$טעינת המיקומים נכשלה$$),

  ('en', 'adminMapLastActive', $$Last active: {time}$$),
  ('es', 'adminMapLastActive', $$Última actividad: {time}$$),
  ('he', 'adminMapLastActive', $$פעילות אחרונה: {time}$$),

  ('en', 'adminMapNoUsersWithLocations', $$No users with locations$$),
  ('es', 'adminMapNoUsersWithLocations', $$No hay usuarios con ubicaciones$$),
  ('he', 'adminMapNoUsersWithLocations', $$אין משתמשים עם מיקום$$),

  ('en', 'adminMapUsersCount', $${count} users$$),
  ('es', 'adminMapUsersCount', $${count} usuarios$$),
  ('he', 'adminMapUsersCount', $${count} משתמשים$$)

ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;