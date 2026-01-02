-- verify_seed.sql
-- Run this against your Supabase/Postgres DB to validate the interests/metadata seed

-- 1) Counts
SELECT 'total_interests' AS check, count(*) FROM interests;
SELECT 'interests_missing_metadata' AS check, count(*) FROM interests WHERE (metadata::jsonb ->> 'group') IS NULL OR (metadata::jsonb ->> 'type') IS NULL;
SELECT 'total_translations' AS check, count(*) FROM translations WHERE key LIKE 'interest.%';

-- 2) Any interest rows missing metadata
SELECT id, key, parent_id, translation_key, metadata FROM interests WHERE (metadata::jsonb ->> 'group') IS NULL OR (metadata::jsonb ->> 'type') IS NULL ORDER BY id LIMIT 200;

-- 3) Quick sample per intent
SELECT id, key, metadata FROM interests WHERE parent_id IS NULL ORDER BY sort_order;

-- 4) Show business and activity trees
SELECT id, key, parent_id, metadata FROM interests WHERE key LIKE 'business%' ORDER BY key;
SELECT id, key, parent_id, metadata FROM interests WHERE key LIKE 'activity%' ORDER BY key;

-- 5) Check duplicates
SELECT key, count(*) FROM interests GROUP BY key HAVING count(*) > 1;

-- 6) Example lookup of translations for business
SELECT key, locale, value FROM translations WHERE key LIKE 'interest.business.%' ORDER BY key, locale;

-- 7) Small sanity checks used by the app
-- Find top-level keys that the UI may expect
SELECT key FROM interests WHERE key IN ('romantic','friendship','activity_partner','business');

-- End of script
