-- Migration: Re-deploy core matching & location functions (idempotent, Supabase-compatible)
-- Date: 2026-01-01
-- Purpose: Ensure all compiled DB functions are updated to the latest, tested implementations
-- Notes: Uses CREATE OR REPLACE FUNCTION, idempotent TRIGGER DROP/CREATE, and grants. No explicit transactions.

--------------------------------------------------------------------------------
-- find_nearby_users: returns nearby visible & online users within radius_km
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.find_nearby_users(
    current_user_id uuid,
    current_lat double precision,
    current_lng double precision,
    radius_km double precision
)
RETURNS TABLE(user_id uuid, latitude double precision, longitude double precision, distance_km double precision, updated_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  earth_km CONSTANT DOUBLE PRECISION := 6371.0;
BEGIN
  RETURN QUERY
  SELECT
    ul.user_id,
    ul.latitude,
    ul.longitude,
    (earth_km * acos(
      cos(radians(current_lat)) * cos(radians(ul.latitude)) * cos(radians(ul.longitude) - radians(current_lng))
      + sin(radians(current_lat)) * sin(radians(ul.latitude))
    ))::DOUBLE PRECISION AS distance_km,
    ul.updated_at
  FROM public.user_locations ul
  JOIN public.users u ON u.id = ul.user_id
  WHERE ul.user_id IS NOT NULL
    AND ul.user_id <> current_user_id
    AND COALESCE(u.user_visibility_setting, FALSE) = TRUE
    AND COALESCE(u.system_visibility_status, 'visible') = 'visible'
    AND EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE)
    AND (earth_km * acos(
      cos(radians(current_lat)) * cos(radians(ul.latitude)) * cos(radians(ul.longitude) - radians(current_lng))
      + sin(radians(current_lat)) * sin(radians(ul.latitude))
    )) <= radius_km
  ORDER BY distance_km ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.find_nearby_users(uuid, double precision, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.find_nearby_users(uuid, double precision, double precision, double precision) TO anon;

--------------------------------------------------------------------------------
-- get_potential_event_matches: returns potential event matches for a user
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_potential_event_matches(p_event_id uuid, p_user_id uuid)
RETURNS TABLE(suggested_user_id uuid, suggested_user_name text, shared_intents text[])
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
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

    SELECT active_modes, user_visibility_setting, shared_event_matching_enabled
    INTO current_user_data
    FROM users
    WHERE id = p_user_id;

    IF current_user_data IS NULL OR NOT current_user_data.shared_event_matching_enabled THEN
        RETURN;
    END IF;

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

    FOR other_attendee IN
        SELECT DISTINCT ea.user_id, public.mask_full_name(up.profile_data->>'fullName') as user_name
        FROM event_attendees ea
        LEFT JOIN user_profiles up ON ea.user_id = up.user_id
        WHERE ea.event_id = p_event_id
        AND ea.user_id != p_user_id
    LOOP
        SELECT active_modes, user_visibility_setting, shared_event_matching_enabled
        INTO other_user_data
        FROM users
        WHERE id = other_attendee.user_id;

        IF other_user_data IS NULL OR NOT other_user_data.shared_event_matching_enabled THEN
            CONTINUE;
        END IF;

        SELECT ARRAY(
            SELECT intent
            FROM unnest(current_user_data.active_modes) AS t(intent)
            WHERE intent = ANY(other_user_data.active_modes)
        ) INTO shared_intents_list;

        IF shared_intents_list IS NULL OR array_length(shared_intents_list, 1) IS NULL THEN
            CONTINUE;
        END IF;

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

        has_shared_interest := FALSE;
        FOR shared_interest_category IN
            SELECT jsonb_object_keys(current_user_interests)
        LOOP
            IF current_user_interests ? shared_interest_category AND other_user_interests ? shared_interest_category THEN
                IF EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements_text(current_user_interests->shared_interest_category) as current_user_interest
                    WHERE current_user_interest = ANY(
                        SELECT jsonb_array_elements_text(other_user_interests->shared_interest_category)
                    )
                ) THEN
                    has_shared_interest := TRUE;
                    EXIT;
                END IF;
            END IF;
        END LOOP;

        IF NOT has_shared_interest THEN
            CONTINUE;
        END IF;

        SELECT COUNT(*) INTO existing_match_count
        FROM matches
        WHERE (user1_id = p_user_id AND user2_id = other_attendee.user_id)
           OR (user1_id = other_attendee.user_id AND user2_id = p_user_id);

        IF existing_match_count > 0 THEN
            CONTINUE;
        END IF;

        RETURN QUERY SELECT
            other_attendee.user_id,
            COALESCE(other_attendee.user_name, 'Unknown User'),
            shared_intents_list;
    END LOOP;

    RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_potential_event_matches(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_potential_event_matches(uuid, uuid) TO anon;

--------------------------------------------------------------------------------
-- perform_event_matching: create matches for attendees of an event (preference-aware)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.perform_event_matching(p_event_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    event_attendee RECORD;
    other_attendee RECORD;
    attendee_a_id uuid;
    attendee_b_id uuid;
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

    FOR event_attendee IN
        SELECT DISTINCT ea.user_id FROM event_attendees ea WHERE ea.event_id = p_event_id
    LOOP
        attendee_a_id := event_attendee.user_id;

        SELECT active_modes, COALESCE(user_visibility_setting,false) as user_visibility_setting, shared_event_matching_enabled
        INTO user_a_data
        FROM users
        WHERE id = attendee_a_id;

        IF user_a_data IS NULL OR NOT user_a_data.shared_event_matching_enabled THEN
            CONTINUE;
        END IF;

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

        FOR other_attendee IN
            SELECT DISTINCT ea2.user_id FROM event_attendees ea2 WHERE ea2.event_id = p_event_id AND ea2.user_id != attendee_a_id
        LOOP
            attendee_b_id := other_attendee.user_id;

            IF attendee_a_id >= attendee_b_id THEN
                CONTINUE;
            END IF;

            SELECT id INTO existing_match_id
            FROM matches
            WHERE (user1_id = attendee_a_id AND user2_id = attendee_b_id)
               OR (user1_id = attendee_b_id AND user2_id = attendee_a_id)
            LIMIT 1;

            IF existing_match_id IS NOT NULL THEN
                CONTINUE; -- Match already exists
            END IF;

            SELECT active_modes, COALESCE(user_visibility_setting,false) as user_visibility_setting, shared_event_matching_enabled
            INTO user_b_data
            FROM users
            WHERE id = attendee_b_id;

            IF user_b_data IS NULL OR NOT user_b_data.shared_event_matching_enabled THEN
                CONTINUE;
            END IF;

            SELECT ARRAY(
                SELECT intent
                FROM unnest(user_a_data.active_modes) AS t(intent)
                WHERE intent = ANY(user_b_data.active_modes)
            ) INTO shared_intents;

            IF shared_intents IS NULL OR array_length(shared_intents, 1) IS NULL THEN
                CONTINUE;
            END IF;

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

            has_shared_interest := FALSE;
            FOR shared_interest_category IN SELECT jsonb_object_keys(user_a_interests) LOOP
                IF user_a_interests ? shared_interest_category AND user_b_interests ? shared_interest_category THEN
                    IF EXISTS (
                        SELECT 1
                        FROM jsonb_array_elements_text(user_a_interests->shared_interest_category) AS user_a_interest
                        WHERE user_a_interest = ANY(SELECT jsonb_array_elements_text(user_b_interests->shared_interest_category))
                    ) THEN
                        has_shared_interest := TRUE;
                        EXIT;
                    END IF;
                END IF;
            END LOOP;

            IF NOT has_shared_interest THEN
                CONTINUE;
            END IF;

            INSERT INTO matches (user1_id, user2_id, match_type, matched_intent, event_id, created_at)
            VALUES (
                attendee_a_id,
                attendee_b_id,
                'event',
                shared_intents[1],
                p_event_id,
                NOW()
            );
        END LOOP;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.perform_event_matching(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_event_matching(uuid) TO anon;

--------------------------------------------------------------------------------
-- perform_continuous_user_matching: periodic proximity-based matching
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.perform_continuous_user_matching()
RETURNS TABLE (users_processed INTEGER, matches_created INTEGER, status TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    user_record RECORD;
    nearby_user_record RECORD;
    current_user_intents TEXT[];
    current_user_interests JSONB;
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
    overall_gender_match BOOLEAN;
    overall_age_match BOOLEAN;
    strict_enforcement BOOLEAN;
BEGIN
    SET search_path = 'public';

    FOR user_record IN
        SELECT
            ul.user_id,
            ul.latitude,
            ul.longitude,
            u.active_modes,
            u.match_radius_default
        FROM user_locations ul
        INNER JOIN users u ON ul.user_id = u.id
        WHERE (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE)
          AND COALESCE(u.user_visibility_setting,false) = TRUE
          AND COALESCE(u.system_visibility_status,'visible') = 'visible')
        AND ul.updated_at >= NOW() - INTERVAL '5 minutes'
        ORDER BY ul.updated_at DESC
    LOOP
        total_users_processed := total_users_processed + 1;

        SELECT
            gender,
            date_of_birth,
            gender_preferences,
            age_preferences,
            strict_gender_age_enforcement
        INTO current_user_profile
        FROM users
        WHERE id = user_record.user_id;

        IF current_user_profile.date_of_birth IS NOT NULL THEN
            current_user_age := EXTRACT(YEAR FROM AGE(current_user_profile.date_of_birth));
        END IF;

        SELECT profile_data->'interests' INTO current_user_interests
        FROM user_profiles
        WHERE user_id = user_record.user_id AND profile_data ? 'interests'
        LIMIT 1;

        current_user_intents := user_record.active_modes;

        FOR nearby_user_record IN
            SELECT * FROM find_nearby_users(
                user_record.user_id,
                user_record.latitude,
                user_record.longitude,
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

            IF other_user_profile.date_of_birth IS NOT NULL THEN
                other_user_age := EXTRACT(YEAR FROM AGE(other_user_profile.date_of_birth));
            END IF;

            SELECT ARRAY(
                SELECT intent_item
                FROM unnest(current_user_intents) as t(intent_item)
                WHERE intent_item = ANY(other_user_profile.active_modes)
            ) INTO shared_intents;

            IF array_length(shared_intents, 1) IS NULL OR array_length(shared_intents, 1) = 0 THEN
                CONTINUE;
            END IF;

            has_shared_interest := FALSE;
            IF current_user_interests IS NOT NULL THEN
                SELECT profile_data->'interests' INTO other_user_interests
                FROM user_profiles WHERE user_id = nearby_user_record.user_id AND profile_data ? 'interests' LIMIT 1;

                IF other_user_interests IS NOT NULL THEN
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
            END IF;

            IF has_shared_interest THEN
                INSERT INTO matches (
                    user1_id, user2_id, matched_intent, match_type, created_at
                ) VALUES (
                    LEAST(user_record.user_id, nearby_user_record.user_id),
                    GREATEST(user_record.user_id, nearby_user_record.user_id),
                    shared_intents[1],
                    'proximity',
                    NOW()
                );

                total_matches_created := total_matches_created + 1;
            END IF;
        END LOOP;
    END LOOP;

    RETURN QUERY SELECT total_users_processed, total_matches_created, 'completed'::TEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION public.perform_continuous_user_matching() TO anon;

--------------------------------------------------------------------------------
-- update_user_location & update_user_activity / set_user_offline
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_user_activity(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    INSERT INTO user_activity (user_id, last_activity, is_online, updated_at)
    VALUES (p_user_id, NOW(), true, NOW())
    ON CONFLICT (user_id) DO UPDATE SET last_activity = NOW(), is_online = true, updated_at = NOW();
END;
$$;
GRANT EXECUTE ON FUNCTION public.update_user_activity(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_activity(uuid) TO anon;

CREATE OR REPLACE FUNCTION public.set_user_offline(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    UPDATE user_activity SET is_online = false, updated_at = NOW() WHERE user_id = p_user_id;
    INSERT INTO user_activity (user_id, last_activity, is_online, updated_at)
    SELECT p_user_id, NOW(), false, NOW() WHERE NOT EXISTS (SELECT 1 FROM user_activity WHERE user_id = p_user_id);
END;
$$;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_user_offline(uuid) TO anon;

CREATE OR REPLACE FUNCTION public.update_user_location(
    p_user_id uuid,
    p_latitude double precision,
    p_longitude double precision,
    p_speed double precision DEFAULT NULL,
    p_heading double precision DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    INSERT INTO user_locations (user_id, latitude, longitude, speed, heading, updated_at)
    VALUES (p_user_id, p_latitude, p_longitude, p_speed, p_heading, NOW())
    ON CONFLICT (user_id) DO UPDATE SET latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude, speed = EXCLUDED.speed, heading = EXCLUDED.heading, updated_at = NOW();

    PERFORM public.update_user_activity(p_user_id);
END;
$$;
GRANT EXECUTE ON FUNCTION public.update_user_location(uuid, double precision, double precision, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_location(uuid, double precision, double precision, double precision, double precision) TO anon;

--------------------------------------------------------------------------------
-- Triggers: user location and event attendee triggers (idempotent)
--------------------------------------------------------------------------------
-- trigger_perform_user_location_matching: calls perform_continuous_user_matching
CREATE OR REPLACE FUNCTION public.trigger_perform_user_location_matching()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        PERFORM public.perform_continuous_user_matching();
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_user_location_matching ON user_locations;
CREATE TRIGGER trigger_user_location_matching
    AFTER INSERT OR UPDATE ON user_locations
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.trigger_perform_user_location_matching();

GRANT EXECUTE ON FUNCTION public.trigger_perform_user_location_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trigger_perform_user_location_matching() TO anon;

-- trigger_perform_event_matching: calls perform_event_matching when a user joins an event
CREATE OR REPLACE FUNCTION public.trigger_perform_event_matching()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    SET search_path = 'public';
    IF TG_OP = 'INSERT' THEN
        PERFORM public.perform_event_matching(NEW.event_id);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_event_matching ON event_attendees;
CREATE TRIGGER trigger_event_matching
    AFTER INSERT ON event_attendees
    FOR EACH ROW
    EXECUTE FUNCTION public.trigger_perform_event_matching();

GRANT EXECUTE ON FUNCTION public.trigger_perform_event_matching() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trigger_perform_event_matching() TO anon;

--------------------------------------------------------------------------------
-- End of migration
--------------------------------------------------------------------------------
