-- ==========================================================================
-- Cleanup Duplicate Interests & Translations
-- ==========================================================================
-- This script consolidates duplicate primary interests that share the same
-- English display value (e.g. "Technology" appearing from technology_cat,
-- technology, and business_technology). For each group:
--
--   1. Sub-interests of the removed interest are repointed to the kept one
--   2. user_interests FK references are updated
--   3. user_profiles JSONB interest keys are merged
--   4. Duplicate translation entries are removed
--   5. The duplicate interest row is deleted
--
-- Run the entire script (it is wrapped in BEGIN/COMMIT).
-- Review the diagnostic output at start and verification at end.
-- ==========================================================================

BEGIN;

-- ==========================================================================
-- SECTION 0: DIAGNOSTIC
-- ==========================================================================

SELECT '=== DIAGNOSTIC: Duplicate English translation values ===' AS step;

WITH translation_dupes AS (
  SELECT t.value, COUNT(*) AS cnt, ARRAY_AGG(t.key ORDER BY t.key) AS keys
  FROM public.translations t
  WHERE t.locale = 'en'
  GROUP BY t.value
  HAVING COUNT(*) > 1
)
SELECT td.value, td.cnt, td.keys,
       COALESCE(
         (SELECT JSON_AGG(json_build_object(
           'interest_id', i.id, 'interest_key', i.key,
           'parent_id', i.parent_id, 'translation_key', i.translation_key
         ))
         FROM public.interests i
         WHERE i.translation_key = ANY(td.keys)),
         '[]'::json
       ) AS matching_interests
FROM translation_dupes td
ORDER BY td.cnt DESC, td.value;

SELECT '=== DIAGNOSTIC: Primary interests (parent_id IS NULL) with duplicate display names ===' AS step;

WITH primary_dupes AS (
  SELECT t.value, COUNT(DISTINCT i.id) AS cnt,
         ARRAY_AGG(DISTINCT i.key ORDER BY i.key) AS interest_keys,
         ARRAY_AGG(DISTINCT t.key ORDER BY t.key) AS translation_keys
  FROM public.interests i
  JOIN public.translations t ON t.key = i.translation_key AND t.locale = 'en'
  WHERE i.parent_id IS NULL
  GROUP BY t.value
  HAVING COUNT(DISTINCT i.id) > 1
)
SELECT * FROM primary_dupes ORDER BY cnt DESC, value;

SELECT '=== Starting cleanup ===' AS step;

-- ==========================================================================
-- SECTION 1: MERGE _cat CATEGORIES INTO SPECIFIC INTERESTS
-- ==========================================================================

-- --------------------------------------------------
-- 1a. technology_cat -> technology
-- --------------------------------------------------
SELECT '--- 1a. technology_cat -> technology ---' AS step;

UPDATE public.interests AS sub
SET parent_id = (SELECT id FROM public.interests WHERE key = 'technology')
WHERE sub.parent_id = (SELECT id FROM public.interests WHERE key = 'technology_cat');

UPDATE public.user_interests AS ui
SET interest_id = (SELECT id FROM public.interests WHERE key = 'technology')
WHERE ui.interest_id = (SELECT id FROM public.interests WHERE key = 'technology_cat');

