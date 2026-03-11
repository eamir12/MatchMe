-- Migration: Add missing verification gesture translation
-- Key: verificationGestureCoverMouthDescription
-- Value: Cover your mouth with your right hand while keeping the rest of your face visible.

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), 'en', 'verificationGestureCoverMouthDescription', 'Cover your mouth with your right hand while keeping the rest of your face visible.', now(), now()
WHERE NOT EXISTS (
    SELECT 1 FROM translations WHERE key = 'verificationGestureCoverMouthDescription' AND locale = 'en'
);
