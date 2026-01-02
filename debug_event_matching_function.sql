-- Debug version of perform_event_matching with detailed logging
-- This will help identify why matches aren't being created

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

        -- Get first user's interests
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

        RETURN QUERY SELECT 'USER A data', jsonb_build_object(
            'user_id', v_user1_id,
            'active_modes', user_a_data.active_modes,
            'event_matching_enabled', user_a_data.shared_event_matching_enabled,
            'interests', user_a_interests
        );

        -- Compare with other attendees
        FOR other_attendee IN
            SELECT DISTINCT ea2.user_id
            FROM event_attendees ea2
            WHERE ea2.event_id = p_event_id
            AND ea2.user_id != v_user1_id
        LOOP
            v_user2_id := other_attendee.user_id;

            -- Skip if users are in wrong order
            IF v_user1_id >= v_user2_id THEN
                CONTINUE;
            END IF;

            -- Check if match already exists
            SELECT COUNT(*) INTO existing_match_count
            FROM matches m
            WHERE m.user1_id = v_user1_id AND m.user2_id = v_user2_id;

            IF existing_match_count > 0 THEN
                RETURN QUERY SELECT 'SKIP: Match already exists', jsonb_build_object('user_a', v_user1_id, 'user_b', v_user2_id);
                CONTINUE;
            END IF;

            -- Get second user's data
            SELECT active_modes, shared_event_matching_enabled
            INTO user_b_data
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
                RETURN QUERY SELECT 'SKIP: No shared intents', jsonb_build_object(
                    'user_a_intents', user_a_data.active_modes,
                    'user_b_intents', user_b_data.active_modes
                );
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
                WHERE user_id = user2_id
                AND profile_data ? 'interests'
            ) interests_data;

            RETURN QUERY SELECT 'USER B data', jsonb_build_object(
                'user_id', user2_id,
                'active_modes', user_b_data.active_modes,
                'event_matching_enabled', user_b_data.shared_event_matching_enabled,
                'interests', user_b_interests
            );

            -- Check for shared interests
            has_shared_interest := FALSE;
            FOR shared_interest_category IN
                SELECT jsonb_object_keys(user_a_interests)
            LOOP
                IF user_a_interests ? shared_interest_category AND user_b_interests ? shared_interest_category THEN
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_array_elements_text(user_a_interests->shared_interest_category) AS user_a_interest
                        WHERE user_a_interest = ANY(
                            SELECT jsonb_array_elements_text(user_b_interests->shared_interest_category)
                        )
                    ) THEN
                        has_shared_interest := TRUE;
                        RETURN QUERY SELECT 'SHARED INTEREST FOUND', jsonb_build_object(
                            'category', shared_interest_category,
                            'user_a_interests', user_a_interests->shared_interest_category,
                            'user_b_interests', user_b_interests->shared_interest_category
                        );
                        EXIT;
                    END IF;
                END IF;
            END LOOP;

            IF NOT has_shared_interest THEN
                RETURN QUERY SELECT 'SKIP: No shared interests', jsonb_build_object(
                    'user_a_interests', user_a_interests,
                    'user_b_interests', user_b_interests
                );
                CONTINUE;
            END IF;

            -- Create match!
            INSERT INTO matches (user1_id, user2_id, match_type, matched_intent, event_id, created_at)
            VALUES (
                user1_id,
                user2_id,
                'event',
                shared_intents[1],
                p_event_id,
                NOW()
            );

            RETURN QUERY SELECT 'MATCH CREATED!', jsonb_build_object(
                'user_a', user1_id,
                'user_b', user2_id,
                'matched_intent', shared_intents[1],
                'event_id', p_event_id
            );
        END LOOP;
    END LOOP;

    RETURN QUERY SELECT 'END: Function completed', jsonb_build_object('event_id', p_event_id);
END;
$$;

-- Test the debug function
SELECT * FROM perform_event_matching_debug('6497a84c-6ae6-445b-b3e1-e7acc984b2c5');