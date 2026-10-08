-- Migration: Remove inaccurate "~10 minutes" claim from iOS background matching copy
-- Date: 2026-10-05
--
-- The native iOS background service (ios/Runner/MatchMeBackgroundService.swift)
-- posts location updates to update_user_location every gps_interval seconds
-- (default 5s) while moving, driven by CLLocationManager delegate callbacks
-- with allowsBackgroundLocationUpdates enabled; 60s only when stationary or on
-- low battery. No 10-minute cadence exists anywhere in the code. The old
-- copy described a worst-case relaunch delay after a force-quit as if it were
-- the operating interval. Replaced with the actual permission requirement and
-- an honest note about relaunch after iOS stops the app.

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'settingsHighAccuracyModeDesc_ios', 'Keep matching even after closing the app. Your location updates periodically in the background so you stay visible to potential matches.
• Requires background location permission (Allow Always). If iOS fully stops the app, updates resume automatically when you move again.'),
  ('es', 'settingsHighAccuracyModeDesc_ios', 'Sigue coincidiendo incluso después de cerrar la app. Tu ubicación se actualiza periódicamente en segundo plano para que sigas siendo visible para posibles coincidencias.
• Requiere el permiso de ubicación en segundo plano (Permitir siempre). Si iOS detiene la app por completo, las actualizaciones se reanudan automáticamente cuando te vuelves a mover.'),
  ('he', 'settingsHighAccuracyModeDesc_ios', 'המשך להתאים גם לאחר סגירת האפליקציה. המיקום שלך מתעדכן מעת לעת ברקע כך שתישאר גלוי להתאמות פוטנציאליות.
• דורש הרשאת מיקום ברקע (אפשר תמיד). אם iOS עוצר את האפליקציה לחלוטין, העדכונים חוזרים באופן אוטומטי כשמתחילים לזוז שוב.')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value;
