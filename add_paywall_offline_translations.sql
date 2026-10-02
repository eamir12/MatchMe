-- Add 'paywallOfflineTitle' and 'paywallOfflineBody' translation keys
-- for English, Spanish, and Hebrew.
-- These are shown when the user opens the subscription paywall while
-- offline and no cached subscription tiers are available on the device.

-- English (fallback)
INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES (
  'paywallOfflineTitle',
  'en',
  'Subscription details unavailable',
  NOW(),
  NOW()
)
ON CONFLICT (key, locale) DO UPDATE SET
  value = 'Subscription details unavailable',
  updated_at = NOW();

INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES (
  'paywallOfflineBody',
  'en',
  'You''re offline and we don''t have a recent copy of the subscription tiers cached on this device. Please connect to the internet to view subscription options.',
  NOW(),
  NOW()
)
ON CONFLICT (key, locale) DO UPDATE SET
  value = 'You''re offline and we don''t have a recent copy of the subscription tiers cached on this device. Please connect to the internet to view subscription options.',
  updated_at = NOW();

-- Spanish
INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES (
  'paywallOfflineTitle',
  'es',
  'Detalles de la suscripción no disponibles',
  NOW(),
  NOW()
)
ON CONFLICT (key, locale) DO UPDATE SET
  value = 'Detalles de la suscripción no disponibles',
  updated_at = NOW();

INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES (
  'paywallOfflineBody',
  'es',
  'Estás sin conexión y no tenemos una copia reciente de los niveles de suscripción guardada en este dispositivo. Conéctate a internet para ver las opciones de suscripción.',
  NOW(),
  NOW()
)
ON CONFLICT (key, locale) DO UPDATE SET
  value = 'Estás sin conexión y no tenemos una copia reciente de los niveles de suscripción guardada en este dispositivo. Conéctate a internet para ver las opciones de suscripción.',
  updated_at = NOW();

-- Hebrew
INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES (
  'paywallOfflineTitle',
  'he',
  'פרטי המנוי אינם זמינים',
  NOW(),
  NOW()
)
ON CONFLICT (key, locale) DO UPDATE SET
  value = 'פרטי המנוי אינם זמינים',
  updated_at = NOW();

INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES (
  'paywallOfflineBody',
  'he',
  'אתה במצב לא מקוון ואין לנו עותק עדכני של רמות המנוי שמור במכשיר זה. אנא התחבר לאינטרנט כדי להציג את אפשרויות המנוי.',
  NOW(),
  NOW()
)
ON CONFLICT (key, locale) DO UPDATE SET
  value = 'אתה במצב לא מקוון ואין לנו עותק עדכני של רמות המנוי שמור במכשיר זה. אנא התחבר לאינטרנט כדי להציג את אפשרויות המנוי.',
  updated_at = NOW();
