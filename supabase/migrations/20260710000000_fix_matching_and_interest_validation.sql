-- Migration: Fix matching function + interest data validation
-- Date: 2026-07-10
-- Fixes:
--   1. Clean up invalid interest data (category name appearing as its own sub-interest)
--   2. Add trigger to prevent future invalid interest data
--   3. Delete incorrect match row
--   4. Rewrite perform_continuous_user_matching:
--      - Each shared intent is evaluated independently for all 4 criteria
--      - All preferences treated as strict (no flexible fallback)
--      - matched_intent = the specific intent that passed all criteria
--      - Interests aggregated across all profile rows (like event matching)
--      - Sub-intent check is per-intent, not global

BEGIN;

-------------------------------------------------------------------------------
-- 1) Clean up invalid interest data: remove category name from its own sub-list
-------------------------------------------------------------------------------
UPDATE user_profiles
SET profile_data = jsonb_set(
  profile_data,
  '{interests}',
  (
    SELECT COALESCE(
      jsonb_object_agg(
        cat,
        filtered_subs
      ),
      '{}'::jsonb
    )
    FROM jsonb_each(profile_data->'interests') AS t(cat, val)
    CROSS JOIN LATERAL (
      SELECT COALESCE(
        jsonb_agg(sub),
        '[]'::jsonb
      ) AS filtered_subs
      FROM jsonb_array_elements_text(val) AS sub
      WHERE sub != cat
    ) f
    WHERE jsonb_typeof(val) = 'array'
  )
)
WHERE profile_data ? 'interests'
  AND EXISTS (
    SELECT 1 FROM jsonb_each(profile_data->'interests') AS t(cat, val)
    WHERE jsonb_typeof(val) = 'array' AND (val ? cat)
  );

-------------------------------------------------------------------------------
-- 2) Trigger to prevent category name appearing as its own sub-interest
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_interest_no_self_reference()
RETURNS TRIGGER AS $$
DECLARE
  cat TEXT;
  subs JSONB;
  sub TEXT;
BEGIN
  IF NEW.profile_data ? 'interests' THEN
    FOR cat, subs IN SELECT key, value FROM jsonb_each(NEW.profile_data->'interests')
    LOOP
      IF jsonb_typeof(subs) = 'array' THEN
        FOR sub IN SELECT jsonb_array_elements_text(subs)
        LOOP
          IF sub = cat THEN
            RAISE EXCEPTION 'Interest category "%" cannot also appear as a sub-interest within itself', cat;
          END IF;
        END LOOP;
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_interests ON user_profiles;
CREATE TRIGGER trg_validate_interests
  BEFORE INSERT OR UPDATE ON user_profiles
  FOR EACH ROW EXECUTE FUNCTION public.validate_interest_no_self_reference();

-------------------------------------------------------------------------------
-- 3) Delete the incorrect match row
-------------------------------------------------------------------------------
DELETE FROM matches WHERE id = 'e5053b5b-74cc-4d15-8e46-28f85d97657f';

-------------------------------------------------------------------------------
-- 4) Rewrite perform_continuous_user_matching
-------------------------------------------------------------------------------
-- Key changes from the old version:
--   a) Each shared intent is evaluated INDEPENDENTLY for all 4 criteria
--   b) All gender/age preferences treated as STRICT (no flexible fallback)
--   c) matched_intent = the specific intent that passed, not shared_intents[1]
--   d) Interests aggregated across ALL profile rows via jsonb_object_agg
--   e) Sub-intent check is per-intent (must pass for the SAME intent)

