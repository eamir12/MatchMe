-- Test matching after fixing the radius
-- This should now create a match since all criteria will be met

DO $$
DECLARE
    edge_user_id UUID := '35fe114e-eae5-49d6-9eba-8459617e7b82';
    android_user_id UUID := 'ffc20046-a777-463b-922a-547151aa1455';
    shared_intents TEXT[];
    has_shared_interest BOOLEAN := FALSE;
    edge_interests JSONB;
    android_interests JSONB;
    interest_category TEXT;
    edge_modes TEXT[];
    android_modes TEXT[];
BEGIN
    RAISE NOTICE '=== TESTING MATCH AFTER RADIUS FIX ===';

    -- Check visibility
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = edge_user_id AND user_visibility_setting = TRUE) THEN
        RAISE NOTICE '❌ Edge user not visible';
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = android_user_id AND user_visibility_setting = TRUE) THEN
        RAISE NOTICE '❌ Android user not visible';
        RETURN;
    END IF;
    RAISE NOTICE '✅ Both users visible';

    -- Load active modes into local arrays and check shared intents
    SELECT active_modes INTO edge_modes FROM users WHERE id = edge_user_id;
    SELECT active_modes INTO android_modes FROM users WHERE id = android_user_id;

    SELECT ARRAY(
        SELECT intent
        FROM unnest(edge_modes) AS t(intent)
        WHERE intent = ANY(android_modes)
    ) INTO shared_intents;

    IF shared_intents IS NULL OR array_length(shared_intents, 1) = 0 THEN
        RAISE NOTICE '❌ No shared intents found';
        RETURN;
    END IF;
    RAISE NOTICE '✅ Shared intents found: %', shared_intents;

    -- Check proximity with updated radius
    DECLARE
        distance_meters DOUBLE PRECISION;
        user_radius DOUBLE PRECISION;
    BEGIN
        SELECT
            (6371000 * 2 * ASIN(SQRT(
                POWER(SIN(RADIANS(ul2.latitude - ul1.latitude) / 2), 2) +
                COS(RADIANS(ul1.latitude)) * COS(RADIANS(ul2.latitude)) *
                POWER(SIN(RADIANS(ul2.longitude - ul1.longitude) / 2), 2)
            ))),
            u1.match_radius_default
        INTO distance_meters, user_radius
        FROM user_locations ul1
        JOIN user_locations ul2 ON ul1.user_id = edge_user_id AND ul2.user_id = android_user_id
        JOIN users u1 ON ul1.user_id = u1.id
        WHERE ul1.updated_at >= NOW() - INTERVAL '1 hour'
        AND ul2.updated_at >= NOW() - INTERVAL '1 hour'
        LIMIT 1;

        RAISE NOTICE '   Distance: % meters, Radius: % meters', distance_meters, user_radius;

        IF distance_meters > user_radius THEN
            RAISE NOTICE '❌ Still out of range after fix!';
            RETURN;
        END IF;
        RAISE NOTICE '✅ Within range after radius fix';
    END;

    -- Check shared interests
    SELECT profile_data->'interests' INTO edge_interests
    FROM user_profiles WHERE user_id = edge_user_id AND profile_data ? 'interests' LIMIT 1;

    SELECT profile_data->'interests' INTO android_interests
    FROM user_profiles WHERE user_id = android_user_id AND profile_data ? 'interests' LIMIT 1;

    IF edge_interests IS NOT NULL AND android_interests IS NOT NULL THEN
        FOR interest_category IN SELECT jsonb_object_keys(edge_interests) INTERSECT SELECT jsonb_object_keys(android_interests) LOOP
            IF jsonb_array_length(edge_interests->interest_category) > 0 AND jsonb_array_length(android_interests->interest_category) > 0 THEN
                IF EXISTS (
                    SELECT 1 FROM jsonb_array_elements_text(edge_interests->interest_category) as i1
                    WHERE i1 IN (SELECT jsonb_array_elements_text(android_interests->interest_category))
                ) THEN
                    has_shared_interest := TRUE;
                    RAISE NOTICE '✅ Shared interests found in category: %', interest_category;
                    EXIT;
                END IF;
            END IF;
        END LOOP;
    END IF;

    IF NOT has_shared_interest THEN
        RAISE NOTICE '❌ No shared interests found';
        RETURN;
    END IF;

    -- Check existing match
    IF EXISTS (
        SELECT 1 FROM matches
        WHERE (user1_id = edge_user_id AND user2_id = android_user_id)
           OR (user1_id = android_user_id AND user2_id = edge_user_id)
    ) THEN
        RAISE NOTICE '⚠️ Match already exists';
        RETURN;
    END IF;

    -- Create match
    RAISE NOTICE '🎉 CREATING MATCH NOW!';
    INSERT INTO matches (user1_id, user2_id, matched_intent, match_type, created_at)
    VALUES (LEAST(edge_user_id, android_user_id), GREATEST(edge_user_id, android_user_id), shared_intents[1], 'proximity', NOW());

    RAISE NOTICE '✅ MATCH CREATED SUCCESSFULLY!';

END $$;
