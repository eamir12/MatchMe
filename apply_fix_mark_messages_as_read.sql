-- Fix: mark_messages_as_read — add the missing read_at IS NULL guard
--
-- Root cause confirmed in production (2026-10-17):
--   The deployed function is the ORIGINAL unguarded version (RETURNS void,
--   no "read_at IS NULL" guard). Every chat open rewrote read_at = NOW() for
--   ALL messages received from the other user, including already-read ones,
--   destroying first-read timestamps. That is why all 32 messages in match
--   ba77197e-1535-4630-9176-2cb508ae1984 share the exact same read_at
--   (2026-10-17 13:23:10.752457 = recipient's last chat open), even though
--   reactions prove they were read on 2026-09-29.
--
-- Why this version:
--   - Same signature and return type (void) => simple CREATE OR REPLACE,
--     no DROP, existing grants preserved, existing clients unaffected
--     (the app ignores the return value).
--   - Keeps the function-level SET search_path from the security advisor
--     remediation so no new advisor warnings appear.
--   - supabase/migrations/20260205000100 tried to fix this but (a) was never
--     applied to prod and (b) has a latent runtime bug: "WHERE user_id = user_id"
--     is ambiguous in plpgsql (variable vs column). This version avoids both.
--   - chats.unread_count is already maintained by the existing trigger
--     trg_handle_message_read_for_chats (fires on NULL -> NOT NULL read_at).
--
-- Run once in the Supabase SQL editor (Dashboard -> SQL Editor -> New query).

CREATE OR REPLACE FUNCTION public.mark_messages_as_read(p_match_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions'
AS $function$
BEGIN
    UPDATE chat_messages
    SET read_at = NOW()
    WHERE match_id = p_match_id
    AND sender_id != auth.uid()
    AND read_at IS NULL;
END;
$function$;

-- Verify afterwards (should show the guard in the body):
-- SELECT pg_get_functiondef('public.mark_messages_as_read(uuid)'::regprocedure);
