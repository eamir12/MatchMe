-- Standardize all Hebrew translations of "Gold" to use "זהב" instead of "גולד"

-- Update tierGold key to use proper Hebrew word "זהב"
UPDATE translations SET value = 'זהב' WHERE locale = 'he' AND key = 'tierGold';

-- Ensure tierGoldTitle uses "זהב"
UPDATE translations SET value = 'MatchMe זהב' WHERE locale = 'he' AND key = 'tierGoldTitle';

-- Ensure tierGoldSubtitle is consistent
UPDATE translations SET value = 'ראה מי אהב אותך' WHERE locale = 'he' AND key = 'tierGoldSubtitle';

-- Verify all Gold-related keys are standardized
SELECT key, value FROM translations WHERE locale = 'he' AND (key LIKE '%Gold%' OR value LIKE '%זהב%' OR value LIKE '%גולד%') ORDER BY key;
