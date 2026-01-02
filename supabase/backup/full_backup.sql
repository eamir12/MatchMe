


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";








ALTER SCHEMA "public" OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "hypopg" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "index_advisor" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."count_event_attendees"("event_id_param" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
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


ALTER FUNCTION "public"."count_event_attendees"("event_id_param" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."find_nearby_users"("current_user_id" "uuid", "current_lat" double precision, "current_lng" double precision, "radius_km" double precision) RETURNS TABLE("user_id" "uuid", "latitude" double precision, "longitude" double precision, "distance_km" double precision, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
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
    AND u.user_visibility_setting = TRUE AND (COALESCE(u.system_visibility_status,'visible') = 'visible') AND EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = u.id AND ua.is_online = TRUE)
    AND (earth_km * acos(
      cos(radians(current_lat)) * cos(radians(ul.latitude)) * cos(radians(ul.longitude) - radians(current_lng))
      + sin(radians(current_lat)) * sin(radians(ul.latitude))
    )) <= radius_km
  ORDER BY distance_km ASC;
END;
$$;


ALTER FUNCTION "public"."find_nearby_users"("current_user_id" "uuid", "current_lat" double precision, "current_lng" double precision, "radius_km" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."find_shared_events"("user1_id" "uuid", "user2_id" "uuid") RETURNS TABLE("event_id" "uuid", "event_name" "text", "start_time" timestamp with time zone)
    LANGUAGE "plpgsql"
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


ALTER FUNCTION "public"."find_shared_events"("user1_id" "uuid", "user2_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_nearby_users_count"("p_user_id" "uuid", "p_radius_km" integer DEFAULT 50) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
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


ALTER FUNCTION "public"."get_nearby_users_count"("p_user_id" "uuid", "p_radius_km" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_online_users_count"("p_user_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
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


ALTER FUNCTION "public"."get_online_users_count"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_potential_event_matches"("p_event_id" "uuid", "p_user_id" "uuid") RETURNS TABLE("suggested_user_id" "uuid", "suggested_user_name" "text", "shared_intents" "text"[])
    LANGUAGE "plpgsql" SECURITY DEFINER
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
        SELECT array_agg(intent) INTO shared_intents_list
        FROM unnest(current_user_data.active_modes) AS intent
        WHERE intent = ANY(other_user_data.active_modes);

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


ALTER FUNCTION "public"."get_potential_event_matches"("p_event_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_recent_chats"("p_user_id" "uuid") RETURNS TABLE("match_id" "uuid", "other_user_id" "uuid", "other_user_name" "text", "last_message_content" "text", "last_message_id" "uuid", "last_message_at" timestamp with time zone, "unread_count" integer, "match_created_at" timestamp with time zone, "event_id" "uuid", "event_name" "text", "event_link" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
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
        COALESCE(up.profile_data->>'fullName', 'Unknown User') AS other_user_name,
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


ALTER FUNCTION "public"."get_recent_chats"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_messages_as_read"("p_match_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    SET search_path = 'public';
    UPDATE chat_messages
    SET read_at = NOW()
    WHERE match_id = p_match_id
    AND sender_id != auth.uid();
END;
$$;


ALTER FUNCTION "public"."mark_messages_as_read"("p_match_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."perform_event_matching"("p_event_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
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
            SELECT array_agg(intent) INTO shared_intents
            FROM unnest(user_a_data.active_modes) AS intent
            WHERE intent = ANY(user_b_data.active_modes);

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


ALTER FUNCTION "public"."perform_event_matching"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."perform_event_matching_debug"("p_event_id" "uuid") RETURNS TABLE("debug_message" "text", "debug_data" "jsonb")
    LANGUAGE "plpgsql" SECURITY DEFINER
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
            SELECT array_agg(intent) INTO shared_intents
            FROM unnest(user_a_data.active_modes) AS intent
            WHERE intent = ANY(user_b_data.active_modes);

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


ALTER FUNCTION "public"."perform_event_matching_debug"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_users_on_auth_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.users (id, email, created_at, updated_at)
    VALUES (NEW.id, NEW.email, NEW.created_at, NEW.updated_at)
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE public.users SET
      email = NEW.email,
      updated_at = NEW.updated_at
    WHERE id = NEW.id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    DELETE FROM public.users WHERE id = OLD.id;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."sync_users_on_auth_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_perform_event_matching"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
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


ALTER FUNCTION "public"."trigger_perform_event_matching"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_set_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    SET search_path = 'public';
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_set_timestamp"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."app_gender_options" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "gender_key" "text" NOT NULL,
    "display_name_key" "text" NOT NULL,
    "sort_order" integer DEFAULT 0
);


ALTER TABLE "public"."app_gender_options" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_languages" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "language_code" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "text_direction" "text" DEFAULT 'LTR'::"text"
);


ALTER TABLE "public"."app_languages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_messages" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "match_id" "uuid",
    "sender_id" "uuid",
    "content_original" "text" NOT NULL,
    "content_translated" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "read_at" timestamp with time zone
);


ALTER TABLE "public"."chat_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_attendees" (
    "event_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_attendees" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_parse_results" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid",
    "file_path" "text" NOT NULL,
    "parsed_data" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_parse_results" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "event_name" "text" NOT NULL,
    "event_venue" "text",
    "start_time" timestamp with time zone NOT NULL,
    "end_time" timestamp with time zone NOT NULL,
    "event_link" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."intents" (
    "id" bigint NOT NULL,
    "key" "text" NOT NULL,
    "parent_id" bigint,
    "translation_key" "text",
    "sort_order" integer DEFAULT 100,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_social" boolean,
    "is_business" boolean
);


ALTER TABLE "public"."intents" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."intents_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."intents_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."intents_id_seq" OWNED BY "public"."intents"."id";



CREATE TABLE IF NOT EXISTS "public"."interests" (
    "id" bigint NOT NULL,
    "key" "text" NOT NULL,
    "translation_key" "text",
    "parent_id" bigint,
    "sort_order" integer DEFAULT 100,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_social" boolean,
    "is_business" boolean
);


ALTER TABLE "public"."interests" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."interests_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."interests_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."interests_id_seq" OWNED BY "public"."interests"."id";



CREATE TABLE IF NOT EXISTS "public"."matches" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user1_id" "uuid",
    "user2_id" "uuid",
    "matched_intent" "text",
    "match_type" "text",
    "event_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."matches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profile_edit_requests" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid",
    "requested_fields" "text"[],
    "message" "text",
    "status" "text" DEFAULT 'pending'::"text",
    "attachments" "jsonb" DEFAULT '[]'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."profile_edit_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."translations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "locale" "text" NOT NULL,
    "key" "text" NOT NULL,
    "value" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."translations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_intents" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "intent_id" bigint NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_intents" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."user_intents_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."user_intents_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."user_intents_id_seq" OWNED BY "public"."user_intents"."id";



CREATE TABLE IF NOT EXISTS "public"."user_interests" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "interest_id" bigint NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_interests" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."user_interests_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."user_interests_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."user_interests_id_seq" OWNED BY "public"."user_interests"."id";



CREATE TABLE IF NOT EXISTS "public"."user_invisibility_rules" (
    "user_id" "uuid" NOT NULL,
    "rules_data" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_invisibility_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_locations" (
    "user_id" "uuid" NOT NULL,
    "latitude" double precision NOT NULL,
    "longitude" double precision NOT NULL,
    "speed" double precision,
    "heading" double precision,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_locations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_profiles" (
    "user_id" "uuid" NOT NULL,
    "intent_type" "text" NOT NULL,
    "profile_data" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_profiles_backup" (
    "user_id" "uuid" NOT NULL,
    "intent_type" "text",
    "profile_data" "jsonb",
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone
);


ALTER TABLE "public"."user_profiles_backup" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_visibility_schedules" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid",
    "rrule" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_visibility_schedules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" NOT NULL,
    "email" "text",
    "name" "text",
    "avatar_url" "text",
    "date_of_birth" "date",
    "gender" "text",
    "preferred_language" "text",
    "active_modes" "text"[],
    "subscription_tier" "text" DEFAULT 'free'::"text",
    "is_profile_complete" boolean DEFAULT false,
    "match_radius_default" integer DEFAULT 50,
    "gps_interval_default" integer DEFAULT 300,
    "smart_gps_throttling_enabled" boolean DEFAULT true,
    "editable_profile_fields" "text"[],
    "bio" "text",
    "photos" "text"[],
    "user_visibility_setting" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "system_visibility_status" "text" DEFAULT 'visible'::"text",
    "languages_known" "jsonb" DEFAULT '{}'::"jsonb",
    "shared_event_matching_enabled" boolean DEFAULT false,
    "shared_movement_matching_enabled" boolean DEFAULT false
);


ALTER TABLE "public"."users" OWNER TO "postgres";


COMMENT ON COLUMN "public"."users"."languages_known" IS 'JSON object of languages known with skills (e.g., {"languages": ["en", "es"], "en": ["read", "speak"], "es": ["read"]})';



COMMENT ON COLUMN "public"."users"."shared_event_matching_enabled" IS 'Enables matching with users attending the same events';



COMMENT ON COLUMN "public"."users"."shared_movement_matching_enabled" IS 'Enables matching with users traveling in similar directions and speeds';



ALTER TABLE ONLY "public"."intents" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."intents_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."interests" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."interests_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."user_intents" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."user_intents_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."user_interests" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."user_interests_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."app_gender_options"
    ADD CONSTRAINT "app_gender_options_gender_key_key" UNIQUE ("gender_key");



ALTER TABLE ONLY "public"."app_gender_options"
    ADD CONSTRAINT "app_gender_options_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_languages"
    ADD CONSTRAINT "app_languages_language_code_key" UNIQUE ("language_code");



ALTER TABLE ONLY "public"."app_languages"
    ADD CONSTRAINT "app_languages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_messages"
    ADD CONSTRAINT "chat_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_attendees"
    ADD CONSTRAINT "event_attendees_pkey" PRIMARY KEY ("event_id", "user_id");



ALTER TABLE ONLY "public"."event_parse_results"
    ADD CONSTRAINT "event_parse_results_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."intents"
    ADD CONSTRAINT "intents_key_key" UNIQUE ("key");



ALTER TABLE ONLY "public"."intents"
    ADD CONSTRAINT "intents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."interests"
    ADD CONSTRAINT "interests_key_key" UNIQUE ("key");



ALTER TABLE ONLY "public"."interests"
    ADD CONSTRAINT "interests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_user_a_id_user_b_id_key" UNIQUE ("user1_id", "user2_id");



ALTER TABLE ONLY "public"."profile_edit_requests"
    ADD CONSTRAINT "profile_edit_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."translations"
    ADD CONSTRAINT "translations_locale_key_key" UNIQUE ("locale", "key");



ALTER TABLE ONLY "public"."translations"
    ADD CONSTRAINT "translations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_intents"
    ADD CONSTRAINT "user_intents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_intents"
    ADD CONSTRAINT "user_intents_user_id_intent_id_key" UNIQUE ("user_id", "intent_id");



ALTER TABLE ONLY "public"."user_interests"
    ADD CONSTRAINT "user_interests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_interests"
    ADD CONSTRAINT "user_interests_user_id_interest_id_key" UNIQUE ("user_id", "interest_id");



ALTER TABLE ONLY "public"."user_invisibility_rules"
    ADD CONSTRAINT "user_invisibility_rules_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_locations"
    ADD CONSTRAINT "user_locations_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_profiles_backup"
    ADD CONSTRAINT "user_profiles_backup_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_pkey" PRIMARY KEY ("user_id", "intent_type");



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_user_id_intent_type_key" UNIQUE ("user_id", "intent_type");



ALTER TABLE ONLY "public"."user_visibility_schedules"
    ADD CONSTRAINT "user_visibility_schedules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_chat_messages_created_at" ON "public"."chat_messages" USING "btree" ("created_at");



CREATE INDEX "idx_chat_messages_match_id" ON "public"."chat_messages" USING "btree" ("match_id");



CREATE INDEX "idx_chat_messages_match_id_created_at" ON "public"."chat_messages" USING "btree" ("match_id", "created_at");



CREATE INDEX "idx_chat_messages_sender_id" ON "public"."chat_messages" USING "btree" ("sender_id");



CREATE INDEX "idx_event_attendees_event_id" ON "public"."event_attendees" USING "btree" ("event_id");



CREATE INDEX "idx_event_attendees_user_id" ON "public"."event_attendees" USING "btree" ("user_id");



CREATE INDEX "idx_event_parse_results_user_id" ON "public"."event_parse_results" USING "btree" ("user_id");



CREATE INDEX "idx_intents_parent_id" ON "public"."intents" USING "btree" ("parent_id");



CREATE INDEX "idx_interests_parent_id" ON "public"."interests" USING "btree" ("parent_id");



CREATE INDEX "idx_matches_user_a_id" ON "public"."matches" USING "btree" ("user1_id");



CREATE INDEX "idx_matches_user_b_id" ON "public"."matches" USING "btree" ("user2_id");



CREATE INDEX "idx_profile_edit_requests_user_id" ON "public"."profile_edit_requests" USING "btree" ("user_id");



CREATE INDEX "idx_user_intents_intent_id" ON "public"."user_intents" USING "btree" ("intent_id");



CREATE INDEX "idx_user_interests_interest_id" ON "public"."user_interests" USING "btree" ("interest_id");



CREATE INDEX "idx_user_visibility_schedules_user_id" ON "public"."user_visibility_schedules" USING "btree" ("user_id");



CREATE INDEX "intents_key_idx" ON "public"."intents" USING "btree" ("key");



CREATE INDEX "interests_key_idx" ON "public"."interests" USING "btree" ("key");



CREATE UNIQUE INDEX "translations_locale_key_uq" ON "public"."translations" USING "btree" ("locale", "key");



CREATE OR REPLACE TRIGGER "intents_set_timestamp" BEFORE UPDATE ON "public"."intents" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_set_timestamp"();



CREATE OR REPLACE TRIGGER "interests_set_timestamp" BEFORE UPDATE ON "public"."interests" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_set_timestamp"();



CREATE OR REPLACE TRIGGER "trigger_event_matching" AFTER INSERT ON "public"."event_attendees" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_perform_event_matching"();



ALTER TABLE ONLY "public"."chat_messages"
    ADD CONSTRAINT "chat_messages_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."matches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chat_messages"
    ADD CONSTRAINT "chat_messages_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_attendees"
    ADD CONSTRAINT "event_attendees_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_attendees"
    ADD CONSTRAINT "event_attendees_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_parse_results"
    ADD CONSTRAINT "event_parse_results_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."intents"
    ADD CONSTRAINT "intents_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."intents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."interests"
    ADD CONSTRAINT "interests_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."interests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_user_a_id_fkey" FOREIGN KEY ("user1_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_user_b_id_fkey" FOREIGN KEY ("user2_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profile_edit_requests"
    ADD CONSTRAINT "profile_edit_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_intents"
    ADD CONSTRAINT "user_intents_intent_id_fkey" FOREIGN KEY ("intent_id") REFERENCES "public"."intents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_interests"
    ADD CONSTRAINT "user_interests_interest_id_fkey" FOREIGN KEY ("interest_id") REFERENCES "public"."interests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_invisibility_rules"
    ADD CONSTRAINT "user_invisibility_rules_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_locations"
    ADD CONSTRAINT "user_locations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_visibility_schedules"
    ADD CONSTRAINT "user_visibility_schedules_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Anyone can view event parse results" ON "public"."event_parse_results" FOR SELECT USING (true);



CREATE POLICY "Anyone can view gender options" ON "public"."app_gender_options" FOR SELECT USING (true);



CREATE POLICY "Anyone can view languages" ON "public"."app_languages" FOR SELECT USING (true);



CREATE POLICY "Anyone can view translations" ON "public"."translations" FOR SELECT USING (true);



CREATE POLICY "Authenticated users can create events" ON "public"."events" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") IS NOT NULL));



CREATE POLICY "Enable delete for service role" ON "public"."chat_messages" FOR DELETE USING (("match_id" IN ( SELECT "matches"."id"
   FROM "public"."matches"
  WHERE (("matches"."user1_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("matches"."user2_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Enable delete for service role" ON "public"."matches" FOR DELETE USING (("auth"."role"() = 'service_role'::"text"));



CREATE POLICY "Enable delete for service role" ON "public"."user_profiles" FOR DELETE USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Enable delete for service role" ON "public"."users" FOR DELETE USING (("id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Match engine can create matches" ON "public"."matches" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Service role full access" ON "public"."user_locations" USING (("auth"."role"() = 'service_role'::"text"));



CREATE POLICY "Users can create requests" ON "public"."profile_edit_requests" FOR INSERT WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can delete their own event attendance" ON "public"."event_attendees" FOR DELETE USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can delete their own matches" ON "public"."matches" FOR DELETE TO "authenticated" USING ((("user1_id" = "auth"."uid"()) OR ("user2_id" = "auth"."uid"())));



CREATE POLICY "Users can insert own profile" ON "public"."user_profiles" FOR INSERT WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can insert own profile" ON "public"."users" FOR INSERT TO "authenticated" WITH CHECK (("id" = "auth"."uid"()));



CREATE POLICY "Users can insert their own backup profile" ON "public"."user_profiles_backup" FOR INSERT WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can manage own location" ON "public"."user_locations" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can send messages in their matches" ON "public"."chat_messages" FOR INSERT WITH CHECK ((("sender_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("match_id" IN ( SELECT "matches"."id"
   FROM "public"."matches"
  WHERE (("matches"."user1_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("matches"."user2_id" = ( SELECT "auth"."uid"() AS "uid")))))));



CREATE POLICY "Users can update own profile" ON "public"."user_profiles" FOR UPDATE USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can update own profile" ON "public"."users" FOR UPDATE TO "authenticated" USING (("id" = "auth"."uid"()));



CREATE POLICY "Users can update their own backup profile" ON "public"."user_profiles_backup" FOR UPDATE USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can update their own event attendance" ON "public"."event_attendees" FOR UPDATE USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can update their own matches" ON "public"."matches" FOR UPDATE TO "authenticated" USING ((("user1_id" = "auth"."uid"()) OR ("user2_id" = "auth"."uid"()))) WITH CHECK ((("user1_id" = "auth"."uid"()) OR ("user2_id" = "auth"."uid"())));



CREATE POLICY "Users can update their own profile" ON "public"."users" FOR UPDATE USING (("id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can update their own visibility schedules" ON "public"."user_visibility_schedules" FOR UPDATE USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can upsert their own invisibility rules" ON "public"."user_invisibility_rules" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can view all profiles" ON "public"."user_profiles" FOR SELECT USING (true);



CREATE POLICY "Users can view events" ON "public"."events" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") IS NOT NULL));



CREATE POLICY "Users can view messages in their matches" ON "public"."chat_messages" FOR SELECT USING (("match_id" IN ( SELECT "matches"."id"
   FROM "public"."matches"
  WHERE (("matches"."user1_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("matches"."user2_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Users can view other users profiles" ON "public"."users" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Users can view their matches" ON "public"."matches" FOR SELECT USING ((("user1_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("user2_id" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "Users can view their own attendance" ON "public"."event_attendees" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can view their own backup profile" ON "public"."user_profiles_backup" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can view their own matches" ON "public"."matches" FOR SELECT TO "authenticated" USING ((("user1_id" = "auth"."uid"()) OR ("user2_id" = "auth"."uid"())));



CREATE POLICY "Users can view their own profile" ON "public"."users" FOR SELECT USING (("id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can view their own requests" ON "public"."profile_edit_requests" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users own attendance only" ON "public"."event_attendees" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."app_gender_options" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_languages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."chat_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_attendees" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_parse_results" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."intents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "intents_service_write" ON "public"."intents" USING ((( SELECT "auth"."uid"() AS "uid") IS NOT NULL));



ALTER TABLE "public"."interests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "interests_service_write" ON "public"."interests" USING ((( SELECT "auth"."uid"() AS "uid") IS NOT NULL));



ALTER TABLE "public"."matches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profile_edit_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."translations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_intents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_intents_owner" ON "public"."user_intents" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "user_intents_service" ON "public"."user_intents" USING ((( SELECT "auth"."uid"() AS "uid") IS NOT NULL));



ALTER TABLE "public"."user_interests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_interests_owner" ON "public"."user_interests" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "user_interests_service" ON "public"."user_interests" USING ((( SELECT "auth"."uid"() AS "uid") IS NOT NULL));



ALTER TABLE "public"."user_invisibility_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_locations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_profiles_backup" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_visibility_schedules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."chat_messages";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."matches";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."user_locations";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."users";






REVOKE USAGE ON SCHEMA "public" FROM PUBLIC;
GRANT ALL ON SCHEMA "public" TO "anon";
GRANT ALL ON SCHEMA "public" TO "authenticated";
GRANT ALL ON SCHEMA "public" TO "service_role";





























































































































































































GRANT ALL ON FUNCTION "public"."count_event_attendees"("event_id_param" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."count_event_attendees"("event_id_param" "uuid") TO "anon";



GRANT ALL ON FUNCTION "public"."find_nearby_users"("current_user_id" "uuid", "current_lat" double precision, "current_lng" double precision, "radius_km" double precision) TO "authenticated";



GRANT ALL ON FUNCTION "public"."find_shared_events"("user1_id" "uuid", "user2_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."find_shared_events"("user1_id" "uuid", "user2_id" "uuid") TO "anon";



GRANT ALL ON FUNCTION "public"."get_nearby_users_count"("p_user_id" "uuid", "p_radius_km" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_nearby_users_count"("p_user_id" "uuid", "p_radius_km" integer) TO "anon";



GRANT ALL ON FUNCTION "public"."get_online_users_count"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_online_users_count"("p_user_id" "uuid") TO "anon";



GRANT ALL ON FUNCTION "public"."get_potential_event_matches"("p_event_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_potential_event_matches"("p_event_id" "uuid", "p_user_id" "uuid") TO "anon";



GRANT ALL ON FUNCTION "public"."get_recent_chats"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_recent_chats"("p_user_id" "uuid") TO "anon";



GRANT ALL ON FUNCTION "public"."mark_messages_as_read"("p_match_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_messages_as_read"("p_match_id" "uuid") TO "anon";



GRANT ALL ON FUNCTION "public"."perform_event_matching"("p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."perform_event_matching"("p_event_id" "uuid") TO "anon";



GRANT ALL ON FUNCTION "public"."perform_event_matching_debug"("p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."perform_event_matching_debug"("p_event_id" "uuid") TO "anon";



GRANT ALL ON FUNCTION "public"."trigger_perform_event_matching"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_perform_event_matching"() TO "anon";



GRANT ALL ON FUNCTION "public"."trigger_set_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_set_timestamp"() TO "anon";
























GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."app_gender_options" TO "authenticated";
GRANT SELECT ON TABLE "public"."app_gender_options" TO "anon";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."app_languages" TO "authenticated";
GRANT SELECT ON TABLE "public"."app_languages" TO "anon";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."chat_messages" TO "authenticated";
GRANT SELECT ON TABLE "public"."chat_messages" TO "anon";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."event_attendees" TO "authenticated";
GRANT SELECT ON TABLE "public"."event_attendees" TO "anon";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."event_parse_results" TO "authenticated";
GRANT SELECT ON TABLE "public"."event_parse_results" TO "anon";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."events" TO "authenticated";
GRANT SELECT ON TABLE "public"."events" TO "anon";



GRANT SELECT ON TABLE "public"."intents" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."intents" TO "authenticated";
GRANT ALL ON TABLE "public"."intents" TO "service_role";



GRANT SELECT ON TABLE "public"."interests" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."interests" TO "authenticated";
GRANT ALL ON TABLE "public"."interests" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."matches" TO "authenticated";
GRANT SELECT ON TABLE "public"."matches" TO "anon";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."profile_edit_requests" TO "authenticated";
GRANT SELECT ON TABLE "public"."profile_edit_requests" TO "anon";



GRANT SELECT ON TABLE "public"."translations" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."translations" TO "authenticated";



GRANT SELECT ON TABLE "public"."user_intents" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."user_intents" TO "authenticated";
GRANT ALL ON TABLE "public"."user_intents" TO "service_role";



GRANT SELECT ON TABLE "public"."user_interests" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."user_interests" TO "authenticated";
GRANT ALL ON TABLE "public"."user_interests" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."user_invisibility_rules" TO "authenticated";
GRANT SELECT ON TABLE "public"."user_invisibility_rules" TO "anon";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."user_locations" TO "authenticated";
GRANT SELECT ON TABLE "public"."user_locations" TO "anon";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."user_profiles" TO "authenticated";
GRANT SELECT ON TABLE "public"."user_profiles" TO "anon";



GRANT SELECT ON TABLE "public"."user_profiles_backup" TO "anon";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."user_profiles_backup" TO "authenticated";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."user_visibility_schedules" TO "authenticated";
GRANT SELECT ON TABLE "public"."user_visibility_schedules" TO "anon";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."users" TO "authenticated";
GRANT SELECT ON TABLE "public"."users" TO "anon";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO "authenticated";




























