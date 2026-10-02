-- Set first match location to Arequipa for pair dd6d20a5 <-> ffc20046
-- After this, MatchProfile for b26db4c2 (occurrence 2) will show:
--   Location #1: Arequipa (-16.41/-71.54)
--   Location #2: current (-13.52/-71.99) second town
-- Run in Supabase SQL Editor (service_role).

BEGIN;

-- Update history for the pair to make occurrence 1 = Arequipa
UPDATE public.unmatched_pairs
SET locations_history = jsonb_build_array(
  jsonb_build_object(
    'occurrence', 1,
    'map_center_lat', -16.409047,
    'map_center_lng', -71.537451,
    'map_zoom', 13,
    'matched_intent', 'romantic',
    'created_at', '2026-08-30T05:34:27.917234+00',
    'match_id', 'eade9e70-1369-4b7a-9fce-dfd1db363b78'
  )
)
WHERE user1_id = 'dd6d20a5-cd79-4761-8a74-751acb555b4d'
  AND user2_id = 'ffc20046-a777-463b-922a-547151aa1455';

-- Verify that current rematch still has its second-town center (should be -13.52/-71.99)
-- If you want to force second town to be visibly different from Arequipa, ensure it stays as is:
UPDATE public.matches
SET map_center_lat = -13.52, map_center_lng = -71.99, map_zoom = 13
WHERE id = 'b26db4c2-1768-499b-a33f-339da0ed71f9' AND map_center_lat IS NOT NULL;

COMMIT;

-- Verification
SELECT 'unmatched_pairs history (should be Arequipa occ1)' as check, locations_history FROM public.unmatched_pairs WHERE user1_id='dd6d20a5-cd79-4761-8a74-751acb555b4d' AND user2_id='ffc20046-a777-463b-922a-547151aa1455';
SELECT 'current match center (should be -13.52/-71.99)' as check, id, match_occurrence, map_center_lat, map_center_lng, map_zoom FROM public.matches WHERE id='b26db4c2-1768-499b-a33f-339da0ed71f9';
SELECT 'get_user_recent_matches previous_locations (should have 1 Arequipa entry)' as check, previous_locations FROM public.get_user_recent_matches('dd6d20a5-cd79-4761-8a74-751acb555b4d', 5) WHERE match_id='b26db4c2-1768-499b-a33f-339da0ed71f9'
UNION ALL
SELECT 'get_user_recent_matches previous_locations' as check, previous_locations FROM public.get_user_recent_matches('ffc20046-a777-463b-922a-547151aa1455', 5) WHERE match_id='b26db4c2-1768-499b-a33f-339da0ed71f9';

-- Client: pull-to-refresh Home or kill app to force syncMatchesNow, then open MatchProfile -> "Where you matched" should show 2 maps.
