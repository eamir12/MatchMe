-- Standardize "System default" translations across Units, Time Format, and Theme
-- This ensures consistent wording: all three dropdowns use "System default"

-- English
INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsUnitsSystem', 'System default') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsTimeFormatSystem', 'System default') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'settingsThemeModeSystem', 'System default') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish (Predeterminado del sistema)
INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsUnitsSystem', 'Predeterminado del sistema') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsTimeFormatSystem', 'Predeterminado del sistema') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'settingsThemeModeSystem', 'Predeterminado del sistema') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew (ברירת מחדל של המערכת)
INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsUnitsSystem', 'ברירת מחדל של המערכת') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsTimeFormatSystem', 'ברירת מחדל של המערכת') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'settingsThemeModeSystem', 'ברירת מחדל של המערכת') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
