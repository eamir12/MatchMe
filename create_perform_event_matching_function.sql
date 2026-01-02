-- Create the perform_event_matching function
CREATE OR REPLACE FUNCTION perform_event_matching(p_event_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    event_attendee RECORD;
    other_attendee RECORD;
    v_user1_id UUID;
    v_user2_id UUID;
    shared_interests JSONB;
    shared_intents TEXT;
    existing_match_id UUID;
    user1_profile RECORD;
    user2_profile RECORD;
    user1_gender_pref JSONB;
    user1_age_pref JSONB;
    user2_gender_pref JSONB;
    user2_age_pref JSONB;
    user1_strict_enforcement BOOLEAN;
    user2_strict_enforcement BOOLEAN;
    user1_age INTEGER;
    user2_age INTEGER;
    gender_match BOOLEAN := FALSE;
    age_match BOOLEAN := FALSE;
    should_create_match BOOLEAN := TRUE;
BEGIN
    -- Get all attendees for this event
    FOR event_attendee IN
        SELECT DISTINCT ea.user_id
        FROM event_attendees ea
        WHERE ea.event_id = p_event_id
    LOOP
        v_user1_id := event_attendee.user_id;

        -- Get user1 profile data
        SELECT
            gender,
            date_of_birth,
            gender_preferences,
            age_preferences,
            strict_gender_age_enforcement,
            active_modes
        INTO user1_profile
        FROM users
        WHERE id = v_user1_id;

        -- Calculate user1 age
        IF user1_profile.date_of_birth IS NOT NULL THEN
            user1_age := EXTRACT(YEAR FROM AGE(user1_profile.date_of_birth));
        END IF;

        -- Compare with other attendees to find potential matches
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
            SELECT id INTO existing_match_id
            FROM matches m
            WHERE m.user1_id = v_user1_id AND m.user2_id = v_user2_id
            LIMIT 1;

            -- If no existing match, check preferences and create one
            IF existing_match_id IS NULL THEN
                -- Get user2 profile data
                SELECT
                    gender,
                    date_of_birth,
                    gender_preferences,
                    age_preferences,
                    strict_gender_age_enforcement,
                    active_modes
                INTO user2_profile
                FROM users
                WHERE id = v_user2_id;

                -- Calculate user2 age
                IF user2_profile.date_of_birth IS NOT NULL THEN
                    user2_age := EXTRACT(YEAR FROM AGE(user2_profile.date_of_birth));
                END IF;

                -- Check gender preferences (for event matching, we use a default intent or check all intents)
                -- For simplicity, we'll check if either user has preferences that exclude the other
                gender_match := TRUE;
                age_match := TRUE;

                -- Check if user1's gender preferences exclude user2
                IF user1_profile.gender_preferences IS NOT NULL AND user1_profile.gender IS NOT NULL THEN
                    -- Check if user1 has any gender preferences that would include user2's gender
                    -- If user1 has strict enforcement and user2's gender is not in preferences, exclude
                    IF user1_profile.strict_gender_age_enforcement THEN
                        gender_match := FALSE;
                        -- Check if any intent's preferences include user2's gender
                        IF EXISTS (
                            SELECT 1
                            FROM jsonb_object_keys(user1_profile.gender_preferences) AS intent_key
                            WHERE user1_profile.gender_preferences->intent_key ? user2_profile.gender
                        ) THEN
                            gender_match := TRUE;
                        END IF;
                    END IF;
                END IF;

                -- Check if user2's gender preferences exclude user1
                IF user2_profile.gender_preferences IS NOT NULL AND user2_profile.gender IS NOT NULL THEN
                    IF user2_profile.strict_gender_age_enforcement THEN
                        IF NOT gender_match THEN
                            gender_match := FALSE;
                        ELSE
                            gender_match := FALSE;
                            -- Check if any intent's preferences include user1's gender
                            IF EXISTS (
                                SELECT 1
                                FROM jsonb_object_keys(user2_profile.gender_preferences) AS intent_key
                                WHERE user2_profile.gender_preferences->intent_key ? user1_profile.gender
                            ) THEN
                                gender_match := TRUE;
                            END IF;
                        END IF;
                    END IF;
                END IF;

                -- Check age preferences
                IF user1_age IS NOT NULL AND user2_age IS NOT NULL THEN
                    -- Check if user1's age preferences exclude user2
                    IF user1_profile.age_preferences IS NOT NULL THEN
                        IF user1_profile.strict_gender_age_enforcement THEN
                            age_match := FALSE;
                            -- Check if any intent's age preferences include user2's age
                            IF EXISTS (
                                SELECT 1
                                FROM jsonb_object_keys(user1_profile.age_preferences) AS intent_key
                                WHERE jsonb_array_length(user1_profile.age_preferences->intent_key) >= 2
                                AND (user1_profile.age_preferences->intent_key->>0)::DOUBLE PRECISION <= user2_age
                                AND (user1_profile.age_preferences->intent_key->>1)::DOUBLE PRECISION >= user2_age
                            ) THEN
                                age_match := TRUE;
                            END IF;
                        END IF;
                    END IF;

                    -- Check if user2's age preferences exclude user1
                    IF user2_profile.age_preferences IS NOT NULL THEN
                        IF user2_profile.strict_gender_age_enforcement THEN
                            IF NOT age_match THEN
                                age_match := FALSE;
                            ELSE
                                age_match := FALSE;
                                -- Check if any intent's age preferences include user1's age
                                IF EXISTS (
                                    SELECT 1
                                    FROM jsonb_object_keys(user2_profile.age_preferences) AS intent_key
                                    WHERE jsonb_array_length(user2_profile.age_preferences->intent_key) >= 2
                                    AND (user2_profile.age_preferences->intent_key->>0)::DOUBLE PRECISION <= user1_age
                                    AND (user2_profile.age_preferences->intent_key->>1)::DOUBLE PRECISION >= user1_age
                                ) THEN
                                    age_match := TRUE;
                                END IF;
                            END IF;
                        END IF;
                    END IF;
                END IF;

                -- Determine if we should create the match
                should_create_match := TRUE;

                -- If either user has strict enforcement and preferences don't match, don't create match
                IF (user1_profile.strict_gender_age_enforcement AND (NOT gender_match OR NOT age_match)) OR
                   (user2_profile.strict_gender_age_enforcement AND (NOT gender_match OR NOT age_match)) THEN
                    should_create_match := FALSE;
                END IF;

                -- Find shared intents between users
                shared_intents := '';
                IF user1_profile.active_modes IS NOT NULL AND user2_profile.active_modes IS NOT NULL THEN
                    -- Find intersection of active_modes arrays
                    SELECT string_agg(intent, ', ')
                    INTO shared_intents
                    FROM (
                        SELECT unnest(user1_profile.active_modes) as intent
                        INTERSECT
                        SELECT unnest(user2_profile.active_modes) as intent
                    ) shared;
                END IF;

                -- If no shared intents found, use default
                IF shared_intents IS NULL OR shared_intents = '' THEN
                    shared_intents := 'Attending same event';
                END IF;

                -- Create match record for users attending same event if preferences allow
                IF should_create_match THEN
                    INSERT INTO matches (user1_id, user2_id, match_type, matched_intent, event_id, created_at)
                    VALUES (
                        v_user1_id,
                        v_user2_id,
                        'event',
                        shared_intents,
                        p_event_id,
                        NOW()
                    );
                END IF;
            END IF;
        END LOOP;
    END LOOP;
END;
$$;

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION perform_event_matching(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION perform_event_matching(UUID) TO anon;