BEGIN;

CREATE TABLE IF NOT EXISTS public.unmatched_pairs (
  user1_id uuid NOT NULL,
  user2_id uuid NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  match_type text,
  match_id uuid,
  PRIMARY KEY (user1_id, user2_id)
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'unmatched_pairs_ordered_users') THEN
    ALTER TABLE public.unmatched_pairs
      ADD CONSTRAINT unmatched_pairs_ordered_users CHECK (user1_id < user2_id);
  END IF;
END$$;

DROP FUNCTION IF EXISTS public.unmatch_from_system_match(uuid);
CREATE OR REPLACE FUNCTION public.unmatch_from_system_match(p_match_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_user1_id uuid;
  v_user2_id uuid;
  v_match_type text;
  v_a uuid;
  v_b uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT m.user1_id, m.user2_id, m.match_type
  INTO v_user1_id, v_user2_id, v_match_type
  FROM public.matches m
  WHERE m.id = p_match_id;

  IF v_user1_id IS NULL OR v_user2_id IS NULL THEN
    RAISE EXCEPTION 'Match not found';
  END IF;

  IF v_user_id <> v_user1_id AND v_user_id <> v_user2_id THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  IF v_match_type NOT IN ('proximity','event','co_motion') THEN
    RAISE EXCEPTION 'Match type not allowed';
  END IF;

  v_a := LEAST(v_user1_id, v_user2_id);
  v_b := GREATEST(v_user1_id, v_user2_id);

  INSERT INTO public.unmatched_pairs (user1_id, user2_id, created_by, created_at, match_type, match_id)
  VALUES (v_a, v_b, v_user_id, now(), v_match_type, p_match_id)
  ON CONFLICT (user1_id, user2_id) DO UPDATE
  SET
    created_by = EXCLUDED.created_by,
    created_at = GREATEST(unmatched_pairs.created_at, EXCLUDED.created_at),
    match_type = COALESCE(unmatched_pairs.match_type, EXCLUDED.match_type),
    match_id = COALESCE(unmatched_pairs.match_id, EXCLUDED.match_id);

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='chats') THEN
    EXECUTE 'DELETE FROM public.chats WHERE match_id = $1' USING p_match_id;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='user_recent_matches') THEN
    EXECUTE 'DELETE FROM public.user_recent_matches WHERE match_id = $1' USING p_match_id;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='user_recent_chats') THEN
    EXECUTE 'DELETE FROM public.user_recent_chats WHERE match_id = $1' USING p_match_id;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='chat_messages') THEN
    EXECUTE 'DELETE FROM public.chat_messages WHERE match_id = $1' USING p_match_id;
  END IF;
  EXECUTE 'DELETE FROM public.matches WHERE id = $1' USING p_match_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.unmatch_from_system_match(uuid) TO authenticated;

DROP FUNCTION IF EXISTS public.cleanup_expired_matches(timestamptz, int);
CREATE OR REPLACE FUNCTION public.cleanup_expired_matches(p_cutoff timestamptz, p_limit int DEFAULT 500)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted int := 0;
BEGIN
  WITH locked AS (
    SELECT m.id, m.user1_id, m.user2_id, m.match_type
    FROM public.matches m
    WHERE m.created_at < p_cutoff
      AND m.match_type IN ('proximity','event','co_motion')
    ORDER BY m.created_at
    LIMIT COALESCE(p_limit, 500)
    FOR UPDATE
  ),
  eligible AS (
    SELECT l.*
    FROM locked l
    WHERE NOT EXISTS (
      SELECT 1 FROM public.chat_messages cm
      WHERE cm.match_id = l.id
      LIMIT 1
    )
  ),
  upsert_pairs AS (
    INSERT INTO public.unmatched_pairs (user1_id, user2_id, created_by, created_at, match_type, match_id)
    SELECT
      LEAST(e.user1_id, e.user2_id),
      GREATEST(e.user1_id, e.user2_id),
      '00000000-0000-0000-0000-000000000000'::uuid,
      now(),
      e.match_type,
      e.id
    FROM eligible e
    ON CONFLICT (user1_id, user2_id) DO UPDATE
    SET
      created_by = EXCLUDED.created_by,
      created_at = GREATEST(unmatched_pairs.created_at, EXCLUDED.created_at),
      match_type = COALESCE(unmatched_pairs.match_type, EXCLUDED.match_type),
      match_id = COALESCE(unmatched_pairs.match_id, EXCLUDED.match_id)
    RETURNING 1
  ),
  del_chats AS (
    DELETE FROM public.chats c
    WHERE c.match_id IN (SELECT id FROM eligible)
    RETURNING 1
  ),
  del_user_recent_matches AS (
    DELETE FROM public.user_recent_matches urm
    WHERE urm.match_id IN (SELECT id FROM eligible)
    RETURNING 1
  ),
  del_messages AS (
    DELETE FROM public.chat_messages cm
    WHERE cm.match_id IN (SELECT id FROM eligible)
    RETURNING 1
  ),
  del_matches AS (
    DELETE FROM public.matches m
    WHERE m.id IN (SELECT id FROM eligible)
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_deleted FROM del_matches;

  RETURN COALESCE(v_deleted, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.cleanup_expired_matches(timestamptz, int) TO service_role;

DROP FUNCTION IF EXISTS public.perform_event_matching(uuid);
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

DROP FUNCTION IF EXISTS public.perform_continuous_user_matching();
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
    v_a uuid;
    v_b uuid;
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
            v_a := LEAST(user_record.user_id, nearby_user_record.user_id);
            v_b := GREATEST(user_record.user_id, nearby_user_record.user_id);

            IF EXISTS (
                SELECT 1 FROM public.unmatched_pairs up
                WHERE up.user1_id = v_a AND up.user2_id = v_b
            ) THEN
                CONTINUE;
            END IF;

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
                    v_a,
                    v_b,
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

COMMIT;
