-- Diagnostic: stuck hourglass + uniform read_at investigation
-- Match: ba77197e-1535-4630-9176-2cb508ae1984
-- Sender (Windows):    35fe114e-eae5-49d6-9eba-8459617e7b82
-- Recipient (Android): ffc20046-a777-463b-922a-547151aa1455
-- Also checks match:   87c36b11-8210-4669-b22d-09d68b3aaa43
-- Other recipient:     1cb98f47-f6af-4665-9348-d6a8575f4ac3
-- Test message:        8a63170c-9559-404c-8ddd-a9f0bfb88744 (sent 2026-10-17 13:22:51Z)

-- ============================================================================
-- QUERY A: Which version of mark_messages_as_read is DEPLOYED to production?
--   If the definition does NOT contain "read_at IS NULL" then every chat open
--   rewrites read_at for the entire conversation (hypothesis A).
-- ============================================================================
SELECT
  p.oid::regprocedure          AS signature,
  p.prosecdef                  AS security_definer,
  pg_get_functiondef(p.oid)    AS definition
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'mark_messages_as_read';

-- ============================================================================
-- QUERY B: Realtime config — REPLICA IDENTITY must be 'f' (FULL) for
--   UPDATE payloads to carry all columns, and the table must be published.
-- ============================================================================
SELECT c.relname, c.relreplident,
       (c.relreplident = 'f') AS replica_identity_full
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname = 'chat_messages';

SELECT pubname, schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime' AND tablename = 'chat_messages';

-- ============================================================================
-- QUERY C: Was the recipient actually IN the chat on earlier days?
--   Reactions are recorded server-side with a timestamp. If the recipient
--   reacted in June/Sept, they had the chat open then -> mark_messages_as_read
--   must have run then. Compare these dates with read_at below:
--     - If reactions exist on earlier days but read_at = today only
--       -> hypothesis A (read_at was overwritten by a guard-less RPC).
-- ============================================================================
SELECT mr.message_id, mr.user_id, mr.reaction, mr.created_at,
       cm.match_id, cm.sender_id, cm.created_at AS message_created_at,
       cm.read_at
FROM public.message_reactions mr
JOIN public.chat_messages cm ON cm.id = mr.message_id
WHERE cm.match_id IN (
        'ba77197e-1535-4630-9176-2cb508ae1984',
        '87c36b11-8210-4669-b22d-09d68b3aaa43'
      )
ORDER BY mr.created_at;

-- ============================================================================
-- QUERY D: Read receipts per match for THIS recipient (bulk-stamp pattern?)
--   distinct_read_seconds ~ 1  => entire conversation stamped in one call
--   first_read_at vs last_read_at shows spread over time (or not).
-- ============================================================================
SELECT
  cm.match_id,
  count(*)                                          AS received_msgs,
  count(cm.read_at)                                 AS with_read_at,
  count(*) FILTER (WHERE cm.read_at IS NULL)        AS still_unread,
  min(cm.read_at)                                   AS first_read_at,
  max(cm.read_at)                                   AS last_read_at,
  count(DISTINCT date_trunc('second', cm.read_at))  AS distinct_read_seconds
FROM public.chat_messages cm
WHERE cm.recipient_id = 'ffc20046-a777-463b-922a-547151aa1455'
GROUP BY cm.match_id
ORDER BY last_read_at DESC NULLS LAST;

-- ============================================================================
-- QUERY E: Control group — messages the Windows user RECEIVED in these two
--   matches. These read_at values are set by a different client/user and show
--   what "normal" per-chat-open read stamping looks like.
-- ============================================================================
SELECT id, match_id, sender_id, created_at, delivered_at, read_at
FROM public.chat_messages
WHERE match_id IN (
        'ba77197e-1535-4630-9176-2cb508ae1984',
        '87c36b11-8210-4669-b22d-09d68b3aaa43'
      )
  AND sender_id <> '35fe114e-eae5-49d6-9eba-8459617e7b82'
ORDER BY created_at;

-- ============================================================================
-- QUERY F: chats table state (unread_count, last activity) for both matches.
-- ============================================================================
SELECT c.user_id, c.match_id, c.unread_count, c.last_message_at, c.updated_at
FROM public.chats c
WHERE c.match_id IN (
        'ba77197e-1535-4630-9176-2cb508ae1984',
        '87c36b11-8210-4669-b22d-09d68b3aaa43'
      )
ORDER BY c.match_id, c.user_id;

-- ============================================================================
-- QUERY G: Recipient's auth activity (was the device online/active today
--   around 13:23 UTC? Was the account even used between June and today?)
-- ============================================================================
SELECT id, email, last_sign_in_at, created_at, updated_at
FROM auth.users
WHERE id = 'ffc20046-a777-463b-922a-547151aa1455';

-- ============================================================================
-- QUERY H: Everything the recipient had stamped as read in the last 30 days,
--   across ALL their chats — shows whether today's 13:23:10 burst is unique
--   to our match or a global pattern.
-- ============================================================================
SELECT id, match_id, sender_id, created_at, read_at
FROM public.chat_messages
WHERE recipient_id = 'ffc20046-a777-463b-922a-547151aa1455'
  AND read_at >= now() - interval '30 days'
ORDER BY read_at DESC
LIMIT 300;
