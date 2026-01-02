-- Continuous user proximity matching function
-- Runs periodically to find matches between users based on proximity, shared intents, and interests

CREATE OR REPLACE FUNCTION perform_continuous_user_matching()
RETURNS TABLE (
    users_processed INTEGER,
    matches_created INTEGER,
    status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    user_record RECORD;
    nearby_user_record RECORD;
    current_user_intents TEXT[];
    current_user_interests JSONB;
    other_user_intents TEXT[];
    other_user_interests JSONB;
    shared_intents TEXT[];
    has_shared_interest BOOLEAN := FALSE;
    interest_category TEXT;
    total_users_processed INTEGER := 0;
    total_matches_created INTEGER := 0;
    current_user_profile RECORD;
    other_user_profile RECORD;
    current_user_age INTEGER;
    other_user_age INTEGER;
    loop_intent TEXT;  -- Loop variable for FOREACH (renamed to avoid ambiguity with column names)
    intent_gender_match BOOLEAN;
    intent_age_match BOOLEAN;
    overall_gender_match BOOLEAN;
    overall_age_match BOOLEAN;
    strict_enforcement BOOLEAN;
BEGIN
    SET search_path = 'public';

    RAISE NOTICE 'Starting continuous user matching at %', NOW();

    -- Loop through all visible users with recent locations
    FOR user_record IN
        SELECT
            ul.user_id,
            ul.latitude,
            ul.longitude,
            u.active_modes,
            u.match_radius_default,
            COALESCE(u.user_visibility_setting,false) as user_visibility_setting,
            COALESCE(u.system_visibility_status,'visible') as system_visibility_status
        FROM user_locations ul
        INNER JOIN users u ON ul.user_id = u.id
        WHERE (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE)
          AND COALESCE(u.user_visibility_setting,false) = TRUE
          AND COALESCE(u.system_visibility_status,'visible') = 'visible')
        AND ul.updated_at >= NOW() - INTERVAL '5 minutes'  -- Only users with recent location updates
        ORDER BY ul.updated_at DESC
    LOOP
        total_users_processed := total_users_processed + 1;

        RAISE NOTICE 'Processing user: % (lat: %, lng: %)', user_record.user_id, user_record.latitude, user_record.longitude;

        -- Get current user's profile data
        SELECT
            gender,
            date_of_birth,
            gender_preferences,
            age_preferences,
            strict_gender_age_enforcement
        INTO current_user_profile
        FROM users
        WHERE id = user_record.user_id;

        -- Calculate current user age
        IF current_user_profile.date_of_birth IS NOT NULL THEN
            current_user_age := EXTRACT(YEAR FROM AGE(current_user_profile.date_of_birth));
        END IF;

        -- Get user's interests (take from first profile)
        SELECT profile_data->'interests' INTO current_user_interests
        FROM user_profiles
        WHERE user_id = user_record.user_id AND profile_data ? 'interests'
        LIMIT 1;

        current_user_intents := user_record.active_modes;

        -- Find nearby users
        FOR nearby_user_record IN
            SELECT * FROM find_nearby_users(
                user_record.user_id,
                user_record.latitude,
                user_record.longitude,
                (user_record.match_radius_default / 1000.0)::DOUBLE PRECISION  -- Convert meters to km
            )
        LOOP
            RAISE NOTICE '  Checking nearby user: % (distance: % km)', nearby_user_record.user_id, nearby_user_record.distance_km;

            -- Check if match already exists
            IF EXISTS (
                SELECT 1 FROM matches
                WHERE (user1_id = user_record.user_id AND user2_id = nearby_user_record.user_id)
                   OR (user1_id = nearby_user_record.user_id AND user2_id = user_record.user_id)
            ) THEN
                RAISE NOTICE '    Match already exists, skipping';
                CONTINUE;
            END IF;

            -- Get other user's profile data
            SELECT
                gender,
                date_of_birth,
                gender_preferences,
                age_preferences,
                strict_gender_age_enforcement,
                active_modes
            INTO other_user_profile
            FROM users
            WHERE id = nearby_user_record.user_id AND (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
              AND COALESCE(user_visibility_setting,false) = TRUE
              AND COALESCE(system_visibility_status,'visible') = 'visible');

            IF other_user_profile.active_modes IS NULL OR array_length(other_user_profile.active_modes, 1) = 0 THEN
                CONTINUE;
            END IF;

            -- Calculate other user age
            IF other_user_profile.date_of_birth IS NOT NULL THEN
                other_user_age := EXTRACT(YEAR FROM AGE(other_user_profile.date_of_birth));
            END IF;

            -- Check shared intents
            SELECT ARRAY(
                SELECT intent_item
                FROM unnest(current_user_intents) as t(intent_item)
                WHERE intent_item = ANY(other_user_profile.active_modes)
            ) INTO shared_intents;

            IF array_length(shared_intents, 1) IS NULL OR array_length(shared_intents, 1) = 0 THEN
                RAISE NOTICE '    No shared intents, skipping';
                CONTINUE;
            END IF;

            -- Check gender and age preferences for each shared intent
            overall_gender_match := TRUE;
            overall_age_match := TRUE;
            strict_enforcement := current_user_profile.strict_gender_age_enforcement OR other_user_profile.strict_gender_age_enforcement;

            FOREACH loop_intent IN ARRAY shared_intents LOOP
                intent_gender_match := TRUE;
                intent_age_match := TRUE;

                -- Check gender preferences for this intent
                IF current_user_profile.gender_preferences IS NOT NULL AND current_user_profile.gender IS NOT NULL THEN
                    IF current_user_profile.gender_preferences ? loop_intent THEN
                        IF NOT (current_user_profile.gender_preferences->loop_intent ? other_user_profile.gender) THEN
                            intent_gender_match := FALSE;
                        END IF;
                    END IF;
                END IF;

                IF other_user_profile.gender_preferences IS NOT NULL AND other_user_profile.gender IS NOT NULL THEN
                    IF other_user_profile.gender_preferences ? loop_intent THEN
                        IF NOT (other_user_profile.gender_preferences->loop_intent ? current_user_profile.gender) THEN
                            intent_gender_match := FALSE;
                        END IF;
                    END IF;
                END IF;

                -- Check age preferences for this intent
                IF current_user_age IS NOT NULL AND other_user_age IS NOT NULL THEN
                    IF current_user_profile.age_preferences IS NOT NULL AND current_user_profile.age_preferences ? loop_intent THEN
                        IF jsonb_array_length(current_user_profile.age_preferences->loop_intent) >= 2 THEN
                            DECLARE
                                min_age DOUBLE PRECISION := (current_user_profile.age_preferences->loop_intent->>0)::DOUBLE PRECISION;
                                max_age DOUBLE PRECISION := (current_user_profile.age_preferences->loop_intent->>1)::DOUBLE PRECISION;
                            BEGIN
                                IF NOT (other_user_age >= min_age AND other_user_age <= max_age) THEN
                                    intent_age_match := FALSE;
                                END IF;
                            END;
                        END IF;
                    END IF;

                    IF other_user_profile.age_preferences IS NOT NULL AND other_user_profile.age_preferences ? loop_intent THEN
                        IF jsonb_array_length(other_user_profile.age_preferences->loop_intent) >= 2 THEN
                            DECLARE
                                min_age DOUBLE PRECISION := (other_user_profile.age_preferences->loop_intent->>0)::DOUBLE PRECISION;
                                max_age DOUBLE PRECISION := (other_user_profile.age_preferences->loop_intent->>1)::DOUBLE PRECISION;
                            BEGIN
                                IF NOT (current_user_age >= min_age AND current_user_age <= max_age) THEN
                                    intent_age_match := FALSE;
                                END IF;
                            END;
                        END IF;
                    END IF;
                END IF;

                -- If strict enforcement is enabled and this intent doesn't match, mark overall as false
                IF strict_enforcement AND (NOT intent_gender_match OR NOT intent_age_match) THEN
                    overall_gender_match := FALSE;
                    overall_age_match := FALSE;
                    EXIT; -- No need to check other intents if strict enforcement fails
                ELSIF NOT intent_gender_match THEN
                    overall_gender_match := FALSE;
                ELSIF NOT intent_age_match THEN
                    overall_age_match := FALSE;
                END IF;
            END LOOP;

            -- Skip if strict enforcement is enabled and preferences don't match
            IF strict_enforcement AND (NOT overall_gender_match OR NOT overall_age_match) THEN
                RAISE NOTICE '    Preferences don''t match with strict enforcement, skipping';
                CONTINUE;
            END IF;

            -- Get other user's interests
            SELECT profile_data->'interests' INTO other_user_interests
            FROM user_profiles
            WHERE user_id = nearby_user_record.user_id AND profile_data ? 'interests'
            LIMIT 1;

            -- Check shared interests
            has_shared_interest := FALSE;
            IF current_user_interests IS NOT NULL AND other_user_interests IS NOT NULL THEN
                -- Check if any category has shared interests
                FOR interest_category IN SELECT jsonb_object_keys(current_user_interests) INTERSECT SELECT jsonb_object_keys(other_user_interests) LOOP
                    IF jsonb_array_length(current_user_interests->interest_category) > 0 AND jsonb_array_length(other_user_interests->interest_category) > 0 THEN
                        -- Check if arrays intersect
                        IF EXISTS (
                            SELECT 1
                            FROM jsonb_array_elements_text(current_user_interests->interest_category) as i1
                            WHERE i1 IN (SELECT jsonb_array_elements_text(other_user_interests->interest_category))
                        ) THEN
                            has_shared_interest := TRUE;
                            EXIT;
                        END IF;
                    END IF;
                END LOOP;
            END IF;

            IF has_shared_interest THEN
                RAISE NOTICE '    Creating match between % and %', user_record.user_id, nearby_user_record.user_id;

                -- Create match
                INSERT INTO matches (
                    user1_id,
                    user2_id,
                    matched_intent,
                    match_type,
                    created_at
                ) VALUES (
                    LEAST(user_record.user_id, nearby_user_record.user_id),
                    GREATEST(user_record.user_id, nearby_user_record.user_id),
                    shared_intents[1],  -- Use first shared intent
                    'proximity',
                    NOW()
                );

                total_matches_created := total_matches_created + 1;
            ELSE
                RAISE NOTICE '    No shared interests, skipping';
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'Continuous user matching completed. Users processed: %, Matches created: %', total_users_processed, total_matches_created;

    RETURN QUERY SELECT total_users_processed, total_matches_created, 'completed'::TEXT;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION perform_continuous_user_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION perform_continuous_user_matching() TO anon;