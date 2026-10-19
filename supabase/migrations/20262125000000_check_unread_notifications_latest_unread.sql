-- Migration: make the specific-message branch of check_unread_notifications
-- return the LATEST UNREAD message of that message's chat.
--
-- Problem:
--   The specific branch (p_message_id, triggered by the Android service on
--   an FCM/Realtime message id) returned exactly the message it was handed,
--   regardless of its read state or of newer messages in the same chat:
--     1. A delayed / out-of-order FCM delivery for an older message re-posted
--        that older message as the tray notification even when a newer
--        unread message (or nothing unread) existed.
--     2. A push that arrived after the user had already read the message on
--        another device still (re)posted a card for the read message.
--   The native service then could not rely on the RPC to answer the only
--   question that matters: "what is the newest unread message in this chat?"
--
-- Fix:
--   For p_message_id: resolve its chat, then return the newest received
--   unread message of that chat (scoped to the caller's own matches).
--   When there is no unread message left, RETURN an empty set — the caller
--   treats it as "nothing to notify" and must NOT fall back to the polling
--   branch (a stale delivery must never re-alert for unrelated unread data).
--
--   The polling branch (p_message_id IS NULL) is unchanged.
--
-- Grants are preserved by CREATE OR REPLACE (same signature); the explicit
-- REVOKE/GRANT block is repeated for idempotence/documentation only.

BEGIN;

CREATE OR REPLACE FUNCTION check_unread_notifications(p_user_id UUID, p_message_id UUID DEFAULT NULL)
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
    v_latest_message_content TEXT;
    v_latest_message_id UUID;
    v_latest_match_id UUID;
    v_latest_sender_id UUID;
    v_translation_enabled BOOLEAN;
    v_translation_language TEXT;
    v_translation_available BOOLEAN;
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
            CASE
                WHEN cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null' THEN cm.content_translated
                ELSE cm.content_original
            END,
            cm.id,
            cm.match_id,
            cm.sender_id,
            COALESCE(c.translation_enabled, false),
            c.translation_language,
            (cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null')
        INTO v_latest_message_sender, v_latest_message_content, v_latest_message_id, v_latest_match_id, v_latest_sender_id, v_translation_enabled, v_translation_language, v_translation_available
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
                v_latest_message_content,
                v_latest_message_id,
                v_latest_match_id,
                v_latest_sender_id,
                v_translation_enabled,
                v_translation_language,
                v_translation_available;
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

    -- Get latest message details with translation info
    IF v_unread_messages > 0 THEN
        SELECT
            public.mask_full_name(u.name),
            CASE
                WHEN cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null' THEN cm.content_translated
                ELSE cm.content_original
            END,
            cm.id,
            cm.match_id,
            cm.sender_id,
            COALESCE(c.translation_enabled, false),
            c.translation_language,
            (cm.content_translated IS NOT NULL AND cm.content_translated != '' AND cm.content_translated != 'null')
        INTO v_latest_message_sender, v_latest_message_content, v_latest_message_id, v_latest_match_id, v_latest_sender_id, v_translation_enabled, v_translation_language, v_translation_available
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
        v_latest_message_content,
        v_latest_message_id,
        v_latest_match_id,
        v_latest_sender_id,
        v_translation_enabled,
        v_translation_language,
        v_translation_available;
END;
$$;

REVOKE ALL ON FUNCTION check_unread_notifications(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION check_unread_notifications(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION check_unread_notifications(UUID, UUID) TO service_role;

COMMIT;
