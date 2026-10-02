-- Missing interest translations for English, Spanish, and Hebrew
-- These 5 keys were missed by add_missing_interest_translations.sql

-- English
INSERT INTO translations (locale, key, value) VALUES ('en', 'founder_groups', 'Founder Groups') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'gaming', 'Gaming') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'knitting', 'Knitting') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'ballroom', 'Ballroom') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'bootstrapping', 'Bootstrapping') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish
INSERT INTO translations (locale, key, value) VALUES ('es', 'founder_groups', 'Grupos de Fundadores') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'gaming', 'Videojuegos') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'knitting', 'Tejer') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'ballroom', 'Baile de salón') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'bootstrapping', 'Arranque propio') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew
INSERT INTO translations (locale, key, value) VALUES ('he', 'founder_groups', 'קבוצות מייסדים') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'gaming', 'גיימינג') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'knitting', 'סריגה') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'ballroom', 'ריקודי סלון') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'bootstrapping', 'הפעלה עצמית') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
