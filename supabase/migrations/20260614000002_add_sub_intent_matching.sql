-- Add sub-intent checking to both matching functions
-- Users must share at least one sub-intent per shared main intent to match.
-- If either user has no sub-intent specified (empty/null), they match any sub-intent.

-- ============================================================
-- UPDATE perform_continuous_user_matching (proximity matching)
-- ============================================================

CREATE OR REPLACE FUNCTION perform_continuous_user_matching()
RETURNS TABLE (
    users_processed INTEGER,
    matches_created INTEGER,
    status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $_$
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
    has_matching_sub_intent BOOLEAN := FALSE;
    shared_intent TEXT;
    current_sub_intents TEXT[];
    other_sub_intents TEXT[];
BEGIN
    SET search_path = 'public';

    FOR user_record IN
        SELECT
            ul.user_id, ul.latitude, ul.longitude, u.active_modes,
            u.match_radius_default,
            COALESCE(u.user_visibility_setting,false) AS user_visibility_setting,
            COALESCE(u.system_visibility_status,'visible') AS system_visibility_status
        FROM user_locations ul
        INNER JOIN users u ON ul.user_id = u.id
        WHERE (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE)
          AND COALESCE(u.user_visibility_setting,false) = TRUE
          AND COALESCE(u.system_visibility_status,'visible') = 'visible')
        AND ul.updated_at >= NOW() - INTERVAL '5 minutes'
        ORDER BY ul.updated_at DESC
    LOOP
        total_users_processed := total_users_processed + 1;

        SELECT profile_data->'interests' INTO current_user_interests
        FROM user_profiles
        WHERE user_id = user_record.user_id AND profile_data ? 'interests'
        LIMIT 1;

        current_user_intents := user_record.active_modes;

        FOR nearby_user_record IN
            SELECT * FROM find_nearby_users(
                user_record.user_id, user_record.latitude, user_record.longitude,
                (user_record.match_radius_default / 1000.0)::DOUBLE PRECISION
            )
        LOOP
            IF EXISTS (
                SELECT 1 FROM matches
                WHERE (user1_id = user_record.user_id AND user2_id = nearby_user_record.user_id)
                   OR (user1_id = nearby_user_record.user_id AND user2_id = user_record.user_id)
            ) THEN
                CONTINUE;
            END IF;

            SELECT active_modes INTO other_user_intents
            FROM users WHERE id = nearby_user_record.user_id AND (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
              AND COALESCE(user_visibility_setting,false) = TRUE
              AND COALESCE(system_visibility_status,'visible') = 'visible');

            IF other_user_intents IS NULL OR array_length(other_user_intents, 1) = 0 THEN
                CONTINUE;
            END IF;

            SELECT ARRAY(
                SELECT intent
                FROM unnest(current_user_intents) as t(intent)
                WHERE intent = ANY(other_user_intents)
            ) INTO shared_intents;

            IF array_length(shared_intents, 1) IS NULL OR array_length(shared_intents, 1) = 0 THEN
                CONTINUE;
            END IF;

            -- Check shared sub-intents per shared main intent
            has_matching_sub_intent := FALSE;
            <<sub_intent_loop>>
            FOREACH shared_intent IN ARRAY shared_intents LOOP
                current_sub_intents := ARRAY(
                    SELECT jsonb_array_elements_text(up.profile_data->'sub_intent')
                    FROM user_profiles up
                    WHERE up.user_id = user_record.user_id
                      AND up.intent_type = shared_intent
                      AND up.profile_data ? 'sub_intent'
                );

                other_sub_intents := ARRAY(
                    SELECT jsonb_array_elements_text(up.profile_data->'sub_intent')
                    FROM user_profiles up
                    WHERE up.user_id = nearby_user_record.user_id
                      AND up.intent_type = shared_intent
                      AND up.profile_data ? 'sub_intent'
                );

                -- If either user has no sub-intent, open to all within this intent
                IF array_length(current_sub_intents, 1) IS NULL
                   OR array_length(other_sub_intents, 1) IS NULL THEN
                    has_matching_sub_intent := TRUE;
                    EXIT sub_intent_loop;
                END IF;

                IF current_sub_intents && other_sub_intents THEN
                    has_matching_sub_intent := TRUE;
                    EXIT sub_intent_loop;
                END IF;
            END LOOP sub_intent_loop;

            IF NOT has_matching_sub_intent THEN
                CONTINUE;
            END IF;

            SELECT profile_data->'interests' INTO other_user_interests
            FROM user_profiles
            WHERE user_id = nearby_user_record.user_id AND profile_data ? 'interests'
            LIMIT 1;

            has_shared_interest := FALSE;
            IF current_user_interests IS NOT NULL AND other_user_interests IS NOT NULL THEN
                FOR interest_category IN SELECT jsonb_object_keys(current_user_interests) INTERSECT SELECT jsonb_object_keys(other_user_interests) LOOP
                    IF jsonb_array_length(current_user_interests->interest_category) > 0 AND jsonb_array_length(other_user_interests->interest_category) > 0 THEN
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
                INSERT INTO matches (user1_id, user2_id, matched_intent, match_type, created_at)
                VALUES (
                    LEAST(user_record.user_id, nearby_user_record.user_id),
                    GREATEST(user_record.user_id, nearby_user_record.user_id),
                    shared_intents[1], 'proximity', NOW()
                );
                total_matches_created := total_matches_created + 1;
            END IF;
        END LOOP;
    END LOOP;

    RETURN QUERY SELECT total_users_processed, total_matches_created, 'completed'::TEXT;
