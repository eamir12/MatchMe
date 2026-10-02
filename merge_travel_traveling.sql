-- ==========================================================================
-- Merge traveling (id=3) into travel (id=56)
-- ==========================================================================
-- traveling is a top-level duplicate of the travel category.
-- This script reparents traveling's sub-interests to travel,
-- updates user_interests and user_profiles, then deletes traveling.
-- ==========================================================================

BEGIN;

-- ==========================================================================
-- SECTION 0: DIAGNOSTIC
-- ==========================================================================

SELECT '=== DIAGNOSTIC: traveling interest ===' AS step;

SELECT id, key, translation_key, parent_id, sort_order
FROM public.interests WHERE key IN ('travel', 'traveling');

SELECT '=== DIAGNOSTIC: Children of traveling ===' AS step;

SELECT id, key, translation_key, parent_id, sort_order
FROM public.interests WHERE parent_id = (SELECT id FROM public.interests WHERE key = 'traveling');

SELECT '=== DIAGNOSTIC: Children of travel ===' AS step;

SELECT id, key, translation_key, parent_id, sort_order
FROM public.interests WHERE parent_id = (SELECT id FROM public.interests WHERE key = 'travel');

SELECT '=== DIAGNOSTIC: user_interests count for traveling ===' AS step;

SELECT COUNT(*) FROM public.user_interests
WHERE interest_id = (SELECT id FROM public.interests WHERE key = 'traveling');

SELECT '=== DIAGNOSTIC: user_profiles with traveling key ===' AS step;

SELECT COUNT(*) FROM public.user_profiles
WHERE profile_data ? 'interests'
  AND profile_data -> 'interests' ? 'traveling';

SELECT '=== DIAGNOSTIC: Translations for traveling ===' AS step;

SELECT key, locale, value FROM public.translations
WHERE key IN ('interest.traveling', 'traveling')
ORDER BY key, locale;

-- ==========================================================================
-- SECTION 1: REPARENT CHILDREN
-- ==========================================================================

SELECT '--- 1. Reparent children of traveling to travel ---' AS step;

UPDATE public.interests AS sub
SET parent_id = (SELECT id FROM public.interests WHERE key = 'travel')
WHERE sub.parent_id = (SELECT id FROM public.interests WHERE key = 'traveling');

-- ==========================================================================
-- SECTION 2: UPDATE USER_INTERISTS FK REFERENCES
-- ==========================================================================

SELECT '--- 2. Update user_interests references ---' AS step;

UPDATE public.user_interests AS ui
SET interest_id = (SELECT id FROM public.interests WHERE key = 'travel')
WHERE ui.interest_id = (SELECT id FROM public.interests WHERE key = 'traveling');

-- ==========================================================================
-- SECTION 3: UPDATE USER_PROFILES JSONB
-- ==========================================================================

SELECT '--- 3. Merge traveling into travel in user_profiles ---' AS step;

UPDATE public.user_profiles up
SET profile_data = jsonb_set(
  profile_data,
  '{interests,travel}',
  COALESCE(profile_data #> '{interests,travel}', '[]'::jsonb) ||
    COALESCE(profile_data #> '{interests,traveling}', '[]'::jsonb)
) #- '{interests,traveling}'
WHERE profile_data ? 'interests'
  AND profile_data -> 'interests' ? 'traveling';

-- ==========================================================================
-- SECTION 4: DELETE ORPHAN TRANSLATIONS
-- ==========================================================================

SELECT '--- 4. Delete orphan translations for interest.traveling and bare key ---' AS step;

DELETE FROM public.translations
WHERE key IN ('interest.traveling', 'traveling');

-- ==========================================================================
-- SECTION 5: DELETE THE DUPLICATE INTEREST
-- ==========================================================================

SELECT '--- 5. Delete traveling interest row ---' AS step;

DELETE FROM public.interests WHERE key = 'traveling';

-- ==========================================================================
-- SECTION 6: NORMALIZE SORT ORDERS
-- ==========================================================================

SELECT '--- 6. Normalize sort orders for merged travel sub-interests ---' AS step;

-- Existing travel children (keep existing order):
--   beach_vacations:   10
--   mountain_retreats: 20
--   city_breaks:       30
--   cruises:           40
-- Former traveling children (renumber after existing):
--   backpacking:       50
--   road_trips:        60
--   adventure_travel:   70
--   cultural_tourism:  80
UPDATE public.interests SET sort_order = 50 WHERE key = 'backpacking'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'travel');
UPDATE public.interests SET sort_order = 60 WHERE key = 'road_trips'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'travel');
UPDATE public.interests SET sort_order = 70 WHERE key = 'adventure_travel'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'travel');
UPDATE public.interests SET sort_order = 80 WHERE key = 'cultural_tourism'
  AND parent_id = (SELECT id FROM public.interests WHERE key = 'travel');

-- ==========================================================================
-- SECTION 7: VERIFICATION
-- ==========================================================================

SELECT '=== VERIFICATION: traveling should no longer exist ===' AS step;

SELECT id, key, translation_key, parent_id
FROM public.interests WHERE key = 'traveling';

SELECT '=== VERIFICATION: All children now under travel ===' AS step;

SELECT id, key, translation_key, parent_id, sort_order
FROM public.interests WHERE parent_id = (SELECT id FROM public.interests WHERE key = 'travel')
ORDER BY sort_order;

SELECT '=== VERIFICATION: No orphan user_interests references ===' AS step;

SELECT COUNT(*) FROM public.user_interests
WHERE interest_id NOT IN (SELECT id FROM public.interests);

SELECT '=== VERIFICATION: No orphan user_profiles references ===' AS step;

SELECT COUNT(*) FROM public.user_profiles
WHERE profile_data ? 'interests'
  AND profile_data -> 'interests' ? 'traveling';

SELECT '=== MERGE COMPLETE ===' AS step;

COMMIT;
