-- Migration: Update event and proximity matching functions to use lifestyle, family, religion, and height filters
-- Date: July 6, 2026
-- Description: Adds lifestyle, family, religion, and height preference checking to both perform_event_matching
--              and perform_continuous_user_matching functions
-- Columns expected: lifestyle, family, religion (JSONB), height (INTEGER),
--                   lifestyle_filters, family_filters, religion_filters, height_preferences (JSONB)
-- Supabase Compatible: Uses SECURITY DEFINER, proper permissions, and standard PostgreSQL syntax

-- Update the perform_event_matching function to include lifestyle, family, religion, and height checks
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
    lifestyle_match BOOLEAN := TRUE;
    family_match BOOLEAN := TRUE;
    religion_match BOOLEAN := TRUE;
    height_match BOOLEAN := TRUE;
    should_create_match BOOLEAN := TRUE;
BEGIN
    -- Validate input parameter
    IF p_event_id IS NULL THEN
        RAISE EXCEPTION 'Event ID cannot be null';
    END IF;

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
            active_modes,
            lifestyle_filters,
            family_filters,
            religion_filters,
            height_preferences,
            lifestyle,
            family,
            religion,
            height
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
                    active_modes,
                    lifestyle_filters,
                    family_filters,
                    religion_filters,
                    height_preferences,
                    lifestyle,
                    family,
                    religion,
                    height
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

                -- Check lifestyle filters
                lifestyle_match := TRUE;
                IF user1_profile.lifestyle_filters IS NOT NULL AND user2_profile.lifestyle IS NOT NULL THEN
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_object_keys(user1_profile.lifestyle_filters) AS intent_key
                        WHERE ((user1_profile.lifestyle_filters->intent_key->>'smoking_strict')::BOOLEAN = TRUE
                               AND user1_profile.lifestyle_filters->intent_key ? 'smoking'
                               AND COALESCE(user1_profile.lifestyle_filters->intent_key->>'smoking', '') != COALESCE(user2_profile.lifestyle->>'smoking', ''))
                           OR ((user1_profile.lifestyle_filters->intent_key->>'drinking_strict')::BOOLEAN = TRUE
                               AND user1_profile.lifestyle_filters->intent_key ? 'drinking'
                               AND COALESCE(user1_profile.lifestyle_filters->intent_key->>'drinking', '') != COALESCE(user2_profile.lifestyle->>'drinking', ''))
                           OR ((user1_profile.lifestyle_filters->intent_key->>'exercise_strict')::BOOLEAN = TRUE
                               AND user1_profile.lifestyle_filters->intent_key ? 'exercise'
                               AND COALESCE(user1_profile.lifestyle_filters->intent_key->>'exercise', '') != COALESCE(user2_profile.lifestyle->>'exercise', ''))
                           OR ((user1_profile.lifestyle_filters->intent_key->>'diet_strict')::BOOLEAN = TRUE
                               AND user1_profile.lifestyle_filters->intent_key ? 'diet'
                               AND COALESCE(user1_profile.lifestyle_filters->intent_key->>'diet', '') != COALESCE(user2_profile.lifestyle->>'diet', ''))
                    ) THEN
                        lifestyle_match := FALSE;
                        RAISE NOTICE '  Lifestyle filter mismatch: user1 % filters exclude user2 %', v_user1_id, v_user2_id;
                    END IF;
                END IF;

                IF user2_profile.lifestyle_filters IS NOT NULL AND user1_profile.lifestyle IS NOT NULL THEN
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_object_keys(user2_profile.lifestyle_filters) AS intent_key
                        WHERE ((user2_profile.lifestyle_filters->intent_key->>'smoking_strict')::BOOLEAN = TRUE
                               AND user2_profile.lifestyle_filters->intent_key ? 'smoking'
                               AND COALESCE(user2_profile.lifestyle_filters->intent_key->>'smoking', '') != COALESCE(user1_profile.lifestyle->>'smoking', ''))
                           OR ((user2_profile.lifestyle_filters->intent_key->>'drinking_strict')::BOOLEAN = TRUE
                               AND user2_profile.lifestyle_filters->intent_key ? 'drinking'
                               AND COALESCE(user2_profile.lifestyle_filters->intent_key->>'drinking', '') != COALESCE(user1_profile.lifestyle->>'drinking', ''))
                           OR ((user2_profile.lifestyle_filters->intent_key->>'exercise_strict')::BOOLEAN = TRUE
                               AND user2_profile.lifestyle_filters->intent_key ? 'exercise'
                               AND COALESCE(user2_profile.lifestyle_filters->intent_key->>'exercise', '') != COALESCE(user1_profile.lifestyle->>'exercise', ''))
                           OR ((user2_profile.lifestyle_filters->intent_key->>'diet_strict')::BOOLEAN = TRUE
                               AND user2_profile.lifestyle_filters->intent_key ? 'diet'
                               AND COALESCE(user2_profile.lifestyle_filters->intent_key->>'diet', '') != COALESCE(user1_profile.lifestyle->>'diet', ''))
                    ) THEN
                        lifestyle_match := FALSE;
                        RAISE NOTICE '  Lifestyle filter mismatch: user2 % filters exclude user1 %', v_user2_id, v_user1_id;
                    END IF;
                END IF;

                -- Check family filters
                family_match := TRUE;
                IF user1_profile.family_filters IS NOT NULL AND user2_profile.family IS NOT NULL THEN
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_object_keys(user1_profile.family_filters) AS intent_key
                        WHERE (user1_profile.family_filters->intent_key->>'has_children_strict')::BOOLEAN = TRUE
                          AND user1_profile.family_filters->intent_key ? 'has_children'
                          AND (user1_profile.family_filters->intent_key->>'has_children' = 'yes')
                              IS DISTINCT FROM
                              (user2_profile.family->>'has_children' = 'true')
                    ) THEN
                        family_match := FALSE;
                        RAISE NOTICE '  Family filter mismatch: user1 % filters exclude user2 %', v_user1_id, v_user2_id;
                    END IF;
                END IF;

                IF user2_profile.family_filters IS NOT NULL AND user1_profile.family IS NOT NULL THEN
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_object_keys(user2_profile.family_filters) AS intent_key
                        WHERE (user2_profile.family_filters->intent_key->>'has_children_strict')::BOOLEAN = TRUE
                          AND user2_profile.family_filters->intent_key ? 'has_children'
                          AND (user2_profile.family_filters->intent_key->>'has_children' = 'yes')
                              IS DISTINCT FROM
                              (user1_profile.family->>'has_children' = 'true')
                    ) THEN
                        family_match := FALSE;
                        RAISE NOTICE '  Family filter mismatch: user2 % filters exclude user1 %', v_user2_id, v_user1_id;
                    END IF;
                END IF;

                -- Check religion filters
                religion_match := TRUE;
                IF user1_profile.religion_filters IS NOT NULL AND user2_profile.religion IS NOT NULL THEN
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_object_keys(user1_profile.religion_filters) AS intent_key
                        WHERE (user1_profile.religion_filters->intent_key->>'strict')::BOOLEAN = TRUE
                          AND (user1_profile.religion_filters->intent_key->>'same_religion')::BOOLEAN = TRUE
                          AND user1_profile.religion_filters->intent_key ? 'religion'
                          AND COALESCE(user1_profile.religion_filters->intent_key->>'religion', '') != COALESCE(user2_profile.religion->>'religion', '')
                    ) THEN
                        religion_match := FALSE;
                        RAISE NOTICE '  Religion filter mismatch: user1 % filters exclude user2 %', v_user1_id, v_user2_id;
                    END IF;
                END IF;

                IF user2_profile.religion_filters IS NOT NULL AND user1_profile.religion IS NOT NULL THEN
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_object_keys(user2_profile.religion_filters) AS intent_key
                        WHERE (user2_profile.religion_filters->intent_key->>'strict')::BOOLEAN = TRUE
                          AND (user2_profile.religion_filters->intent_key->>'same_religion')::BOOLEAN = TRUE
                          AND user2_profile.religion_filters->intent_key ? 'religion'
                          AND COALESCE(user2_profile.religion_filters->intent_key->>'religion', '') != COALESCE(user1_profile.religion->>'religion', '')
                    ) THEN
                        religion_match := FALSE;
                        RAISE NOTICE '  Religion filter mismatch: user2 % filters exclude user1 %', v_user2_id, v_user1_id;
                    END IF;
                END IF;

                -- Check height preferences
                height_match := TRUE;
                IF user1_profile.height_preferences IS NOT NULL AND user2_profile.height IS NOT NULL THEN
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_object_keys(user1_profile.height_preferences) AS intent_key
                        WHERE (user1_profile.height_preferences->intent_key->>'strict')::BOOLEAN = TRUE
                          AND user1_profile.height_preferences->intent_key ? 'min'
                          AND user1_profile.height_preferences->intent_key ? 'max'
                          AND (user2_profile.height < (user1_profile.height_preferences->intent_key->>'min')::INTEGER
                               OR user2_profile.height > (user1_profile.height_preferences->intent_key->>'max')::INTEGER)
                    ) THEN
                        height_match := FALSE;
                        RAISE NOTICE '  Height filter mismatch: user1 % filters exclude user2 %', v_user1_id, v_user2_id;
                    END IF;
                END IF;

                IF user2_profile.height_preferences IS NOT NULL AND user1_profile.height IS NOT NULL THEN
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_object_keys(user2_profile.height_preferences) AS intent_key
                        WHERE (user2_profile.height_preferences->intent_key->>'strict')::BOOLEAN = TRUE
                          AND user2_profile.height_preferences->intent_key ? 'min'
                          AND user2_profile.height_preferences->intent_key ? 'max'
                          AND (user1_profile.height < (user2_profile.height_preferences->intent_key->>'min')::INTEGER
                               OR user1_profile.height > (user2_profile.height_preferences->intent_key->>'max')::INTEGER)
                    ) THEN
                        height_match := FALSE;
                        RAISE NOTICE '  Height filter mismatch: user2 % filters exclude user1 %', v_user2_id, v_user1_id;
                    END IF;
                END IF;

                -- Determine if we should create the match
                should_create_match := TRUE;

                -- If either user has strict enforcement and preferences don't match, don't create match
                IF (user1_profile.strict_gender_age_enforcement AND (NOT gender_match OR NOT age_match)) OR
                   (user2_profile.strict_gender_age_enforcement AND (NOT gender_match OR NOT age_match)) THEN
                    should_create_match := FALSE;
                END IF;

                -- If any strict lifestyle/family/religion/height filter fails, don't create match
                IF NOT lifestyle_match OR NOT family_match OR NOT religion_match OR NOT height_match THEN
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