END;
$_$;

GRANT EXECUTE ON FUNCTION perform_continuous_user_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION perform_continuous_user_matching() TO anon;

-- ============================================================
-- UPDATE perform_event_matching (event matching)
-- ============================================================

CREATE OR REPLACE FUNCTION perform_event_matching(p_event_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $_$
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
    has_matching_sub_intent BOOLEAN := FALSE;
    shared_intent TEXT;
    user_a_sub_intents TEXT[];
    user_b_sub_intents TEXT[];
BEGIN
    SET search_path = 'public';

    FOR event_attendee IN
        SELECT DISTINCT ea.user_id
        FROM event_attendees ea
        WHERE ea.event_id = p_event_id
    LOOP
        attendee_a_id := event_attendee.user_id;

        SELECT active_modes, user_visibility_setting, shared_event_matching_enabled
        INTO user_a_data FROM users WHERE id = attendee_a_id;

        IF user_a_data IS NULL OR NOT user_a_data.shared_event_matching_enabled THEN
            CONTINUE;
        END IF;

        SELECT COALESCE(jsonb_object_agg(category, interests), '{}'::jsonb)
        INTO user_a_interests
        FROM (
            SELECT jsonb_object_keys(profile_data->'interests') as category,
                   profile_data->'interests'->jsonb_object_keys(profile_data->'interests') as interests
            FROM user_profiles WHERE user_id = attendee_a_id AND profile_data ? 'interests'
        ) interests_data;

        FOR other_attendee IN
            SELECT DISTINCT ea2.user_id FROM event_attendees ea2
            WHERE ea2.event_id = p_event_id AND ea2.user_id != attendee_a_id
        LOOP
            attendee_b_id := other_attendee.user_id;
            IF attendee_a_id >= attendee_b_id THEN CONTINUE; END IF;

            SELECT id INTO existing_match_id FROM matches
            WHERE (user1_id = attendee_a_id AND user2_id = attendee_b_id)
               OR (user1_id = attendee_b_id AND user2_id = attendee_a_id)
            LIMIT 1;
            IF existing_match_id IS NOT NULL THEN CONTINUE; END IF;

            SELECT active_modes, user_visibility_setting, shared_event_matching_enabled
            INTO user_b_data FROM users WHERE id = attendee_b_id;
            IF user_b_data IS NULL OR NOT user_b_data.shared_event_matching_enabled THEN
                CONTINUE;
            END IF;

            SELECT ARRAY(
                SELECT intent FROM unnest(user_a_data.active_modes) AS t(intent)
                WHERE intent = ANY(user_b_data.active_modes)
            ) INTO shared_intents;

            IF shared_intents IS NULL OR array_length(shared_intents, 1) IS NULL THEN
                CONTINUE;
            END IF;

            -- Check shared sub-intents per shared main intent
            has_matching_sub_intent := FALSE;
            <<sub_intent_loop>>
            FOREACH shared_intent IN ARRAY shared_intents LOOP
                user_a_sub_intents := ARRAY(
                    SELECT jsonb_array_elements_text(up.profile_data->'sub_intent')
                    FROM user_profiles up
                    WHERE up.user_id = attendee_a_id AND up.intent_type = shared_intent
                      AND up.profile_data ? 'sub_intent'
                );
                user_b_sub_intents := ARRAY(
                    SELECT jsonb_array_elements_text(up.profile_data->'sub_intent')
                    FROM user_profiles up
                    WHERE up.user_id = attendee_b_id AND up.intent_type = shared_intent
                      AND up.profile_data ? 'sub_intent'
                );

                IF array_length(user_a_sub_intents, 1) IS NULL
                   OR array_length(user_b_sub_intents, 1) IS NULL THEN
                    has_matching_sub_intent := TRUE;
                    EXIT sub_intent_loop;
                END IF;

                IF user_a_sub_intents && user_b_sub_intents THEN
                    has_matching_sub_intent := TRUE;
                    EXIT sub_intent_loop;
                END IF;
            END LOOP sub_intent_loop;

            IF NOT has_matching_sub_intent THEN
                CONTINUE;
            END IF;

            SELECT COALESCE(jsonb_object_agg(category, interests), '{}'::jsonb)
            INTO user_b_interests
            FROM (
                SELECT jsonb_object_keys(profile_data->'interests') as category,
                       profile_data->'interests'->jsonb_object_keys(profile_data->'interests') as interests
                FROM user_profiles WHERE user_id = attendee_b_id AND profile_data ? 'interests'
            ) interests_data;

            has_shared_interest := FALSE;
            FOR shared_interest_category IN SELECT jsonb_object_keys(user_a_interests) LOOP
                IF user_a_interests ? shared_interest_category AND user_b_interests ? shared_interest_category THEN
                    IF EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(user_a_interests->shared_interest_category) AS user_a_interest
                        WHERE user_a_interest = ANY(SELECT jsonb_array_elements_text(user_b_interests->shared_interest_category))
                    ) THEN
                        has_shared_interest := TRUE;
                        EXIT;
                    END IF;
                END IF;
            END LOOP;

            IF NOT has_shared_interest THEN CONTINUE; END IF;

            INSERT INTO matches (user1_id, user2_id, match_type, matched_intent, event_id, created_at)
            VALUES (attendee_a_id, attendee_b_id, 'event', shared_intents[1], p_event_id, NOW());
        END LOOP;
    END LOOP;
END;
$_$;