CREATE OR REPLACE FUNCTION public.perform_continuous_user_matching()
RETURNS TABLE (
    users_processed INTEGER,
    matches_created INTEGER,
    status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $_$
DECLARE
    user_record RECORD;
    nearby_user_record RECORD;
    current_user_intents TEXT[];
    current_user_interests JSONB;
    other_user_intents TEXT[];
    other_user_interests JSONB;
    shared_intents TEXT[];
    total_users_processed INTEGER := 0;
    total_matches_created INTEGER := 0;
    matched_intent_result TEXT;
    shared_intent TEXT;
    current_sub_intents TEXT[];
    other_sub_intents TEXT[];
    current_user_gender_prefs JSONB;
    current_user_age_prefs JSONB;
    other_user_gender_prefs JSONB;
    other_user_age_prefs JSONB;
    other_user_gender TEXT;
    other_user_dob DATE;
    current_user_gender TEXT;
    current_user_dob DATE;
    other_user_age INTEGER;
    current_user_age INTEGER;
    a_gender_ok BOOLEAN;
    a_age_ok BOOLEAN;
    b_gender_ok BOOLEAN;
    b_age_ok BOOLEAN;
    -- Filter compatibility variables
    current_user_lifestyle    JSONB;
    current_user_family       JSONB;
    current_user_religion     JSONB;
    current_user_height       INTEGER;
    other_user_lifestyle      JSONB;
    other_user_family         JSONB;
    other_user_religion       JSONB;
    other_user_height         INTEGER;
    current_user_lifestyle_filters JSONB;
    current_user_family_filters    JSONB;
    current_user_religion_filters  JSONB;
    current_user_height_prefs      JSONB;
    other_user_lifestyle_filters   JSONB;
    other_user_family_filters      JSONB;
    other_user_religion_filters    JSONB;
    other_user_height_prefs        JSONB;
    filters_compatible BOOLEAN := FALSE;
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

        -- Load profile/preferences for the current user once per outer iteration
        SELECT
            gender, date_of_birth,
            gender_preferences, age_preferences,
            lifestyle, family, religion, height,
            lifestyle_filters, family_filters,
            religion_filters, height_preferences
        INTO current_user_gender, current_user_dob,
             current_user_gender_prefs, current_user_age_prefs,
             current_user_lifestyle, current_user_family, current_user_religion,
             current_user_height,
             current_user_lifestyle_filters, current_user_family_filters,
             current_user_religion_filters, current_user_height_prefs
        FROM users
        WHERE id = user_record.user_id;

        IF current_user_dob IS NOT NULL THEN
            current_user_age := EXTRACT(YEAR FROM AGE(current_user_dob));
        ELSE
            current_user_age := NULL;
        END IF;

        -- Aggregate interests across ALL profile rows (not LIMIT 1)
        SELECT COALESCE(jsonb_object_agg(cat, subs), '{}'::jsonb)
        INTO current_user_interests
        FROM (
            SELECT
                ie.key AS cat,
                ie.value AS subs
            FROM user_profiles up
            CROSS JOIN LATERAL jsonb_each(up.profile_data->'interests') AS ie(key, value)
            WHERE up.user_id = user_record.user_id
              AND up.profile_data ? 'interests'
              AND jsonb_typeof(up.profile_data->'interests') = 'object'
              AND jsonb_typeof(ie.value) = 'array'
        ) interests_data;

        current_user_intents := user_record.active_modes;

        FOR nearby_user_record IN
            SELECT * FROM find_nearby_users(
                user_record.user_id, user_record.latitude, user_record.longitude,
                (user_record.match_radius_default / 1000.0)::DOUBLE PRECISION
            )
        LOOP
            -- Skip if already matched
            IF EXISTS (
                SELECT 1 FROM matches
                WHERE (user1_id = user_record.user_id AND user2_id = nearby_user_record.user_id)
                   OR (user1_id = nearby_user_record.user_id AND user2_id = user_record.user_id)
            ) THEN
                CONTINUE;
            END IF;

            -- Load other user's data
            SELECT active_modes, gender, date_of_birth,
                   gender_preferences, age_preferences,
                   lifestyle, family, religion, height,
                   lifestyle_filters, family_filters,
                   religion_filters, height_preferences
            INTO other_user_intents, other_user_gender, other_user_dob,
                 other_user_gender_prefs, other_user_age_prefs,
                 other_user_lifestyle, other_user_family, other_user_religion,
                 other_user_height,
                 other_user_lifestyle_filters, other_user_family_filters,
                 other_user_religion_filters, other_user_height_prefs
            FROM users
            WHERE id = nearby_user_record.user_id
              AND (EXISTS (SELECT 1 FROM user_activity ua WHERE ua.user_id = users.id AND ua.is_online = TRUE)
                AND COALESCE(user_visibility_setting,false) = TRUE
                AND COALESCE(system_visibility_status,'visible') = 'visible');

            IF other_user_intents IS NULL OR array_length(other_user_intents, 1) = 0 THEN
                CONTINUE;
            END IF;

            IF other_user_dob IS NOT NULL THEN
                other_user_age := EXTRACT(YEAR FROM AGE(other_user_dob));
            ELSE
                other_user_age := NULL;
            END IF;

            -- Compute shared intents
            SELECT ARRAY(
                SELECT intent
                FROM unnest(current_user_intents) as t(intent)
                WHERE intent = ANY(other_user_intents)
            ) INTO shared_intents;

            IF array_length(shared_intents, 1) IS NULL OR array_length(shared_intents, 1) = 0 THEN
                CONTINUE;
            END IF;

            -- Aggregate other user's interests across ALL profile rows
            SELECT COALESCE(jsonb_object_agg(cat, subs), '{}'::jsonb)
            INTO other_user_interests
            FROM (
                SELECT
                    ie.key AS cat,
                    ie.value AS subs
                FROM user_profiles up
                CROSS JOIN LATERAL jsonb_each(up.profile_data->'interests') AS ie(key, value)
                WHERE up.user_id = nearby_user_record.user_id
                  AND up.profile_data ? 'interests'
                  AND jsonb_typeof(up.profile_data->'interests') = 'object'
                  AND jsonb_typeof(ie.value) = 'array'
            ) interests_data;

            -- Evaluate each shared intent independently for ALL 4 criteria.
            -- The first intent that passes all criteria is used as matched_intent.
            matched_intent_result := NULL;

            <<intent_loop>>
            FOREACH shared_intent IN ARRAY shared_intents LOOP

                -- CRITERION 1: Sub-intent overlap for THIS specific intent
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

                -- Both users must have sub-intents for this intent, and they must overlap
                IF array_length(current_sub_intents, 1) IS NULL
                   OR array_length(other_sub_intents, 1) IS NULL THEN
                    -- One or both users have no sub-intents for this intent — skip
                    CONTINUE intent_loop;
                END IF;

                IF NOT (current_sub_intents && other_sub_intents) THEN
                    CONTINUE intent_loop;
                END IF;

                -- CRITERION 2: Gender preferences (ALL strict — no flexible fallback)
                -- Check that each user's candidate satisfies the other's gender preference
                a_gender_ok := (
                    NOT (other_user_gender_prefs ? shared_intent)
                    OR (other_user_gender_prefs -> shared_intent) ? current_user_gender
                );
                b_gender_ok := (
                    NOT (current_user_gender_prefs ? shared_intent)
                    OR (current_user_gender_prefs -> shared_intent) ? other_user_gender
                );

                IF NOT a_gender_ok OR NOT b_gender_ok THEN
                    CONTINUE intent_loop;
                END IF;

                -- CRITERION 2b: Age preferences (ALL strict)
                a_age_ok := (
                    NOT (other_user_age_prefs ? shared_intent)
                    OR current_user_age IS NULL
                    OR (
                        jsonb_array_length(other_user_age_prefs -> shared_intent) >= 2
                        AND current_user_age >= (other_user_age_prefs -> shared_intent ->> 0)::numeric
                        AND current_user_age <= (other_user_age_prefs -> shared_intent ->> 1)::numeric
                    )
                );
                b_age_ok := (
                    NOT (current_user_age_prefs ? shared_intent)
                    OR other_user_age IS NULL
                    OR (
                        jsonb_array_length(current_user_age_prefs -> shared_intent) >= 2
                        AND other_user_age >= (current_user_age_prefs -> shared_intent ->> 0)::numeric
                        AND other_user_age <= (current_user_age_prefs -> shared_intent ->> 1)::numeric
                    )
                );

                IF NOT a_age_ok OR NOT b_age_ok THEN
                    CONTINUE intent_loop;
                END IF;

                -- CRITERION 2c: Lifestyle/family/religion/height filter compatibility
                filters_compatible := public.are_filters_compatible(
                    current_user_lifestyle, current_user_family,
                    current_user_religion, current_user_height,
                    other_user_lifestyle, other_user_family,
                    other_user_religion, other_user_height,
                    other_user_lifestyle_filters, other_user_family_filters,
                    other_user_religion_filters, other_user_height_prefs,
                    current_user_lifestyle_filters, current_user_family_filters,
                    current_user_religion_filters, current_user_height_prefs,
                    shared_intent
                );

                IF NOT filters_compatible THEN
                    CONTINUE intent_loop;
                END IF;

                -- CRITERION 3+4: Interest and sub-interest overlap for THIS intent
                -- Check aggregated interests (already loaded above)
                IF current_user_interests IS NULL OR other_user_interests IS NULL THEN
                    CONTINUE intent_loop;
                END IF;

                IF NOT EXISTS (
                    SELECT 1
                    FROM jsonb_object_keys(current_user_interests) AS cat
                    WHERE current_user_interests ? cat AND other_user_interests ? cat
                      AND jsonb_array_length(current_user_interests->cat) > 0
                      AND jsonb_array_length(other_user_interests->cat) > 0
                      AND EXISTS (
                          SELECT 1
                          FROM jsonb_array_elements_text(current_user_interests->cat) AS sub
                          WHERE sub = ANY(SELECT jsonb_array_elements_text(other_user_interests->cat))
                      )
                ) THEN
                    CONTINUE intent_loop;
                END IF;

                -- This intent passed ALL 4 criteria
                matched_intent_result := shared_intent;
                EXIT intent_loop;

            END LOOP intent_loop;

            -- Only create match if an intent passed all criteria
            IF matched_intent_result IS NOT NULL THEN
                INSERT INTO matches (user1_id, user2_id, matched_intent, match_type, created_at)
                VALUES (
                    LEAST(user_record.user_id, nearby_user_record.user_id),
                    GREATEST(user_record.user_id, nearby_user_record.user_id),
                    matched_intent_result, 'proximity', NOW()
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

COMMIT;