-- Update the perform_continuous_user_matching function to include lifestyle, family, religion, and height checks
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
    loop_intent TEXT;
    intent_gender_match BOOLEAN;
    intent_age_match BOOLEAN;
    intent_lifestyle_match BOOLEAN;
    intent_family_match BOOLEAN;
    intent_religion_match BOOLEAN;
    intent_height_match BOOLEAN;
    overall_gender_match BOOLEAN;
    overall_age_match BOOLEAN;
    overall_lifestyle_match BOOLEAN;
    overall_family_match BOOLEAN;
    overall_religion_match BOOLEAN;
    overall_height_match BOOLEAN;
    strict_enforcement BOOLEAN;
BEGIN
    -- Log start of matching process
    RAISE NOTICE 'Starting continuous user matching at %', NOW();

    -- Loop through all visible users with recent locations
    FOR user_record IN
        SELECT
            ul.user_id,
            ul.latitude,
            ul.longitude,
            u.active_modes,
            u.match_radius_default,
            u.user_visibility_setting
        FROM user_locations ul
        INNER JOIN users u ON ul.user_id = u.id
        WHERE u.user_visibility_setting = TRUE
        AND COALESCE(u.system_visibility_status,'visible') = 'visible'
        AND EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE)
        AND ul.updated_at >= NOW() - INTERVAL '5 minutes'
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
            strict_gender_age_enforcement,
            lifestyle_filters,
            family_filters,
            religion_filters,
            height_preferences,
            lifestyle,
            family,
            religion,
            height
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
                (user_record.match_radius_default / 1000.0)::DOUBLE PRECISION
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
                active_modes,
                lifestyle_filters,
                family_filters,
                religion_filters,
                height_preferences,
                lifestyle,
                family,
                religion,
                height
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
            overall_lifestyle_match := TRUE;
            overall_family_match := TRUE;
            overall_religion_match := TRUE;
            overall_height_match := TRUE;
            strict_enforcement := current_user_profile.strict_gender_age_enforcement OR other_user_profile.strict_gender_age_enforcement;

            FOREACH loop_intent IN ARRAY shared_intents LOOP
                intent_gender_match := TRUE;
                intent_age_match := TRUE;
                intent_lifestyle_match := TRUE;
                intent_family_match := TRUE;
                intent_religion_match := TRUE;
                intent_height_match := TRUE;

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

                -- Check lifestyle filters for this intent
                IF current_user_profile.lifestyle_filters IS NOT NULL
                   AND current_user_profile.lifestyle_filters ? loop_intent
                   AND other_user_profile.lifestyle IS NOT NULL THEN
                    IF ((current_user_profile.lifestyle_filters->loop_intent->>'smoking_strict')::BOOLEAN = TRUE
                        AND current_user_profile.lifestyle_filters->loop_intent ? 'smoking'
                        AND COALESCE(current_user_profile.lifestyle_filters->loop_intent->>'smoking', '') != COALESCE(other_user_profile.lifestyle->>'smoking', ''))
                       OR ((current_user_profile.lifestyle_filters->loop_intent->>'drinking_strict')::BOOLEAN = TRUE
                           AND current_user_profile.lifestyle_filters->loop_intent ? 'drinking'
                           AND COALESCE(current_user_profile.lifestyle_filters->loop_intent->>'drinking', '') != COALESCE(other_user_profile.lifestyle->>'drinking', ''))
                       OR ((current_user_profile.lifestyle_filters->loop_intent->>'exercise_strict')::BOOLEAN = TRUE
                           AND current_user_profile.lifestyle_filters->loop_intent ? 'exercise'
                           AND COALESCE(current_user_profile.lifestyle_filters->loop_intent->>'exercise', '') != COALESCE(other_user_profile.lifestyle->>'exercise', ''))
                       OR ((current_user_profile.lifestyle_filters->loop_intent->>'diet_strict')::BOOLEAN = TRUE
                           AND current_user_profile.lifestyle_filters->loop_intent ? 'diet'
                           AND COALESCE(current_user_profile.lifestyle_filters->loop_intent->>'diet', '') != COALESCE(other_user_profile.lifestyle->>'diet', ''))
                    THEN
                        intent_lifestyle_match := FALSE;
                        RAISE NOTICE '    Lifestyle filter mismatch for intent %: current user % vs nearby user %', loop_intent, user_record.user_id, nearby_user_record.user_id;
                    END IF;
                END IF;

                IF other_user_profile.lifestyle_filters IS NOT NULL
                   AND other_user_profile.lifestyle_filters ? loop_intent
                   AND current_user_profile.lifestyle IS NOT NULL THEN
                    IF ((other_user_profile.lifestyle_filters->loop_intent->>'smoking_strict')::BOOLEAN = TRUE
                        AND other_user_profile.lifestyle_filters->loop_intent ? 'smoking'
                        AND COALESCE(other_user_profile.lifestyle_filters->loop_intent->>'smoking', '') != COALESCE(current_user_profile.lifestyle->>'smoking', ''))
                       OR ((other_user_profile.lifestyle_filters->loop_intent->>'drinking_strict')::BOOLEAN = TRUE
                           AND other_user_profile.lifestyle_filters->loop_intent ? 'drinking'
                           AND COALESCE(other_user_profile.lifestyle_filters->loop_intent->>'drinking', '') != COALESCE(current_user_profile.lifestyle->>'drinking', ''))
                       OR ((other_user_profile.lifestyle_filters->loop_intent->>'exercise_strict')::BOOLEAN = TRUE
                           AND other_user_profile.lifestyle_filters->loop_intent ? 'exercise'
                           AND COALESCE(other_user_profile.lifestyle_filters->loop_intent->>'exercise', '') != COALESCE(current_user_profile.lifestyle->>'exercise', ''))
                       OR ((other_user_profile.lifestyle_filters->loop_intent->>'diet_strict')::BOOLEAN = TRUE
                           AND other_user_profile.lifestyle_filters->loop_intent ? 'diet'
                           AND COALESCE(other_user_profile.lifestyle_filters->loop_intent->>'diet', '') != COALESCE(current_user_profile.lifestyle->>'diet', ''))
                    THEN
                        intent_lifestyle_match := FALSE;
                        RAISE NOTICE '    Lifestyle filter mismatch for intent %: nearby user % vs current user %', loop_intent, nearby_user_record.user_id, user_record.user_id;
                    END IF;
                END IF;

                -- Check family filters for this intent
                IF current_user_profile.family_filters IS NOT NULL
                   AND current_user_profile.family_filters ? loop_intent
                   AND other_user_profile.family IS NOT NULL THEN
                    IF (current_user_profile.family_filters->loop_intent->>'has_children_strict')::BOOLEAN = TRUE
                       AND current_user_profile.family_filters->loop_intent ? 'has_children'
                        AND (current_user_profile.family_filters->loop_intent->>'has_children' = 'yes')
                            IS DISTINCT FROM
                            (other_user_profile.family->>'has_children' = 'true')
                    THEN
                        intent_family_match := FALSE;
                        RAISE NOTICE '    Family filter mismatch for intent %: current user % vs nearby user %', loop_intent, user_record.user_id, nearby_user_record.user_id;
                    END IF;
                END IF;

                IF other_user_profile.family_filters IS NOT NULL
                   AND other_user_profile.family_filters ? loop_intent
                   AND current_user_profile.family IS NOT NULL THEN
                    IF (other_user_profile.family_filters->loop_intent->>'has_children_strict')::BOOLEAN = TRUE
                       AND other_user_profile.family_filters->loop_intent ? 'has_children'
                        AND (other_user_profile.family_filters->loop_intent->>'has_children' = 'yes')
                            IS DISTINCT FROM
                            (current_user_profile.family->>'has_children' = 'true')
                    THEN
                        intent_family_match := FALSE;
                        RAISE NOTICE '    Family filter mismatch for intent %: nearby user % vs current user %', loop_intent, nearby_user_record.user_id, user_record.user_id;
                    END IF;
                END IF;

                -- Check religion filters for this intent
                IF current_user_profile.religion_filters IS NOT NULL
                   AND current_user_profile.religion_filters ? loop_intent
                   AND other_user_profile.religion IS NOT NULL THEN
                    IF (current_user_profile.religion_filters->loop_intent->>'strict')::BOOLEAN = TRUE
                       AND (current_user_profile.religion_filters->loop_intent->>'same_religion')::BOOLEAN = TRUE
                       AND current_user_profile.religion_filters->loop_intent ? 'religion'
                       AND COALESCE(current_user_profile.religion_filters->loop_intent->>'religion', '') != COALESCE(other_user_profile.religion->>'religion', '')
                    THEN
                        intent_religion_match := FALSE;
                        RAISE NOTICE '    Religion filter mismatch for intent %: current user % vs nearby user %', loop_intent, user_record.user_id, nearby_user_record.user_id;
                    END IF;
                END IF;

                IF other_user_profile.religion_filters IS NOT NULL
                   AND other_user_profile.religion_filters ? loop_intent
                   AND current_user_profile.religion IS NOT NULL THEN
                    IF (other_user_profile.religion_filters->loop_intent->>'strict')::BOOLEAN = TRUE
                       AND (other_user_profile.religion_filters->loop_intent->>'same_religion')::BOOLEAN = TRUE
                       AND other_user_profile.religion_filters->loop_intent ? 'religion'
                       AND COALESCE(other_user_profile.religion_filters->loop_intent->>'religion', '') != COALESCE(current_user_profile.religion->>'religion', '')
                    THEN
                        intent_religion_match := FALSE;
                        RAISE NOTICE '    Religion filter mismatch for intent %: nearby user % vs current user %', loop_intent, nearby_user_record.user_id, user_record.user_id;
                    END IF;
                END IF;

                -- Check height preferences for this intent
                IF current_user_profile.height_preferences IS NOT NULL
                   AND current_user_profile.height_preferences ? loop_intent
                   AND other_user_profile.height IS NOT NULL THEN
                    IF (current_user_profile.height_preferences->loop_intent->>'strict')::BOOLEAN = TRUE
                       AND current_user_profile.height_preferences->loop_intent ? 'min'
                       AND current_user_profile.height_preferences->loop_intent ? 'max'
                       AND (other_user_profile.height < (current_user_profile.height_preferences->loop_intent->>'min')::INTEGER
                            OR other_user_profile.height > (current_user_profile.height_preferences->loop_intent->>'max')::INTEGER)
                    THEN
                        intent_height_match := FALSE;
                        RAISE NOTICE '    Height filter mismatch for intent %: current user % vs nearby user %', loop_intent, user_record.user_id, nearby_user_record.user_id;
                    END IF;
                END IF;

                IF other_user_profile.height_preferences IS NOT NULL
                   AND other_user_profile.height_preferences ? loop_intent
                   AND current_user_profile.height IS NOT NULL THEN
                    IF (other_user_profile.height_preferences->loop_intent->>'strict')::BOOLEAN = TRUE
                       AND other_user_profile.height_preferences->loop_intent ? 'min'
                       AND other_user_profile.height_preferences->loop_intent ? 'max'
                       AND (current_user_profile.height < (other_user_profile.height_preferences->loop_intent->>'min')::INTEGER
                            OR current_user_profile.height > (other_user_profile.height_preferences->loop_intent->>'max')::INTEGER)
                    THEN
                        intent_height_match := FALSE;
                        RAISE NOTICE '    Height filter mismatch for intent %: nearby user % vs current user %', loop_intent, nearby_user_record.user_id, user_record.user_id;
                    END IF;
                END IF;

                -- If strict enforcement is enabled and this intent doesn't match for gender/age, mark overall as false
                IF strict_enforcement AND (NOT intent_gender_match OR NOT intent_age_match) THEN
                    overall_gender_match := FALSE;
                    overall_age_match := FALSE;
                    EXIT;
                ELSIF NOT intent_gender_match THEN
                    overall_gender_match := FALSE;
                ELSIF NOT intent_age_match THEN
                    overall_age_match := FALSE;
                END IF;

                -- If any strict lifestyle/family/religion/height filter fails for this intent, mark overall as false and exit
                IF NOT intent_lifestyle_match OR NOT intent_family_match OR NOT intent_religion_match OR NOT intent_height_match THEN
                    overall_lifestyle_match := FALSE;
                    overall_family_match := FALSE;
                    overall_religion_match := FALSE;
                    overall_height_match := FALSE;
                    EXIT;
                END IF;
            END LOOP;

            -- Skip if strict enforcement is enabled and gender/age preferences don't match
            IF strict_enforcement AND (NOT overall_gender_match OR NOT overall_age_match) THEN
                RAISE NOTICE '    Gender/age preferences don''t match with strict enforcement, skipping';
                CONTINUE;
            END IF;

            -- Skip if any strict lifestyle/family/religion/height filter fails
            IF NOT overall_lifestyle_match OR NOT overall_family_match OR NOT overall_religion_match OR NOT overall_height_match THEN
                RAISE NOTICE '    Lifestyle/family/religion/height strict filters not satisfied, skipping';
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
                    shared_intents[1],
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

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION perform_event_matching(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION perform_event_matching(UUID) TO anon;
GRANT EXECUTE ON FUNCTION perform_continuous_user_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION perform_continuous_user_matching() TO anon;
