BEGIN;

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

        IF user_a_data IS NULL
           OR NOT user_a_data.shared_event_matching_enabled
           OR user_a_data.active_modes IS NULL
           OR array_length(user_a_data.active_modes, 1) IS NULL THEN
            CONTINUE;
        END IF;

        SELECT COALESCE(jsonb_object_agg(category, interests), '{}'::jsonb)
        INTO user_a_interests
        FROM (
            SELECT
                interest_entry.key AS category,
                interest_entry.value AS interests
            FROM user_profiles up
            CROSS JOIN LATERAL jsonb_each(up.profile_data->'interests') AS interest_entry(key, value)
            WHERE up.user_id = attendee_a_id
              AND up.profile_data ? 'interests'
              AND jsonb_typeof(up.profile_data->'interests') = 'object'
              AND jsonb_typeof(interest_entry.value) = 'array'
        ) interests_data;

        FOR other_attendee IN
            SELECT DISTINCT ea2.user_id FROM event_attendees ea2 WHERE ea2.event_id = p_event_id AND ea2.user_id != attendee_a_id
        LOOP
            attendee_b_id := other_attendee.user_id;

            IF attendee_a_id >= attendee_b_id THEN
                CONTINUE;
            END IF;

            IF EXISTS (
                SELECT 1 FROM public.unmatched_pairs up
                WHERE up.user1_id = attendee_a_id AND up.user2_id = attendee_b_id
            ) THEN
                CONTINUE;
            END IF;

            SELECT id INTO existing_match_id
            FROM matches
            WHERE (user1_id = attendee_a_id AND user2_id = attendee_b_id)
               OR (user1_id = attendee_b_id AND user2_id = attendee_a_id)
            LIMIT 1;

            IF existing_match_id IS NOT NULL THEN
                CONTINUE;
            END IF;

            SELECT active_modes, COALESCE(user_visibility_setting,false) as user_visibility_setting, shared_event_matching_enabled
            INTO user_b_data
            FROM users
            WHERE id = attendee_b_id;

            IF user_b_data IS NULL
               OR NOT user_b_data.shared_event_matching_enabled
               OR user_b_data.active_modes IS NULL
               OR array_length(user_b_data.active_modes, 1) IS NULL THEN
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
                    interest_entry.key AS category,
                    interest_entry.value AS interests
                FROM user_profiles up
                CROSS JOIN LATERAL jsonb_each(up.profile_data->'interests') AS interest_entry(key, value)
                WHERE up.user_id = attendee_b_id
                  AND up.profile_data ? 'interests'
                  AND jsonb_typeof(up.profile_data->'interests') = 'object'
                  AND jsonb_typeof(interest_entry.value) = 'array'
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

COMMIT;
