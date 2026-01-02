-- Comprehensive fix for function search path mutable issues
-- This migration ensures all affected functions have SET search_path = 'public'

-- Fix trigger_set_timestamp function
CREATE OR REPLACE FUNCTION trigger_set_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- Fix trigger_perform_event_matching function
CREATE OR REPLACE FUNCTION trigger_perform_event_matching()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    -- Only trigger on INSERT (when user joins event)
    IF TG_OP = 'INSERT' THEN
        -- Call the matching function for this event
        PERFORM perform_event_matching(NEW.event_id);
    END IF;
    RETURN NEW;
END;
$$;

-- Fix get_recent_chats function
CREATE OR REPLACE FUNCTION get_recent_chats(p_user_id UUID)
RETURNS TABLE (
    match_id UUID,
    other_user_id UUID,
    other_user_name TEXT,
    last_message_content TEXT,
    last_message_id UUID,
    last_message_at TIMESTAMP WITH TIME ZONE,
    unread_count INTEGER,
    match_created_at TIMESTAMP WITH TIME ZONE,
    event_id UUID,
    event_name TEXT,
    event_link TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    RETURN QUERY
    SELECT DISTINCT
        m.id AS match_id,
        CASE
            WHEN m.user1_id = p_user_id THEN m.user2_id
            ELSE m.user1_id
        END AS other_user_id,
          -- Use central mask function
          public.mask_full_name(up.profile_data->>'fullName') AS other_user_name,
        cm.content_original AS last_message_content,
        cm.id AS last_message_id,
        cm.created_at AS last_message_at,
        -- Count messages from the other user (simplified unread count)
        (SELECT COUNT(*)::integer
         FROM chat_messages cm_unread
         WHERE cm_unread.match_id = m.id
         AND cm_unread.sender_id != p_user_id) AS unread_count,
        m.created_at AS match_created_at,
        m.event_id,
        e.event_name,
        e.event_link
    FROM matches m
    -- Join with user_profiles to get the other user's name
    LEFT JOIN user_profiles up ON up.user_id = CASE
        WHEN m.user1_id = p_user_id THEN m.user2_id
        ELSE m.user1_id
    END
    -- Join with events to get event details
    LEFT JOIN events e ON e.id = m.event_id
    -- Join with chat_messages to get the last message
    INNER JOIN chat_messages cm ON cm.match_id = m.id
    -- Ensure we only include matches that have messages
    WHERE (m.user1_id = p_user_id OR m.user2_id = p_user_id)
    -- Get only the most recent message per match
    AND cm.id = (
        SELECT cm_sub.id
        FROM chat_messages cm_sub
        WHERE cm_sub.match_id = m.id
        ORDER BY cm_sub.created_at DESC
        LIMIT 1
    )
    ORDER BY cm.created_at DESC;

    RETURN;
END;
$$;

-- Fix mark_messages_as_read function
CREATE OR REPLACE FUNCTION mark_messages_as_read(p_match_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    UPDATE chat_messages
    SET read_at = NOW()
    WHERE match_id = p_match_id
    AND sender_id != auth.uid();
END;
$$;

-- Fix get_potential_event_matches function
CREATE OR REPLACE FUNCTION get_potential_event_matches(p_event_id UUID, p_user_id UUID)
RETURNS TABLE (
    suggested_user_id UUID,
    suggested_user_name TEXT,
    shared_intents TEXT[]
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    current_user_data RECORD;
    current_user_interests JSONB;
    other_attendee RECORD;
    other_user_data RECORD;
    other_user_interests JSONB;
    shared_intents_list TEXT[];
    has_shared_interest BOOLEAN := FALSE;
    shared_interest_category TEXT;
    existing_match_count INTEGER;
BEGIN
    SET search_path = 'public';
    -- Get current user's data (intents, visibility, and event matching setting)
    SELECT active_modes, user_visibility_setting, shared_event_matching_enabled
    INTO current_user_data
    FROM users
    WHERE id = p_user_id;

    -- Return empty if user not found or event matching not enabled
    IF current_user_data IS NULL OR NOT current_user_data.shared_event_matching_enabled THEN
        RETURN;
    END IF;

    -- Get current user's interests
    SELECT COALESCE(jsonb_object_agg(category, interests), '{}'::jsonb)
    INTO current_user_interests
    FROM (
        SELECT
            jsonb_object_keys(profile_data->'interests') as category,
            profile_data->'interests'->jsonb_object_keys(profile_data->'interests') as interests
        FROM user_profiles
        WHERE user_id = p_user_id
        AND profile_data ? 'interests'
    ) interests_data;

    -- Loop through other attendees
    FOR other_attendee IN
        SELECT DISTINCT ea.user_id, public.mask_full_name(up.profile_data->>'fullName') as user_name
        FROM event_attendees ea
        LEFT JOIN user_profiles up ON ea.user_id = up.user_id
        WHERE ea.event_id = p_event_id
        AND ea.user_id != p_user_id
    LOOP
        -- Get other user's data
        SELECT active_modes, user_visibility_setting, shared_event_matching_enabled
        INTO other_user_data
        FROM users
        WHERE id = other_attendee.user_id;

        -- Skip if user not found or event matching not enabled
        IF other_user_data IS NULL OR NOT other_user_data.shared_event_matching_enabled THEN
            CONTINUE;
        END IF;

        -- Check shared intents
        SELECT ARRAY(
            SELECT intent
            FROM unnest(current_user_data.active_modes) AS t(intent)
            WHERE intent = ANY(other_user_data.active_modes)
        ) INTO shared_intents_list;

        -- No shared intents = no match
        IF shared_intents_list IS NULL OR array_length(shared_intents_list, 1) IS NULL THEN
            CONTINUE;
        END IF;

        -- Get other user's interests
        SELECT COALESCE(jsonb_object_agg(category, interests), '{}'::jsonb)
        INTO other_user_interests
        FROM (
            SELECT
                jsonb_object_keys(profile_data->'interests') as category,
                profile_data->'interests'->jsonb_object_keys(profile_data->'interests') as interests
            FROM user_profiles
            WHERE user_id = other_attendee.user_id
            AND profile_data ? 'interests'
        ) interests_data;

        -- Check for shared interests
        has_shared_interest := FALSE;
        shared_interest_category := NULL;

        FOR shared_interest_category IN
            SELECT jsonb_object_keys(current_user_interests)
        LOOP
            -- Check if both users have this category
            IF current_user_interests ? shared_interest_category AND other_user_interests ? shared_interest_category THEN
                -- Check if they have any overlapping interests in this category
                IF EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements_text(current_user_interests->shared_interest_category) AS user_a_interest
                    WHERE user_a_interest = ANY(
                        SELECT jsonb_array_elements_text(other_user_interests->shared_interest_category)
                    )
                ) THEN
                    has_shared_interest := TRUE;
                    EXIT;
                END IF;
            END IF;
        END LOOP;

        -- No shared interests = no match
        IF NOT has_shared_interest THEN
            CONTINUE;
        END IF;

        -- Return the potential match
        RETURN QUERY SELECT other_attendee.user_id, other_attendee.user_name, shared_intents_list;
    END LOOP;

    RETURN;
END;
$$;

-- Fix perform_event_matching_debug function
CREATE OR REPLACE FUNCTION perform_event_matching_debug(p_event_id UUID)
RETURNS TABLE (
    debug_message TEXT,
    debug_data JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    event_attendee RECORD;
    other_attendee RECORD;
    v_user1_id UUID;
    v_user2_id UUID;
    user_a_data RECORD;
    user_b_data RECORD;
    user_a_interests JSONB;
    user_b_interests JSONB;
    shared_intents TEXT[];
    has_shared_interest BOOLEAN := FALSE;
    shared_interest_category TEXT;
    existing_match_count INTEGER;
BEGIN
    SET search_path = 'public';
    -- Log start
    RETURN QUERY SELECT 'START: Checking event ' || p_event_id::TEXT, jsonb_build_object('event_id', p_event_id);

    -- Get all attendees for this event
    FOR event_attendee IN
        SELECT DISTINCT ea.user_id
        FROM event_attendees ea
        WHERE ea.event_id = p_event_id
    LOOP
        v_user1_id := event_attendee.user_id;

        -- Get user A data
        SELECT * INTO user_a_data
        FROM users
        WHERE id = v_user1_id;

        IF user_a_data IS NULL THEN
            RETURN QUERY SELECT 'SKIP: User A not found', jsonb_build_object('user_id', v_user1_id);
            CONTINUE;
        END IF;

        IF NOT user_a_data.shared_event_matching_enabled THEN
            RETURN QUERY SELECT 'SKIP: User A has event matching disabled', jsonb_build_object('user_id', v_user1_id, 'enabled', user_a_data.shared_event_matching_enabled);
            CONTINUE;
        END IF;

        -- Get user A interests
        SELECT COALESCE(jsonb_object_agg(category, interests), '{}'::jsonb)
        INTO user_a_interests
        FROM (
            SELECT
                jsonb_object_keys(profile_data->'interests') as category,
                profile_data->'interests'->jsonb_object_keys(profile_data->'interests') as interests
            FROM user_profiles
            WHERE user_id = v_user1_id
            AND profile_data ? 'interests'
        ) interests_data;

        -- Compare with other attendees
        FOR other_attendee IN
            SELECT DISTINCT ea2.user_id
            FROM event_attendees ea2
            WHERE ea2.event_id = p_event_id
            AND ea2.user_id != v_user1_id
        LOOP
            v_user2_id := other_attendee.user_id;

            -- Skip if users are in wrong order (always match A < B)
            IF v_user1_id >= v_user2_id THEN
                CONTINUE;
            END IF;

            -- Check if match already exists
            SELECT COUNT(*) INTO existing_match_count
            FROM matches m
            WHERE (m.user1_id = v_user1_id AND m.user2_id = v_user2_id)
               OR (m.user1_id = v_user2_id AND m.user2_id = v_user1_id);

            IF existing_match_count > 0 THEN
                RETURN QUERY SELECT 'SKIP: Match already exists', jsonb_build_object('user1', v_user1_id, 'user2', v_user2_id);
                CONTINUE;
            END IF;

            -- Get user B data
            SELECT * INTO user_b_data
            FROM users
            WHERE id = v_user2_id;

            IF user_b_data IS NULL THEN
                RETURN QUERY SELECT 'SKIP: User B not found', jsonb_build_object('user_id', v_user2_id);
                CONTINUE;
            END IF;

            IF NOT user_b_data.shared_event_matching_enabled THEN
                RETURN QUERY SELECT 'SKIP: User B has event matching disabled', jsonb_build_object('user_id', v_user2_id, 'enabled', user_b_data.shared_event_matching_enabled);
                CONTINUE;
            END IF;

            -- Check shared intents
            SELECT ARRAY(
                SELECT intent
                FROM unnest(user_a_data.active_modes) AS t(intent)
                WHERE intent = ANY(user_b_data.active_modes)
            ) INTO shared_intents;

            IF shared_intents IS NULL OR array_length(shared_intents, 1) IS NULL THEN
                RETURN QUERY SELECT 'SKIP: No shared intents', jsonb_build_object('user1_intents', user_a_data.active_modes, 'user2_intents', user_b_data.active_modes);
                CONTINUE;
            END IF;

            -- Get user B interests
            SELECT COALESCE(jsonb_object_agg(category, interests), '{}'::jsonb)
            INTO user_b_interests
            FROM (
                SELECT
                    jsonb_object_keys(profile_data->'interests') as category,
                    profile_data->'interests'->jsonb_object_keys(profile_data->'interests') as interests
                FROM user_profiles
                WHERE user_id = v_user2_id
                AND profile_data ? 'interests'
            ) interests_data;

            -- Check for shared interests
            has_shared_interest := FALSE;
            shared_interest_category := NULL;

            FOR shared_interest_category IN
                SELECT jsonb_object_keys(user_a_interests)
            LOOP
                -- Check if both users have this category
                IF user_a_interests ? shared_interest_category AND user_b_interests ? shared_interest_category THEN
                    -- Check if they have any overlapping interests in this category
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_array_elements_text(user_a_interests->shared_interest_category) AS user_a_interest
                        WHERE user_a_interest = ANY(
                            SELECT jsonb_array_elements_text(user_b_interests->shared_interest_category)
                        )
                    ) THEN
                        has_shared_interest := TRUE;
                        EXIT;
                    END IF;
                END IF;
            END LOOP;

            IF NOT has_shared_interest THEN
                RETURN QUERY SELECT 'SKIP: No shared interests', jsonb_build_object('user1_interests', user_a_interests, 'user2_interests', user_b_interests);
                CONTINUE;
            END IF;

            -- Both shared intents AND shared interests found - create match!
            INSERT INTO matches (user1_id, user2_id, match_type, matched_intent, event_id, created_at)
            VALUES (
                v_user1_id,
                v_user2_id,
                'event',
                shared_intents[1], -- Use first shared intent
                p_event_id,
                NOW()
            );

            RETURN QUERY SELECT 'MATCH CREATED', jsonb_build_object('user1', v_user1_id, 'user2', v_user2_id, 'intent', shared_intents[1], 'event', p_event_id);
        END LOOP;
    END LOOP;

    RETURN QUERY SELECT 'END: Event matching complete', jsonb_build_object('event_id', p_event_id);
END;
$$;

-- Fix perform_event_matching function (using the updated version)
CREATE OR REPLACE FUNCTION perform_event_matching(p_event_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    event_attendee RECORD;
    other_attendee RECORD;
    attendee_a_id UUID;
    attendee_b_id UUID;
    user_a_data RECORD;
    user_b_data RECORD;
    user_a_interests JSONB;
    user_b_interests JSONB;
    shared_intents TEXT[];
    has_shared_interest BOOLEAN := FALSE;
    shared_interest_category TEXT;
    existing_match_id UUID;
BEGIN
    SET search_path = 'public';
    -- Get all attendees for this event
    FOR event_attendee IN
        SELECT DISTINCT ea.user_id
        FROM event_attendees ea
        WHERE ea.event_id = p_event_id
    LOOP
        attendee_a_id := event_attendee.user_id;

        -- Get first user's data (intents, visibility, and event matching setting)
        SELECT active_modes, user_visibility_setting, shared_event_matching_enabled
        INTO user_a_data
        FROM users
        WHERE id = attendee_a_id;

        -- Skip if user not found or event matching not enabled
        IF user_a_data IS NULL OR NOT user_a_data.shared_event_matching_enabled THEN
            CONTINUE;
        END IF;

        -- Get first user's interests
        SELECT COALESCE(jsonb_object_agg(category, interests), '{}'::jsonb)
        INTO user_a_interests
        FROM (
            SELECT
                jsonb_object_keys(profile_data->'interests') as category,
                profile_data->'interests'->jsonb_object_keys(profile_data->'interests') as interests
            FROM user_profiles
            WHERE user_id = attendee_a_id
            AND profile_data ? 'interests'
        ) interests_data;

        -- Compare with other attendees
        FOR other_attendee IN
            SELECT DISTINCT ea2.user_id
            FROM event_attendees ea2
            WHERE ea2.event_id = p_event_id
            AND ea2.user_id != attendee_a_id
        LOOP
            attendee_b_id := other_attendee.user_id;

            -- Skip if users are in wrong order (always match A < B)
            IF attendee_a_id >= attendee_b_id THEN
                CONTINUE;
            END IF;

            -- Check if match already exists
            SELECT id INTO existing_match_id
            FROM matches
            WHERE (user1_id = attendee_a_id AND user2_id = attendee_b_id)
               OR (user1_id = attendee_b_id AND user2_id = attendee_a_id)
            LIMIT 1;

            IF existing_match_id IS NOT NULL THEN
                CONTINUE; -- Match already exists
            END IF;

            -- Get second user's data
            SELECT active_modes, user_visibility_setting, shared_event_matching_enabled
            INTO user_b_data
            FROM users
            WHERE id = attendee_b_id;

            -- Skip if user not found or event matching not enabled
            IF user_b_data IS NULL OR NOT user_b_data.shared_event_matching_enabled THEN
                CONTINUE;
            END IF;

            -- Check shared intents
            SELECT ARRAY(
                SELECT intent
                FROM unnest(user_a_data.active_modes) AS t(intent)
                WHERE intent = ANY(user_b_data.active_modes)
            ) INTO shared_intents;

            -- No shared intents = no match
            IF shared_intents IS NULL OR array_length(shared_intents, 1) IS NULL THEN
                CONTINUE;
            END IF;

            -- Get second user's interests
            SELECT COALESCE(jsonb_object_agg(category, interests), '{}'::jsonb)
            INTO user_b_interests
            FROM (
                SELECT
                    jsonb_object_keys(profile_data->'interests') as category,
                    profile_data->'interests'->jsonb_object_keys(profile_data->'interests') as interests
                FROM user_profiles
                WHERE user_id = attendee_b_id
                AND profile_data ? 'interests'
            ) interests_data;

            -- Check for shared interests
            has_shared_interest := FALSE;
            shared_interest_category := NULL;

            FOR shared_interest_category IN
                SELECT jsonb_object_keys(user_a_interests)
            LOOP
                -- Check if both users have this category
                IF user_a_interests ? shared_interest_category AND user_b_interests ? shared_interest_category THEN
                    -- Check if they have any overlapping interests in this category
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_array_elements_text(user_a_interests->shared_interest_category) AS user_a_interest
                        WHERE user_a_interest = ANY(
                            SELECT jsonb_array_elements_text(user_b_interests->shared_interest_category)
                        )
                    ) THEN
                        has_shared_interest := TRUE;
                        EXIT;
                    END IF;
                END IF;
            END LOOP;

            -- No shared interests = no match
            IF NOT has_shared_interest THEN
                CONTINUE;
            END IF;

            -- Both shared intents AND shared interests found - create match!
            INSERT INTO matches (user1_id, user2_id, match_type, matched_intent, event_id, created_at)
            VALUES (
                attendee_a_id,
                attendee_b_id,
                'event',
                shared_intents[1], -- Use first shared intent
                p_event_id,
                NOW()
            );
        END LOOP;
    END LOOP;
END;
$$;

-- Fix find_shared_events function
CREATE OR REPLACE FUNCTION find_shared_events(user1_id UUID, user2_id UUID)
RETURNS TABLE(event_id UUID, event_name TEXT, start_time TIMESTAMP WITH TIME ZONE)
LANGUAGE plpgsql
AS $$
BEGIN
    SET search_path = 'public';
    RETURN QUERY
    SELECT
        e.id,
        e.event_name,
        e.start_time
    FROM events e
    WHERE EXISTS (
        SELECT 1 FROM event_attendees ea1
        WHERE ea1.event_id = e.id AND ea1.user_id = user1_id
    )
    AND EXISTS (
        SELECT 1 FROM event_attendees ea2
        WHERE ea2.event_id = e.id AND ea2.user_id = user2_id
    )
    ORDER BY e.start_time DESC
    LIMIT 1; -- Return the most recent shared event
END;
$$;

-- Fix get_online_users_count function
CREATE OR REPLACE FUNCTION get_online_users_count(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    online_count INTEGER;
BEGIN
    SET search_path = 'public';

    -- Count users who are currently logged in (all users except current user)
    -- Exclude the current user from the count
    SELECT COUNT(*)
    INTO online_count
    FROM users u
    WHERE u.id != p_user_id;

    RETURN COALESCE(online_count, 0);
END;
$$;

-- Fix get_nearby_users_count function
CREATE OR REPLACE FUNCTION get_nearby_users_count(p_user_id UUID, p_radius_km INTEGER DEFAULT 50)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    nearby_count INTEGER;
    user_lat DOUBLE PRECISION;
    user_lon DOUBLE PRECISION;
BEGIN
    SET search_path = 'public';

    -- Get current user's location
    SELECT latitude, longitude
    INTO user_lat, user_lon
    FROM user_locations
    WHERE user_id = p_user_id
    ORDER BY updated_at DESC
    LIMIT 1;

    -- If user has no location, return 0
    IF user_lat IS NULL OR user_lon IS NULL THEN
        RETURN 0;
    END IF;

    -- Count users within the specified radius who are also visible
    -- This is a simplified distance calculation for performance
    SELECT COUNT(DISTINCT ul.user_id)
    INTO nearby_count
    FROM user_locations ul
    INNER JOIN users u ON ul.user_id = u.id
    WHERE ul.user_id != p_user_id
    AND public.is_user_truly_visible(u.id) = TRUE  -- Only count visible users
    -- Simple bounding box filter first (rough approximation)
    AND ul.latitude BETWEEN user_lat - (p_radius_km / 111.0) AND user_lat + (p_radius_km / 111.0)
    AND ul.longitude BETWEEN user_lon - (p_radius_km / (111.0 * COS(RADIANS(user_lat)))) AND user_lon + (p_radius_km / (111.0 * COS(RADIANS(user_lat))))
    -- More precise distance check would require PostGIS or complex math
    -- For now, we'll use this bounding box approximation
    AND ul.updated_at > NOW() - INTERVAL '24 hours'; -- Only consider recent locations

    RETURN COALESCE(nearby_count, 0);
END;
$$;

-- Fix count_event_attendees function
CREATE OR REPLACE FUNCTION count_event_attendees(event_id_param UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    attendee_count INTEGER;
BEGIN
    SET search_path = 'public';
    SELECT COUNT(*)
    INTO attendee_count
    FROM event_attendees
    WHERE event_id = event_id_param;
    RETURN COALESCE(attendee_count, 0);
END;
$$;

-- Grant permissions for all functions
GRANT EXECUTE ON FUNCTION trigger_set_timestamp() TO authenticated;
GRANT EXECUTE ON FUNCTION trigger_set_timestamp() TO anon;
GRANT EXECUTE ON FUNCTION trigger_perform_event_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION trigger_perform_event_matching() TO anon;
GRANT EXECUTE ON FUNCTION get_recent_chats(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_recent_chats(UUID) TO anon;
GRANT EXECUTE ON FUNCTION mark_messages_as_read(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION mark_messages_as_read(UUID) TO anon;
GRANT EXECUTE ON FUNCTION get_potential_event_matches(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_potential_event_matches(UUID, UUID) TO anon;
GRANT EXECUTE ON FUNCTION perform_event_matching_debug(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION perform_event_matching_debug(UUID) TO anon;
GRANT EXECUTE ON FUNCTION perform_event_matching(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION perform_event_matching(UUID) TO anon;
GRANT EXECUTE ON FUNCTION find_shared_events(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION find_shared_events(UUID, UUID) TO anon;
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_online_users_count(UUID) TO anon;
GRANT EXECUTE ON FUNCTION get_nearby_users_count(UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_nearby_users_count(UUID, INTEGER) TO anon;
GRANT EXECUTE ON FUNCTION count_event_attendees(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION count_event_attendees(UUID) TO anon;