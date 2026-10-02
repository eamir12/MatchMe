-- Script to reverse the current rematch (1d7074ac-868d-45ea-a452-40b59fe49528)
-- so you can test rematching again between dd6d20a5 (Android) and ffc20046 (Chrome)
-- Run this in Supabase SQL Editor (service_role / postgres).
--
-- Current state (buggy before 20261007000000):
--   matches 1d7074ac occurrence=1 (should be 2), created 2026-09-02 17:41
--   unmatched_pairs dd6d20a5|ffc20046 expiry_count=0 (should be 1), created 2026-09-02 17:24
-- After 20261007000000 the migration auto-fixes to expiry_count=1, occurrence=2.
-- This script REVERSES the rematch regardless of which state you are in.

BEGIN;

-- 1) Delete the rematch itself (and all dependent rows)
DELETE FROM public.chats WHERE match_id = '1d7074ac-868d-45ea-a452-40b59fe49528';
DELETE FROM public.chat_messages WHERE match_id = '1d7074ac-868d-45ea-a452-40b59fe49528';
-- Keep for backwards compat if legacy tables still exist
DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='user_recent_chats') THEN EXECUTE 'DELETE FROM public.user_recent_chats WHERE match_id = ''1d7074ac-868d-45ea-a452-40b59fe49528'''; END IF; END $$;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='match_chat_extensions') THEN EXECUTE 'DELETE FROM public.match_chat_extensions WHERE match_id = ''1d7074ac-868d-45ea-a452-40b59fe49528'''; END IF; END $$;
DELETE FROM public.matches WHERE id = '1d7074ac-868d-45ea-a452-40b59fe49528';

-- 2) Clear server-side expiry warning dedup so you get fresh 60m/15m/5m/1m pushes
DELETE FROM public.match_expiry_warnings WHERE match_id = '1d7074ac-868d-45ea-a452-40b59fe49528';

-- 3) unmatched_pairs handling — CHOOSE ONE:
-- Option A (default, RECOMMENDED for testing rematch AGAIN):
--   Keep the history row so next proximity creates occurrence=2 (rematch banner).
--   Do nothing — leave expiry_count as is (1 after fix, 0 before fix).
--   The row stays: (dd6d20a5, ffc20046, expiry_count=1, is_permanent=false)

-- Option B — Fully reset pair to test original match from scratch (occurrence=1):
--   Uncomment the block below to delete the history. Next match will be occurrence=1 (no banner).
-- DELETE FROM public.unmatched_pairs WHERE user1_id = 'dd6d20a5-cd79-4761-8a74-751acb555b4d' AND user2_id = 'ffc20046-a777-463b-922a-547151aa1455';

-- Option C — Keep row but reset count to 0 (also makes next match occurrence=1):
-- UPDATE public.unmatched_pairs SET expiry_count = 0, is_permanent = false, created_at = now() WHERE user1_id = 'dd6d20a5-cd79-4761-8a74-751acb555b4d' AND user2_id = 'ffc20046-a777-463b-922a-547151aa1455';

COMMIT;

-- 4) Verification — should return 0 rows for the deleted match, and show current counter
SELECT 'matches row should be 0' as check, count(*) FROM public.matches WHERE id = '1d7074ac-868d-45ea-a452-40b59fe49528';
SELECT 'unmatched_pairs after reverse' as check, * FROM public.unmatched_pairs WHERE user1_id = 'dd6d20a5-cd79-4761-8a74-751acb555b4d' AND user2_id = 'ffc20046-a777-463b-922a-547151aa1455';
SELECT 'remaining matches for pair (should be 0-1)' as check, * FROM public.matches WHERE (user1_id='dd6d20a5-cd79-4761-8a74-751acb555b4d' AND user2_id='ffc20046-a777-463b-922a-547151aa1455') OR (user1_id='ffc20046-a777-463b-922a-547151aa1455' AND user2_id='dd6d20a5-cd79-4761-8a74-751acb555b4d');

-- 5) To immediately re-trigger a proximity rematch after this reverse:
--    Ensure both users are visible and have a recent location (updated_at >= now()-5m):
--    On each device, toggle visibility off/on or move slightly, then wait for next
--    perform_continuous_user_matching cron tick (1m) or call:
--    SELECT public.perform_continuous_user_matching();
--    For event rematches: SELECT public.perform_event_matching('your_event_id');
--    Check max rematches config: SELECT config_value FROM public.app_config WHERE config_key='matches.max_match_occurrence'; -- default 3 (2 rematches)
