-- Give native polling clients the per-conversation unread count.
--
-- unread_messages_count counts everything received in the last two minutes and
-- the p_message_id branch hardcodes 1, so neither can be shown as "N unread"
-- for one chat. Android's notification check runs when a push never landed
-- (force-stop, offline at delivery) and has to draw the card itself; without a
-- real per-chat count that card can only repeat a canned "New message", which
-- is the copy the tray is moving away from.
--
-- Output columns only: the argument list is unchanged, so the function
-- identity stays check_unread_notifications(UUID, UUID) and no overload is
-- introduced.
--
-- CREATE OR REPLACE cannot be used here: Postgres refuses to change the row
-- type defined by a function's OUT parameters ("cannot change return type of
-- existing function"), so the new column needs a real DROP first. A drop also
-- discards the grants from 20262130000000, which is why they are re-applied
-- below - without them the RPC silently disappears for authenticated clients.
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
    translation_available BOOLEAN,
    latest_chat_unread_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_unread_matches INTEGER := 0;
    v_unread_messages INTEGER := 0;
    v_chat_unread INTEGER := 0;
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
            -- Whole backlog of this chat, not just the last two minutes: the
            -- card quotes how much is waiting to be read here.
            SELECT COUNT(*)::INTEGER INTO v_chat_unread
            FROM chat_messages cm
            WHERE cm.match_id = v_latest_match_id
              AND cm.sender_id != p_user_id
              AND cm.read_at IS NULL;

            RETURN QUERY SELECT 0, 1, NULL::TEXT, v_latest_message_sender,
                'Sent a message'::TEXT, v_latest_message_id, v_latest_match_id,
                v_latest_sender_id, v_translation_enabled,
                v_translation_language, false, GREATEST(v_chat_unread, 1);
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

        SELECT COUNT(*)::INTEGER INTO v_chat_unread
        FROM chat_messages cm
        WHERE cm.match_id = v_latest_match_id
          AND cm.sender_id != p_user_id
          AND cm.read_at IS NULL;
    END IF;

    RETURN QUERY SELECT COALESCE(v_unread_matches, 0),
        COALESCE(v_unread_messages, 0), v_latest_match_name,
        v_latest_message_sender,
        CASE WHEN v_unread_messages > 0 THEN 'Sent a message'::TEXT ELSE NULL::TEXT END,
        v_latest_message_id, v_latest_match_id, v_latest_sender_id,
        v_translation_enabled, v_translation_language, false,
        GREATEST(v_chat_unread, 1);
END;
$$;

-- Re-apply the grants the DROP removed (same set as 20262130000000).
REVOKE ALL ON FUNCTION check_unread_notifications(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION check_unread_notifications(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION check_unread_notifications(UUID, UUID) TO service_role;

-- PostgREST caches the function's return shape; without this the new column
-- stays invisible to REST callers until the schema cache is reloaded.
NOTIFY pgrst, 'reload schema';

COMMIT;
