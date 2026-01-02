-- Create the get_potential_event_matches function
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
        SELECT DISTINCT ea.user_id,
          public.mask_full_name(up.profile_data->>'fullName') as user_name
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

        -- Skip if user not found
        IF other_user_data IS NULL THEN
            CONTINUE;
        END IF;

        -- Skip if other user doesn't have event matching enabled
        IF NOT other_user_data.shared_event_matching_enabled THEN
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
        FOR shared_interest_category IN
            SELECT jsonb_object_keys(current_user_interests)
        LOOP
            -- Check if both users have this category
            IF current_user_interests ? shared_interest_category AND other_user_interests ? shared_interest_category THEN
                -- Check if they have any overlapping interests in this category
                IF EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements_text(current_user_interests->shared_interest_category) AS current_user_interest
                    WHERE current_user_interest = ANY(
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

        -- Check if match already exists
        SELECT COUNT(*) INTO existing_match_count
        FROM matches
        WHERE (user1_id = p_user_id AND user2_id = other_attendee.user_id)
           OR (user1_id = other_attendee.user_id AND user2_id = p_user_id);

        -- Skip if match already exists
        IF existing_match_count > 0 THEN
            CONTINUE;
        END IF;

        -- Return this potential match
        RETURN QUERY SELECT
            other_attendee.user_id,
            COALESCE(other_attendee.user_name, 'Unknown User'),
            shared_intents_list;
    END LOOP;

    RETURN;
END;
$$;

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION get_potential_event_matches(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_potential_event_matches(UUID, UUID) TO anon;