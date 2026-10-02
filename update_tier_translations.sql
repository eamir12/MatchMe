-- Migration: Update Tier Name and Title Translations
-- Description: Localizes subscription tier names and full titles for en, es, he
-- Languages: English (en), Spanish (es), Hebrew (he)

INSERT INTO public.translations (locale, key, value) VALUES

-- ==========================================
-- TIER NAMES
-- ==========================================

-- tierFree
('en', 'tierFree', 'Free'),
('es', 'tierFree', 'Gratis'),
('he', 'tierFree', 'חינם'),

-- tierPlus
('en', 'tierPlus', 'Plus'),
('es', 'tierPlus', 'Plus'),
('he', 'tierPlus', 'פלוס'),

-- tierGold
('en', 'tierGold', 'Gold'),
('es', 'tierGold', 'Gold'),
('he', 'tierGold', 'זהב'),

-- tierPlatinum
('en', 'tierPlatinum', 'Platinum'),
('es', 'tierPlatinum', 'Platino'),
('he', 'tierPlatinum', 'פלטינום'),

-- ==========================================
-- TIER FULL TITLES
-- ==========================================

-- tierPlusTitle
('en', 'tierPlusTitle', 'MatchMe Plus'),
('es', 'tierPlusTitle', 'MatchMe Plus'),
('he', 'tierPlusTitle', 'MatchMe Plus'),

-- tierGoldTitle
('en', 'tierGoldTitle', 'MatchMe Gold'),
('es', 'tierGoldTitle', 'MatchMe Gold'),
('he', 'tierGoldTitle', 'MatchMe זהב'),

-- tierPlatinumTitle
('en', 'tierPlatinumTitle', 'MatchMe Platinum'),
('es', 'tierPlatinumTitle', 'MatchMe Platino'),
('he', 'tierPlatinumTitle', 'MatchMe פלטינום')

ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
