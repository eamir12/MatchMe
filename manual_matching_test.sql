-- Manual test of the matching logic for Edge and Android users

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
    RAISE NOTICE '=== MANUAL MATCHING TEST ===';

    -- Check if users exist and are visible
    RAISE NOTICE 'Checking user visibility...';
    IF NOT public.is_user_truly_visible(edge_user_id) THEN
        RAISE NOTICE '❌ Edge user not truly visible or does not exist';
        RETURN;
    END IF;
    IF NOT public.is_user_truly_visible(android_user_id) THEN
        RAISE NOTICE '❌ Android user not truly visible or does not exist';
        RETURN;
    END IF;
    RAISE NOTICE '✅ Both users are visible';

    -- Check shared intents
    RAISE NOTICE 'Checking shared intents...';
    SELECT active_modes INTO edge_modes FROM users WHERE id = edge_user_id;
    SELECT active_modes INTO android_modes FROM users WHERE id = android_user_id;

    SELECT ARRAY(
        SELECT intent
        FROM unnest(edge_modes) AS t(intent)
        WHERE intent = ANY(android_modes)
    ) INTO shared_intents;

    IF shared_intents IS NULL OR array_length(shared_intents, 1) = 0 THEN
        RAISE NOTICE '❌ No shared intents found';
        RAISE NOTICE '   Edge intents: %', (SELECT active_modes FROM users WHERE id = edge_user_id);
        RAISE NOTICE '   Android intents: %', (SELECT active_modes FROM users WHERE id = android_user_id);
        RETURN;
    END IF;
    RAISE NOTICE '✅ Found shared intents: %', shared_intents;

    -- Check shared interests
    RAISE NOTICE 'Checking shared interests...';

    -- Get interests for both users
    SELECT profile_data->'interests' INTO edge_interests
    FROM user_profiles
    WHERE user_id = edge_user_id AND profile_data ? 'interests'
    LIMIT 1;

    SELECT profile_data->'interests' INTO android_interests
    FROM user_profiles
    WHERE user_id = android_user_id AND profile_data ? 'interests'
    LIMIT 1;

    RAISE NOTICE '   Edge interests: %', edge_interests;
    RAISE NOTICE '   Android interests: %', android_interests;

    IF edge_interests IS NOT NULL AND android_interests IS NOT NULL THEN
        -- Check if any category has shared interests
        FOR interest_category IN SELECT jsonb_object_keys(edge_interests) INTERSECT SELECT jsonb_object_keys(android_interests) LOOP
            RAISE NOTICE '   Checking category: %', interest_category;

            IF jsonb_array_length(edge_interests->interest_category) > 0 AND jsonb_array_length(android_interests->interest_category) > 0 THEN
                IF EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements_text(edge_interests->interest_category) as i1
                    WHERE i1 IN (SELECT jsonb_array_elements_text(android_interests->interest_category))
                ) THEN
                    has_shared_interest := TRUE;
                    RAISE NOTICE '   ✅ Found shared interests in category: %', interest_category;
                    EXIT;
                END IF;
            END IF;
        END LOOP;
    END IF;

    IF NOT has_shared_interest THEN
        RAISE NOTICE '❌ No shared interests found in any category';
        RETURN;
    END IF;

    -- If we get here, all criteria are met
    RAISE NOTICE '🎉 ALL MATCHING CRITERIA MET!';
    RAISE NOTICE '   Shared intents: %', shared_intents;
    RAISE NOTICE '   Shared interests: YES';

    -- Check if match already exists
    IF EXISTS (
        SELECT 1 FROM matches
        WHERE (user1_id = edge_user_id AND user2_id = android_user_id)
           OR (user1_id = android_user_id AND user2_id = edge_user_id)
    ) THEN
        RAISE NOTICE '⚠️ Match already exists between these users';
        RETURN;
    END IF;

    -- Create the match
    RAISE NOTICE 'Creating match...';
    INSERT INTO matches (
        user1_id,
        user2_id,
        matched_intent,
        match_type,
        created_at
    ) VALUES (
        LEAST(edge_user_id, android_user_id),
        GREATEST(edge_user_id, android_user_id),
        shared_intents[1],
        'proximity',
        NOW()
    );

    RAISE NOTICE '✅ MATCH CREATED SUCCESSFULLY!';

END $$;