UPDATE public.user_profiles up
SET profile_data = jsonb_set(
  profile_data,
  '{interests,technology}',
  COALESCE(profile_data #> '{interests,technology}', '[]'::jsonb) ||
    COALESCE(profile_data #> '{interests,technology_cat}', '[]'::jsonb)
) #- '{interests,technology_cat}'
WHERE profile_data ? 'interests'
  AND profile_data -> 'interests' ? 'technology_cat';

DELETE FROM public.interests WHERE key = 'technology_cat';

-- --------------------------------------------------
-- 1b. entrepreneurship_cat -> entrepreneurship
-- --------------------------------------------------
SELECT '--- 1b. entrepreneurship_cat -> entrepreneurship ---' AS step;

UPDATE public.interests AS sub
SET parent_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship')
WHERE sub.parent_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship_cat');

UPDATE public.user_interests AS ui
SET interest_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship')
WHERE ui.interest_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship_cat');

UPDATE public.user_profiles up
SET profile_data = jsonb_set(
  profile_data,
  '{interests,entrepreneurship}',
  COALESCE(profile_data #> '{interests,entrepreneurship}', '[]'::jsonb) ||
    COALESCE(profile_data #> '{interests,entrepreneurship_cat}', '[]'::jsonb)
) #- '{interests,entrepreneurship_cat}'
WHERE profile_data ? 'interests'
  AND profile_data -> 'interests' ? 'entrepreneurship_cat';

DELETE FROM public.interests WHERE key = 'entrepreneurship_cat';

-- --------------------------------------------------
-- 1c. consulting_cat -> consulting
-- --------------------------------------------------
SELECT '--- 1c. consulting_cat -> consulting ---' AS step;

UPDATE public.interests AS sub
SET parent_id = (SELECT id FROM public.interests WHERE key = 'consulting')
WHERE sub.parent_id = (SELECT id FROM public.interests WHERE key = 'consulting_cat');

UPDATE public.user_interests AS ui
SET interest_id = (SELECT id FROM public.interests WHERE key = 'consulting')
WHERE ui.interest_id = (SELECT id FROM public.interests WHERE key = 'consulting_cat');

UPDATE public.user_profiles up
SET profile_data = jsonb_set(
  profile_data,
  '{interests,consulting}',
  COALESCE(profile_data #> '{interests,consulting}', '[]'::jsonb) ||
    COALESCE(profile_data #> '{interests,consulting_cat}', '[]'::jsonb)
) #- '{interests,consulting_cat}'
WHERE profile_data ? 'interests'
  AND profile_data -> 'interests' ? 'consulting_cat';

DELETE FROM public.interests WHERE key = 'consulting_cat';

-- ==========================================================================
-- SECTION 2: MERGE OLD BUSINESS INTENT CATEGORIES INTO TOP-LEVEL INTERESTS
-- ==========================================================================

-- --------------------------------------------------
-- 2a. business_technology -> technology
-- --------------------------------------------------
SELECT '--- 2a. business_technology -> technology ---' AS step;

UPDATE public.interests AS sub
SET parent_id = (SELECT id FROM public.interests WHERE key = 'technology')
WHERE sub.parent_id = (SELECT id FROM public.interests WHERE key = 'business_technology');

UPDATE public.user_interests AS ui
SET interest_id = (SELECT id FROM public.interests WHERE key = 'technology')
WHERE ui.interest_id = (SELECT id FROM public.interests WHERE key = 'business_technology');

UPDATE public.user_profiles up
SET profile_data = jsonb_set(
  profile_data,
  '{interests,technology}',
  COALESCE(profile_data #> '{interests,technology}', '[]'::jsonb) ||
    COALESCE(profile_data #> '{interests,business_technology}', '[]'::jsonb)
) #- '{interests,business_technology}'
WHERE profile_data ? 'interests'
  AND profile_data -> 'interests' ? 'business_technology';

DELETE FROM public.interests WHERE key = 'business_technology';

-- --------------------------------------------------
-- 2b. business_entrepreneurship -> entrepreneurship
-- --------------------------------------------------
SELECT '--- 2b. business_entrepreneurship -> entrepreneurship ---' AS step;

UPDATE public.interests AS sub
SET parent_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship')
WHERE sub.parent_id = (SELECT id FROM public.interests WHERE key = 'business_entrepreneurship');

UPDATE public.user_interests AS ui
SET interest_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship')
WHERE ui.interest_id = (SELECT id FROM public.interests WHERE key = 'business_entrepreneurship');

UPDATE public.user_profiles up
SET profile_data = jsonb_set(
  profile_data,
  '{interests,entrepreneurship}',
  COALESCE(profile_data #> '{interests,entrepreneurship}', '[]'::jsonb) ||
    COALESCE(profile_data #> '{interests,business_entrepreneurship}', '[]'::jsonb)
) #- '{interests,business_entrepreneurship}'
WHERE profile_data ? 'interests'
  AND profile_data -> 'interests' ? 'business_entrepreneurship';

DELETE FROM public.interests WHERE key = 'business_entrepreneurship';

-- --------------------------------------------------
-- 2c. business_finance -> finance
-- --------------------------------------------------
SELECT '--- 2c. business_finance -> finance ---' AS step;

UPDATE public.interests AS sub
SET parent_id = (SELECT id FROM public.interests WHERE key = 'finance')
WHERE sub.parent_id = (SELECT id FROM public.interests WHERE key = 'business_finance');

UPDATE public.user_interests AS ui
SET interest_id = (SELECT id FROM public.interests WHERE key = 'finance')
WHERE ui.interest_id = (SELECT id FROM public.interests WHERE key = 'business_finance');

UPDATE public.user_profiles up
SET profile_data = jsonb_set(
  profile_data,
  '{interests,finance}',
  COALESCE(profile_data #> '{interests,finance}', '[]'::jsonb) ||
    COALESCE(profile_data #> '{interests,business_finance}', '[]'::jsonb)
) #- '{interests,business_finance}'
WHERE profile_data ? 'interests'
  AND profile_data -> 'interests' ? 'business_finance';

DELETE FROM public.interests WHERE key = 'business_finance';

-- --------------------------------------------------
-- 2d. business_marketing -> marketing
-- --------------------------------------------------
SELECT '--- 2d. business_marketing -> marketing ---' AS step;

UPDATE public.interests AS sub
SET parent_id = (SELECT id FROM public.interests WHERE key = 'marketing')
WHERE sub.parent_id = (SELECT id FROM public.interests WHERE key = 'business_marketing');

UPDATE public.user_interests AS ui
SET interest_id = (SELECT id FROM public.interests WHERE key = 'marketing')
WHERE ui.interest_id = (SELECT id FROM public.interests WHERE key = 'business_marketing');

UPDATE public.user_profiles up
SET profile_data = jsonb_set(
  profile_data,
  '{interests,marketing}',
  COALESCE(profile_data #> '{interests,marketing}', '[]'::jsonb) ||
    COALESCE(profile_data #> '{interests,business_marketing}', '[]'::jsonb)
) #- '{interests,business_marketing}'
WHERE profile_data ? 'interests'
  AND profile_data -> 'interests' ? 'business_marketing';

DELETE FROM public.interests WHERE key = 'business_marketing';

-- ==========================================================================
-- SECTION 3: DELETE ORPHAN / SUPERSEDED TRANSLATIONS
-- ==========================================================================

SELECT '--- 3. Delete orphan translations ---' AS step;

DELETE FROM public.translations
WHERE key IN (
  -- Orphan from unknown source
  'interest.industry.technology',
  -- Superseded _cat category translations (all locales)
  'interest_category.technology',
  'interest_category.entrepreneurship',
  'interest_category.consulting',
  -- Superseded business intent category translations
  'interest.business.technology',
  'interest.business.entrepreneurship',
  'interest.business.finance',
  'interest.business.marketing'
);

-- ==========================================================================
-- SECTION 4: DELETE REDUNDANT OLD BUSINESS SUB-INTEREST TRANSLATIONS
-- ==========================================================================

SELECT '--- 4. Remove redundant old business sub-interest translations ---' AS step;

DELETE FROM public.translations
WHERE key IN (
  -- Technology (old business_* translation keys superseded)
  'interest.business.technology.ai',
  'interest.business.technology.cyber',
  'interest.business.technology.web',
  -- Entrepreneurship
  'interest.business.entrepreneurship.startups',
  'interest.business.entrepreneurship.investing',
  'interest.business.entrepreneurship.social',
  -- Finance
  'interest.business.finance.investing',
  'interest.business.finance.cryptocurrency',
  'interest.business.finance.accounting',
  -- Marketing
  'interest.business.marketing.digital',
  'interest.business.marketing.branding',
  'interest.business.marketing.international'
);

-- ==========================================================================
-- SECTION 5: UPDATE SUB-INTEREST TRANSLATION KEYS
-- ==========================================================================
-- Sub-interests that were reparented may still reference old translation keys.
-- Update them to the consolidated keys.

SELECT '--- 5. Update reparented sub-interest translation_keys ---' AS step;

UPDATE public.interests
SET translation_key = 'interest.technology.ai_ml'
WHERE key = 'business_technology_ai'
  AND translation_key = 'interest.business.technology.ai';

UPDATE public.interests
SET translation_key = 'interest.technology.cybersecurity'
WHERE key = 'business_technology_cyber'
  AND translation_key = 'interest.business.technology.cyber';

UPDATE public.interests
SET translation_key = 'interest.technology.web_development'
WHERE key = 'business_technology_web'
  AND translation_key = 'interest.business.technology.web';

UPDATE public.interests
SET translation_key = 'interest.entrepreneurship.bootstrapping'
WHERE key = 'business_entrepreneurship_startups'
  AND translation_key = 'interest.business.entrepreneurship.startups';

UPDATE public.interests
SET translation_key = 'interest.entrepreneurship.side_hustles'
WHERE key = 'business_entrepreneurship_investing'
  AND translation_key = 'interest.business.entrepreneurship.investing';

UPDATE public.interests
SET translation_key = 'interest.entrepreneurship.social_enterprise'
WHERE key = 'business_entrepreneurship_social'
  AND translation_key = 'interest.business.entrepreneurship.social';

UPDATE public.interests
SET translation_key = 'interest.investing'
WHERE key = 'business_finance_investing'
  AND translation_key = 'interest.business.finance.investing';

UPDATE public.interests
SET translation_key = 'interest.digital_marketing'
WHERE key = 'business_marketing_digital'
  AND translation_key = 'interest.business.marketing.digital';

UPDATE public.interests
SET translation_key = 'interest.brand_strategy'
WHERE key = 'business_marketing_branding'
  AND translation_key = 'interest.business.marketing.branding';

-- ==========================================================================
-- SECTION 6: NORMALIZE SORT ORDERS AFTER MERGE
-- ==========================================================================

SELECT '--- 6. Normalize sort orders ---' AS step;

-- Technology sub-interests (existing: 10-50, added from _cat: 60-80, from business: 90-110)
UPDATE public.interests SET sort_order = 60 WHERE key = 'tech_meetups'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'technology');
UPDATE public.interests SET sort_order = 70 WHERE key = 'coding_bootcamps'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'technology');
UPDATE public.interests SET sort_order = 80 WHERE key = 'open_source'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'technology');
UPDATE public.interests SET sort_order = 90 WHERE key = 'business_technology_ai'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'technology');
UPDATE public.interests SET sort_order = 100 WHERE key = 'business_technology_cyber'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'technology');
UPDATE public.interests SET sort_order = 110 WHERE key = 'business_technology_web'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'technology');

-- Entrepreneurship sub-interests (existing: 10-40, added from _cat: 50-70, from business: 80-100)
UPDATE public.interests SET sort_order = 50 WHERE key = 'startup_events'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship');
UPDATE public.interests SET sort_order = 60 WHERE key = 'pitch_nights'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship');
UPDATE public.interests SET sort_order = 70 WHERE key = 'founder_groups'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship');
UPDATE public.interests SET sort_order = 80 WHERE key = 'business_entrepreneurship_startups'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship');
UPDATE public.interests SET sort_order = 90 WHERE key = 'business_entrepreneurship_investing'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship');
UPDATE public.interests SET sort_order = 100 WHERE key = 'business_entrepreneurship_social'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'entrepreneurship');

-- Consulting sub-interests (existing: 10-40, added from _cat: 50-70)
UPDATE public.interests SET sort_order = 50 WHERE key = 'management_consulting'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'consulting');
UPDATE public.interests SET sort_order = 60 WHERE key = 'financial_advisory'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'consulting');
UPDATE public.interests SET sort_order = 70 WHERE key = 'career_coaching'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'consulting');

-- Finance sub-interests (existing: 10-30, added from business: need renumber)
UPDATE public.interests SET sort_order = 40 WHERE key = 'business_finance_investing'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'finance');
UPDATE public.interests SET sort_order = 50 WHERE key = 'business_finance_cryptocurrency'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'finance');
UPDATE public.interests SET sort_order = 60 WHERE key = 'business_finance_accounting'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'finance');

-- Marketing sub-interests (existing: 10-40, added from business: need renumber)
UPDATE public.interests SET sort_order = 50 WHERE key = 'business_marketing_digital'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'marketing');
UPDATE public.interests SET sort_order = 60 WHERE key = 'business_marketing_branding'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'marketing');
UPDATE public.interests SET sort_order = 70 WHERE key = 'business_marketing_international'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'marketing');

