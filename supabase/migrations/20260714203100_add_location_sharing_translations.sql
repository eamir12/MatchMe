-- Location sharing translation keys
-- Run this in Supabase SQL Editor

BEGIN;

-- English translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareStart', 'Share Live Location', 'en'),
  ('locationShareView', 'View Live Location', 'en'),
  ('locationShareStop', 'Stop Sharing', 'en'),
  ('locationSharePause', 'Pause', 'en'),
  ('locationShareResume', 'Resume', 'en'),
  ('locationShareCenter', 'Center Map', 'en'),
  ('locationShareActive', 'You are sharing your live location', 'en'),
  ('locationShareReceiving', '{name} is sharing their location with you', 'en'),
  ('locationShareOtherSharing', '{name} is sharing their live location', 'en'),
  ('locationShareExpired', 'Location sharing has ended', 'en'),
  ('locationShareDurationTitle', 'Share for how long?', 'en'),
  ('locationShareUntilOff', 'Until turned off', 'en'),
  ('locationShareMinutes', '{count} minutes', 'en'),
  ('locationShareHours', '{count} hours', 'en'),
  ('locationShareOffline', 'You must be online to share your location', 'en'),
  ('locationShareOtherOffline', '{name} is currently offline', 'en'),
  ('locationShareOtherStopped', '{name} stopped sharing their location', 'en'),
  ('locationShareOtherPaused', '{name} paused their location sharing', 'en'),
  ('locationShareTimerRemaining', 'Expires in {time}', 'en'),
  ('locationShareNoLocation', 'Waiting for location...', 'en'),
  ('settingsNotificationsLocationSharing', 'Location Sharing', 'en'),
  ('locationShareMapTitle', 'Live Location', 'en'),
  ('locationShareStale', 'Stale', 'en'),
  ('locationShareYou', 'You', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareStart', 'Compartir ubicación en vivo', 'es'),
  ('locationShareView', 'Ver ubicación en vivo', 'es'),
  ('locationShareStop', 'Dejar de compartir', 'es'),
  ('locationSharePause', 'Pausar', 'es'),
  ('locationShareResume', 'Reanudar', 'es'),
  ('locationShareCenter', 'Centrar mapa', 'es'),
  ('locationShareActive', 'Estás compartiendo tu ubicación en vivo', 'es'),
  ('locationShareReceiving', '{name} está compartiendo su ubicación contigo', 'es'),
  ('locationShareOtherSharing', '{name} está compartiendo su ubicación en vivo', 'es'),
  ('locationShareExpired', 'La compartición de ubicación ha terminado', 'es'),
  ('locationShareDurationTitle', '¿Compartir por cuánto tiempo?', 'es'),
  ('locationShareUntilOff', 'Hasta que se desactive', 'es'),
  ('locationShareMinutes', '{count} minutos', 'es'),
  ('locationShareHours', '{count} horas', 'es'),
  ('locationShareOffline', 'Debes estar en línea para compartir tu ubicación', 'es'),
  ('locationShareOtherOffline', '{name} está actualmente sin conexión', 'es'),
  ('locationShareOtherStopped', '{name} dejó de compartir su ubicación', 'es'),
  ('locationShareOtherPaused', '{name} pausó la compartición de su ubicación', 'es'),
  ('locationShareTimerRemaining', 'Expira en {time}', 'es'),
  ('locationShareNoLocation', 'Esperando ubicación...', 'es'),
  ('settingsNotificationsLocationSharing', 'Compartición de ubicación', 'es'),
  ('locationShareMapTitle', 'Ubicación en vivo', 'es'),
  ('locationShareStale', 'Desactualizada', 'es'),
  ('locationShareYou', 'Tú', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (key, value, locale) VALUES
  ('locationShareStart', 'שתף מיקום חי', 'he'),
  ('locationShareView', 'צפה במיקום חי', 'he'),
  ('locationShareStop', 'הפסק שיתוף', 'he'),
  ('locationSharePause', 'השהה', 'he'),
  ('locationShareResume', 'המשך', 'he'),
  ('locationShareCenter', 'מרכז מפה', 'he'),
  ('locationShareActive', 'אתה משתף את המיקום החי שלך', 'he'),
  ('locationShareReceiving', '{name} משתף את המיקום שלו איתך', 'he'),
  ('locationShareOtherSharing', '{name} משתף את המיקום החי שלו', 'he'),
  ('locationShareExpired', 'שיתוף המיקום הסתיים', 'he'),
  ('locationShareDurationTitle', 'לשתף למשך כמה זמן?', 'he'),
  ('locationShareUntilOff', 'עד שכבה', 'he'),
  ('locationShareMinutes', '{count} דקות', 'he'),
  ('locationShareHours', '{count} שעות', 'he'),
  ('locationShareOffline', 'אתה חייב להיות מחובר כדי לשתף את המיקום שלך', 'he'),
  ('locationShareOtherOffline', '{name} כרגע לא מחובר', 'he'),
  ('locationShareOtherStopped', '{name} הפסיק לשתף את המיקום שלו', 'he'),
  ('locationShareOtherPaused', '{name} השהה את שיתוף המיקום שלו', 'he'),
  ('locationShareTimerRemaining', 'יפוג ב-{time}', 'he'),
  ('locationShareNoLocation', 'ממתין למיקום...', 'he'),
  ('settingsNotificationsLocationSharing', 'שיתוף מיקום', 'he'),
  ('locationShareMapTitle', 'מיקום חי', 'he'),
  ('locationShareStale', 'לא מעודכן', 'he'),
  ('locationShareYou', 'אתה', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
