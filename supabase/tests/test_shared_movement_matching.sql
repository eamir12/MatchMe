-- Test cases for shared movement (co-motion) matching inside
-- public.perform_continuous_user_matching()
--
-- Fixture: pairs of users co-moving (similar speed + heading) within the
-- ~25m movement corridor, with compliant profiles (shared intent,
-- overlapping sub-intents and interests, no preference filters).
--
--  A+B: enabled, 20m apart, both radii 5m  -> co_motion match (radius bump)
--  C+D: enabled, 15m apart, opposite headings -> NO match (not co-moving)
--  E+F: enabled, 3m apart, both radii 50m  -> proximity match (no bump)
--  G+H: one user disabled, co-moving       -> NO match
--
-- NOTE: Run these in a disposable/staging DB (same harness as the other
-- supabase/tests scripts). Default config values are assumed.

-- =============================================================
-- Cleanup (start and end)
-- =============================================================
DELETE FROM matches WHERE user1_id::text LIKE '00000000-0000-0000-0001-00000000000%'
   OR user2_id::text LIKE '00000000-0000-0000-0001-00000000000%';
DELETE FROM movement_co_motion WHERE user1_id::text LIKE '00000000-0000-0000-0001-00000000000%';
DELETE FROM user_locations WHERE user_id::text LIKE '00000000-0000-0000-0001-00000000000%';
DELETE FROM user_activity WHERE user_id::text LIKE '00000000-0000-0000-0001-00000000000%';
DELETE FROM user_profiles WHERE user_id::text LIKE '00000000-0000-0000-0001-00000000000%';
DELETE FROM users WHERE id::text LIKE '00000000-0000-0000-0001-00000000000%';

-- =============================================================
-- Users. Radii in meters; shared_movement_matching_enabled per pair case.
-- =============================================================
INSERT INTO users (id, email, name, gender, date_of_birth, match_radius_default, shared_movement_matching_enabled, user_visibility_setting, system_visibility_status, created_at) VALUES
  ('00000000-0000-0000-0001-000000000001', 'test_comotion_a@example.com', 'CoMotion A', 'male',   '1995-05-05', 5,  TRUE,  TRUE, 'visible', NOW()),
  ('00000000-0000-0000-0001-000000000002', 'test_comotion_b@example.com', 'CoMotion B', 'female', '1995-05-05', 5,  TRUE,  TRUE, 'visible', NOW()),
  ('00000000-0000-0000-0001-000000000003', 'test_comotion_c@example.com', 'CoMotion C', 'male',   '1995-05-05', 5,  TRUE,  TRUE, 'visible', NOW()),
  ('00000000-0000-0000-0001-000000000004', 'test_comotion_d@example.com', 'CoMotion D', 'female', '1995-05-05', 5,  TRUE,  TRUE, 'visible', NOW()),
  ('00000000-0000-0000-0001-000000000005', 'test_comotion_e@example.com', 'CoMotion E', 'male',   '1995-05-05', 50, TRUE,  TRUE, 'visible', NOW()),
  ('00000000-0000-0000-0001-000000000006', 'test_comotion_f@example.com', 'CoMotion F', 'female', '1995-05-05', 50, TRUE,  TRUE, 'visible', NOW()),
  ('00000000-0000-0000-0001-000000000007', 'test_comotion_g@example.com', 'CoMotion G', 'male',   '1995-05-05', 5,  FALSE, TRUE, 'visible', NOW()),
  ('00000000-0000-0000-0001-000000000008', 'test_comotion_h@example.com', 'CoMotion H', 'female', '1995-05-05', 5,  TRUE,  TRUE, 'visible', NOW());

INSERT INTO user_activity (user_id, is_online, last_activity)
SELECT id, TRUE, NOW() FROM users WHERE id::text LIKE '00000000-0000-0000-0001-00000000000%';

-- Compliant profiles: shared intents, overlapping sub-intents and interests,
-- no gender/age/filter preferences set (so nothing else can block the pair).
INSERT INTO user_profiles (user_id, active_modes, sub_intents, personal_interests)
SELECT id,
       '["romantic","friendship"]'::jsonb,
       '{"romantic": ["casual_dating","serious_relationship"], "friendship": ["activity_partners"]}'::jsonb,
       '{"music": ["rock","indie"]}'::jsonb
FROM users WHERE id::text LIKE '00000000-0000-0000-0001-00000000000%';