-- ==========================================================================
-- SECTION 7: VERIFICATION
-- ==========================================================================

SELECT '=== VERIFICATION: Remaining duplicate English translations ===' AS step;

WITH translation_dupes AS (
  SELECT t.value, COUNT(*) AS cnt, ARRAY_AGG(t.key ORDER BY t.key) AS keys
  FROM public.translations t
  WHERE t.locale = 'en'
  GROUP BY t.value
  HAVING COUNT(*) > 1
)
SELECT td.value, td.cnt, td.keys
FROM translation_dupes td
ORDER BY td.cnt DESC, td.value;

SELECT '=== VERIFICATION: Remaining primary interest duplicates ===' AS step;

WITH primary_dupes AS (
  SELECT t.value, COUNT(DISTINCT i.id) AS cnt,
         ARRAY_AGG(DISTINCT i.key ORDER BY i.key) AS interest_keys
  FROM public.interests i
  JOIN public.translations t ON t.key = i.translation_key AND t.locale = 'en'
  WHERE i.parent_id IS NULL
  GROUP BY t.value
  HAVING COUNT(DISTINCT i.id) > 1
)
SELECT * FROM primary_dupes ORDER BY cnt DESC, value;

SELECT '=== CLEANUP COMPLETE ===' AS step;

COMMIT;
