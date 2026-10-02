-- Add 'offlineMode' translation key for English, Spanish, and Hebrew
-- This translation is used in the OfflineIndicator widget to show when the app is offline

-- English (fallback)
INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES ('offlineMode', 'en', 'You are offline', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET value = 'You are offline', updated_at = NOW();

-- Spanish
INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES ('offlineMode', 'es', 'Estás sin conexión', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET value = 'Estás sin conexión', updated_at = NOW();

-- Hebrew
INSERT INTO translations (key, locale, value, created_at, updated_at)
VALUES ('offlineMode', 'he', 'אתה במצב לא מקוון', NOW(), NOW())
ON CONFLICT (key, locale) DO UPDATE SET value = 'אתה במצב לא מקוון', updated_at = NOW();
