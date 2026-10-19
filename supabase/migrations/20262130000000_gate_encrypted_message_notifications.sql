-- Expose the recipient's translation preference to native polling clients.
-- Those clients cannot decrypt message/translation content themselves; they
-- must therefore wait for translate-proxy instead of publishing the generic
-- encrypted-message placeholder while translation is pending.
BEGIN;

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
    v_translation_enabled BOOLEAN := false;
    v_translation_language TEXT;
BEGIN
    SET search_path = 'public';

    IF p_user_id IS NULL THEN RETURN; END IF;
    IF p_user_id IS DISTINCT FROM auth.uid()
       AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    IF p_message_id IS NOT NULL THEN
        SELECT public.mask_full_name(u.name), cm.id, cm.match_id, cm.sender_id,
               COALESCE(c.translation_enabled, false), c.translation_language
        INTO v_latest_message_sender, v_latest_message_id, v_latest_match_id,
             v_latest_sender_id, v_translation_enabled, v_translation_language
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
            RETURN QUERY SELECT 0, 1, NULL::TEXT, v_latest_message_sender,
                'Sent a message'::TEXT, v_latest_message_id, v_latest_match_id,
                v_latest_sender_id, v_translation_enabled,
                v_translation_language, false;
        END IF;
        RETURN;
    END IF;

    SELECT COUNT(*)::INTEGER INTO v_unread_matches
    FROM matches m
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      AND m.created_at > (NOW() - INTERVAL '24 hours');

    IF v_unread_matches > 0 THEN
        SELECT public.mask_full_name(u.name), m.id
        INTO v_latest_match_name, v_latest_match_id
        FROM matches m
        LEFT JOIN users u ON u.id = CASE
            WHEN m.user1_id = p_user_id THEN m.user2_id ELSE m.user1_id END
        WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
          AND m.created_at > (NOW() - INTERVAL '24 hours')
        ORDER BY m.created_at DESC LIMIT 1;
    END IF;

    SELECT COUNT(*)::INTEGER INTO v_unread_messages
    FROM chat_messages cm
    JOIN matches m ON cm.match_id = m.id
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
      AND cm.sender_id != p_user_id
      AND cm.read_at IS NULL
      AND cm.created_at > (NOW() - INTERVAL '2 minutes');

    IF v_unread_messages > 0 THEN
        SELECT public.mask_full_name(u.name), cm.id, cm.match_id, cm.sender_id,
               COALESCE(c.translation_enabled, false), c.translation_language
        INTO v_latest_message_sender, v_latest_message_id, v_latest_match_id,
             v_latest_sender_id, v_translation_enabled, v_translation_language
        FROM chat_messages cm
        JOIN matches m ON cm.match_id = m.id
        LEFT JOIN users u ON u.id = cm.sender_id
        LEFT JOIN chats c ON c.match_id = cm.match_id AND c.user_id = p_user_id
        WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
          AND cm.sender_id != p_user_id
          AND cm.read_at IS NULL
          AND cm.created_at > (NOW() - INTERVAL '2 minutes')
        ORDER BY cm.created_at DESC LIMIT 1;
    END IF;

    RETURN QUERY SELECT COALESCE(v_unread_matches, 0),
        COALESCE(v_unread_messages, 0), v_latest_match_name,
        v_latest_message_sender,
        CASE WHEN v_unread_messages > 0 THEN 'Sent a message'::TEXT ELSE NULL::TEXT END,
        v_latest_message_id, v_latest_match_id, v_latest_sender_id,
        v_translation_enabled, v_translation_language, false;
END;
$$;

REVOKE ALL ON FUNCTION check_unread_notifications(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION check_unread_notifications(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION check_unread_notifications(UUID, UUID) TO service_role;

COMMIT;
