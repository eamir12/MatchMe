-- Test script: message reactions and recompute_reaction_summary
-- Run this against a test/staging database only.

BEGIN;

-- Ensure test message exists
INSERT INTO public.chat_messages (id, match_id, sender_id, content_original, created_at)
VALUES
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333', 'Test message for reactions', now())
ON CONFLICT (id) DO UPDATE SET content_original = EXCLUDED.content_original;

-- Clean up any previous test reactions
DELETE FROM public.message_reactions WHERE message_id = '11111111-1111-1111-1111-111111111111';

-- Insert reactions
INSERT INTO public.message_reactions (message_id, user_id, reaction, created_at) VALUES
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','❤️', now()),
  ('11111111-1111-1111-1111-111111111111','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','❤️', now()),
  ('11111111-1111-1111-1111-111111111111','cccccccc-cccc-cccc-cccc-cccccccccccc','👍', now());

-- Force recompute
SELECT public.recompute_reaction_summary('11111111-1111-1111-1111-111111111111') AS summary;

-- Check stored summary
SELECT reaction_summary FROM public.chat_messages WHERE id = '11111111-1111-1111-1111-111111111111';

-- Change a reaction (simulate user toggling)
UPDATE public.message_reactions SET reaction = '😂' WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' AND message_id = '11111111-1111-1111-1111-111111111111';

-- Recompute and inspect
SELECT public.recompute_reaction_summary('11111111-1111-1111-1111-111111111111') AS updated_summary;
SELECT reaction_summary FROM public.chat_messages WHERE id = '11111111-1111-1111-1111-111111111111';

-- Cleanup (optional)
-- DELETE FROM public.message_reactions WHERE message_id = '11111111-1111-1111-1111-111111111111';
-- DELETE FROM public.chat_messages WHERE id = '11111111-1111-1111-1111-111111111111';

COMMIT;