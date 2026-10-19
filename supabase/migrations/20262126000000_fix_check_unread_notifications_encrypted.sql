-- Migration: rewrite check_unread_notifications for the encrypted chat schema.
--
-- Problem:
--   Every published version of this function (through
--   20262125000000_check_unread_notifications_latest_unread.sql) selects the
--   legacy plaintext columns chat_messages.content_original /
--   chat_messages.content_translated. Those columns were removed when chat
--   encryption shipped (20260523000000_chat_encryption_schema.sql). plpgsql
--   resolves column names at first execution, so CREATE FUNCTION succeeded
--   but every call failed at runtime with 42703 ("column cm.content_translated
--   does not exist") and returned 400 to:
--     - Android MatchMeBackgroundService / LocationWorker notification polls,
--     - the Deno push-message badge-count fallback.
--
-- Fix:
--   Message bodies are end-to-end encrypted; the server cannot decrypt them
--   for this RPC, so the function returns metadata only.
--
--   - latest_message_content: fixed generic placeholder ("Sent a message").
--     A literal string (not NULL) is deliberate: older clients passed
--     `optString("latest_message_content", "Sent a message")`, whose fallback
--     only applies when the field is MISSING — a JSON null renders as the
--     literal text "null". The placeholder keeps every client generation
--     showing a sane body.
--   - translation_enabled / translation_available: NULL. With no readable
--     body there is no translation state to report, and NULL reads as false
--     in every client (org.json optBoolean / Dart), which stops the legacy
--     "translation pending" skip (translationEnabled && !translationAvailable)
--     from suppressing notifications entirely. The real translated push text
--     is still delivered by the translate-proxy push pipeline.
--
--   Everything else is unchanged: signature (clients call with one or two
--   arguments), the auth identity guard, the specific-message branch, and
--   the 24h / 2min polling windows.

BEGIN;

-- Defensive: a stale single-argument overload would make one-arg calls
-- ambiguous with the two-arg version whose second parameter has a default.
DROP FUNCTION IF EXISTS check_unread_notifications(UUID);
DROP FUNCTION IF EXISTS check_unread_notifications(UUID, UUID);

CREATE FUNCTION check_unread_notifications(p_user_id UUID, p_message_id UUID DEFAULT NULL)
RETURNS TABLE (
    unread_matches_count INTEGER,
    unread_messages_count INTEGER,
    latest_match_name TEXT,
    latest_message_sender TEXT,
    latest_message_content TEXT,
    latest_message_id UUID,
    latest_match_id UUID,
    latest_message_sender_id UUID,
    translation_enabled BOOLEAN,
    translation_language TEXT,
    translation_available BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_unread_matches INTEGER := 0;
    v_unread_messages INTEGER := 0;
    v_latest_match_name TEXT;
    v_latest_message_sender TEXT;
    v_latest_message_id UUID;
    v_latest_match_id UUID;
    v_latest_sender_id UUID;
    v_translation_language TEXT;
BEGIN
    SET search_path = 'public';

    -- Identity guard: callers may only read their own notifications.
    IF p_user_id IS NULL THEN
        RETURN;
    END IF;

    IF p_user_id IS DISTINCT FROM auth.uid()
       AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    -- If a specific message ID is provided (from FCM/Realtime), answer for
    -- its chat: the newest unread message RECEIVED by this user. Delayed or
    -- out-of-order deliveries therefore converge on what the tray should
    -- actually show, and already-read messages yield nothing.
    IF p_message_id IS NOT NULL THEN
        SELECT
            public.mask_full_name(u.name),
            cm.id,
            cm.match_id,
            cm.sender_id,
            c.translation_language
        INTO v_latest_message_sender, v_latest_message_id, v_latest_match_id, v_latest_sender_id, v_translation_language
        FROM chat_messages cm
        JOIN matches m ON m.id = cm.match_id
                      AND (m.user1_id = p_user_id OR m.user2_id = p_user_id)
        LEFT JOIN users u ON u.id = cm.sender_id
        LEFT JOIN chats c ON c.match_id = cm.match_id AND c.user_id = p_user_id
        WHERE cm.match_id = (SELECT match_id FROM chat_messages WHERE id = p_message_id)
          AND cm.sender_id != p_user_id
          AND cm.read_at IS NULL
        ORDER BY cm.created_at DESC
        LIMIT 1;

        IF FOUND THEN
            v_unread_messages := 1;
            RETURN QUERY SELECT
                0,
                1,
                NULL::TEXT,
                v_latest_message_sender,
                'Sent a message'::TEXT,
                v_latest_message_id,
                v_latest_match_id,
                v_latest_sender_id,
                NULL::BOOLEAN,
                v_translation_language,
                NULL::BOOLEAN;
        END IF;

        -- Nothing unread in that chat: the delivery was stale/out-of-order.
        -- Return empty instead of falling back to unrelated polling data.
        RETURN;
    END IF;

    -- Fallback to polling logic (check recent unread)

    -- 1. Count unread matches (last 24 hours: catch-up for matches created
    -- while the device was offline, killed, or unreachable; per-match dedup
    -- on the clients prevents repeat buzzes)
    SELECT COUNT(*)::INTEGER
    INTO v_unread_matches
    FROM matches m
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      AND m.created_at > (NOW() - INTERVAL '24 hours');

    -- Get the name of the most recent match
    IF v_unread_matches > 0 THEN
        SELECT
            public.mask_full_name(u.name),
            m.id
        INTO v_latest_match_name, v_latest_match_id
        FROM matches m
        LEFT JOIN public.users u ON u.id = CASE
            WHEN m.user1_id = p_user_id THEN m.user2_id
            ELSE m.user1_id
        END
        WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
          AND m.created_at > (NOW() - INTERVAL '24 hours')
        ORDER BY m.created_at DESC
        LIMIT 1;
    END IF;

    -- 2. Count unread messages (received in last 2 minutes and unread)
    SELECT COUNT(*)::INTEGER
    INTO v_unread_messages
    FROM chat_messages cm
    JOIN matches m ON cm.match_id = m.id
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      AND cm.sender_id != p_user_id
      AND cm.read_at IS NULL
      AND cm.created_at > (NOW() - INTERVAL '2 minutes');

    -- Get latest message metadata (content stays a placeholder: encrypted)
    IF v_unread_messages > 0 THEN
        SELECT
            public.mask_full_name(u.name),
            cm.id,
            cm.match_id,
            cm.sender_id,
            c.translation_language
        INTO v_latest_message_sender, v_latest_message_id, v_latest_match_id, v_latest_sender_id, v_translation_language
        FROM chat_messages cm
        JOIN matches m ON cm.match_id = m.id
        LEFT JOIN users u ON u.id = cm.sender_id
        LEFT JOIN chats c ON c.match_id = cm.match_id AND c.user_id = p_user_id
        WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
          AND cm.sender_id != p_user_id
          AND cm.read_at IS NULL
          AND cm.created_at > (NOW() - INTERVAL '2 minutes')
        ORDER BY cm.created_at DESC
        LIMIT 1;
    END IF;

    RETURN QUERY SELECT
        COALESCE(v_unread_matches, 0),
        COALESCE(v_unread_messages, 0),
        v_latest_match_name,
        v_latest_message_sender,
        CASE WHEN v_unread_messages > 0 THEN 'Sent a message'::TEXT ELSE NULL::TEXT END,
        v_latest_message_id,
        v_latest_match_id,
        v_latest_sender_id,
        NULL::BOOLEAN,
        v_translation_language,
        NULL::BOOLEAN;
END;
$$;

REVOKE ALL ON FUNCTION check_unread_notifications(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION check_unread_notifications(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION check_unread_notifications(UUID, UUID) TO service_role;

COMMIT;
