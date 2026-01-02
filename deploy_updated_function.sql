-- Deploy the updated perform_event_matching function
-- This fixes the ambiguous column reference error

-- Drop the existing function first
DROP FUNCTION IF EXISTS perform_event_matching(UUID);

-- Create the updated function
-- Create the perform_event_matching function with proper intent and interest matching
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
        SELECT active_modes, COALESCE(user_visibility_setting,false) as user_visibility_setting, shared_event_matching_enabled
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
            SELECT active_modes, COALESCE(user_visibility_setting,false) as user_visibility_setting, shared_event_matching_enabled
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

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION perform_event_matching(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION perform_event_matching(UUID) TO anon;

-- Create trigger to automatically perform event matching when users join events
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

-- Create the trigger on event_attendees table
DROP TRIGGER IF EXISTS trigger_event_matching ON event_attendees;
CREATE TRIGGER trigger_event_matching
    AFTER INSERT ON event_attendees
    FOR EACH ROW
    EXECUTE FUNCTION trigger_perform_event_matching();

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION trigger_perform_event_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION trigger_perform_event_matching() TO anon;