-- Add 'offlineMessageQueuedToast' translation key for English, Spanish, and Hebrew
-- This translation is shown as a snackbar when the user sends a chat message
-- while the device is offline, so they understand the message will be sent
-- later instead of being lost.

-- English (fallback)
INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES (
  'offlineMessageQueuedToast',
  'en',
  'You''re offline — message will be sent when you''re back online',
  NOW(),
  NOW()
)
ON CONFLICT (key, locale) DO UPDATE SET
  value = 'You''re offline — message will be sent when you''re back online',
  updated_at = NOW();

-- Spanish
INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES (
  'offlineMessageQueuedToast',
  'es',
  'Estás sin conexión — el mensaje se enviará cuando vuelvas a estar en línea',
  NOW(),
  NOW()
)
ON CONFLICT (key, locale) DO UPDATE SET
  value = 'Estás sin conexión — el mensaje se enviará cuando vuelvas a estar en línea',
  updated_at = NOW();

-- Hebrew
INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES (
  'offlineMessageQueuedToast',
  'he',
  'אתה במצב לא מקוון — ההודעה תישלח כשתחזור לחיבור',
  NOW(),
  NOW()
)
ON CONFLICT (key, locale) DO UPDATE SET
  value = 'אתה במצב לא מקוון — ההודעה תישלח כשתחזור לחיבור',
  updated_at = NOW();
