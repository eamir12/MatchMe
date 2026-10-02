-- Match score + sorting translations for English, Spanish, and Hebrew
-- Keys: sharedInterestsCount, sortByLabel, sortOptionNewest,
--       sortOptionMostShared, sortOptionTopRated, sortOptionExpiringSoon

-- English
INSERT INTO translations (locale, key, value) VALUES ('en', 'sharedInterestsCount', 'Shared interests: {count}') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'sortByLabel', 'Sort by') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'sortOptionNewest', 'Newest') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'sortOptionMostShared', 'Most shared') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'sortOptionTopRated', 'Top rated') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'sortOptionExpiringSoon', 'Ending soon') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish
INSERT INTO translations (locale, key, value) VALUES ('es', 'sharedInterestsCount', 'Intereses compartidos: {count}') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'sortByLabel', 'Ordenar por') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'sortOptionNewest', 'Más recientes') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'sortOptionMostShared', 'Más compartidos') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'sortOptionTopRated', 'Mejor valorados') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'sortOptionExpiringSoon', 'Termina pronto') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew
INSERT INTO translations (locale, key, value) VALUES ('he', 'sharedInterestsCount', 'תחומי עניין משותפים: {count}') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'sortByLabel', 'מיון לפי') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'sortOptionNewest', 'החדשים ביותר') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'sortOptionMostShared', 'הכי הרבה משותף') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'sortOptionTopRated', 'הדירוג הגבוה ביותר') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'sortOptionExpiringSoon', 'מסתיים בקרוב') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