-- =============================================================
-- Locations. All moving at 10 m/s. ~0.00018 deg lat ~ 20m.
-- =============================================================
-- A+B: co-moving (heading 90), 20m apart -> outside both 5m radii.
INSERT INTO user_locations (user_id, latitude, longitude, speed, heading, updated_at) VALUES
  ('00000000-0000-0000-0001-000000000001', 52.52000, 13.40500, 10, 90, NOW()),
  ('00000000-0000-0000-0001-000000000002', 52.52018, 13.40500, 10, 90, NOW()),
  -- C+D: 15m apart but heading in opposite directions.
  ('00000000-0000-0000-0001-000000000003', 52.52100, 13.40500, 10, 90,  NOW()),
  ('00000000-0000-0000-0001-000000000004', 52.52113, 13.40500, 10, 270, NOW()),
  -- E+F: co-moving but only 3m apart, inside both 50m radii -> proximity.
  ('00000000-0000-0000-0001-000000000005', 52.52200, 13.40500, 10, 90, NOW()),
  ('00000000-0000-0000-0001-000000000006', 52.52203, 13.40500, 10, 90, NOW()),
  -- G+H: co-moving and 10m apart, but G has the option OFF.
  ('00000000-0000-0000-0001-000000000007', 52.52300, 13.40500, 10, 90, NOW()),
  ('00000000-0000-0000-0001-000000000008', 52.52309, 13.40500, 10, 90, NOW());

-- Pre-seed sustained co-motion for A+B: first seen 2 minutes ago, last
-- confirmed 10 seconds ago (simulates the previous cron run's confirmation).
INSERT INTO movement_co_motion (user1_id, user2_id, first_seen, last_seen) VALUES
  ('00000000-0000-0000-0001-000000000001', '00000000-0000-0000-0001-000000000002', NOW() - INTERVAL '2 minutes', NOW() - INTERVAL '10 seconds');

-- =============================================================
-- Run the matcher once.
-- =============================================================
SELECT public.perform_continuous_user_matching();

-- =============================================================
-- Assertions
-- =============================================================
-- Expected: exactly one co_motion match (A+B) and exactly one proximity
-- match (E+F). C+D and G+H must not match.
SELECT
  (SELECT count(*) FROM matches WHERE match_type = 'co_motion'
     AND (user1_id, user2_id) IN (('00000000-0000-0000-0001-000000000001','00000000-0000-0000-0001-000000000002'))
  ) AS ab_comotion_match,        -- expect 1
  (SELECT count(*) FROM matches WHERE match_type = 'proximity'
     AND (user1_id, user2_id) IN (('00000000-0000-0000-0001-000000000005','00000000-0000-0000-0001-000000000006'))
  ) AS ef_proximity_match,       -- expect 1
  (SELECT count(*) FROM matches
     WHERE (user1_id, user2_id) IN (('00000000-0000-0000-0001-000000000003','00000000-0000-0000-0001-000000000004'))
  ) AS cd_no_match,              -- expect 0 (opposite headings)
  (SELECT count(*) FROM matches
     WHERE user1_id IN ('00000000-0000-0000-0001-000000000007','00000000-0000-0000-0001-000000000008')
        OR user2_id IN ('00000000-0000-0000-0001-000000000007','00000000-0000-0000-0001-000000000008')
  ) AS gh_no_match;              -- expect 0 (option off on G)

-- Fresh (unsustained) pairs must not have matched on a single run:
-- C+D and G+H staging rows may exist, but only A+B should have a match.
SELECT user1_id, user2_id, match_type, matched_intent, match_occurrence
FROM matches
WHERE user1_id::text LIKE '00000000-0000-0000-0001-00000000000%'
   OR user2_id::text LIKE '00000000-0000-0000-0001-00000000000%';

-- =============================================================
-- Second run sanity: with the match already present, nothing duplicates.
-- =============================================================
SELECT public.perform_continuous_user_matching();

SELECT count(*) AS total_matches_after_second_run  -- expect 2
FROM matches
WHERE user1_id::text LIKE '00000000-0000-0000-0001-00000000000%'
   OR user2_id::text LIKE '00000000-0000-0000-0001-00000000000%';

-- =============================================================
-- Cleanup
-- =============================================================
DELETE FROM matches WHERE user1_id::text LIKE '00000000-0000-0000-0001-00000000000%'
   OR user2_id::text LIKE '00000000-0000-0000-0001-00000000000%';
DELETE FROM movement_co_motion WHERE user1_id::text LIKE '00000000-0000-0000-0001-00000000000%';
DELETE FROM user_locations WHERE user_id::text LIKE '00000000-0000-0000-0001-00000000000%';
DELETE FROM user_activity WHERE user_id::text LIKE '00000000-0000-0000-0001-00000000000%';
DELETE FROM user_profiles WHERE user_id::text LIKE '00000000-0000-0000-0001-00000000000%';
DELETE FROM users WHERE id::text LIKE '00000000-0000-0000-0001-00000000000%';
