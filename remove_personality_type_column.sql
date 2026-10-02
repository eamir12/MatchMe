-- Remove personality_type column (zodiac_sign is auto-calculated from date_of_birth)
ALTER TABLE users DROP COLUMN IF EXISTS personality_type;
