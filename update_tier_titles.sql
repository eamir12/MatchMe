-- Upsert Tier Titles for Spanish and Hebrew

INSERT INTO public.translations (key, locale, value)
VALUES
-- Spanish
('tierPlusTitle', 'es', 'MatchMe Plus'),
('tierGoldTitle', 'es', 'MatchMe Oro'),
('tierPlatinumTitle', 'es', 'MatchMe Platino'),
-- Hebrew
('tierPlusTitle', 'he', 'MatchMe פלוס'),
('tierGoldTitle', 'he', 'MatchMe זהב'),
('tierPlatinumTitle', 'he', 'MatchMe פלטינום')
ON CONFLICT (key, locale) DO UPDATE SET
    value = EXCLUDED.value;
