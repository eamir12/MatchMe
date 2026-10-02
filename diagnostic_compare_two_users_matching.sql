-- Compare two users against the gates used by
-- public.perform_continuous_user_matching().
-- Replace the two UUIDs below and run this in the Supabase SQL editor.
-- The result has one operational row plus one row per shared active intent.

WITH params AS (
    SELECT
        '00000000-0000-0000-0000-000000000001'::uuid AS user_a_id,
        '00000000-0000-0000-0000-000000000002'::uuid AS user_b_id
),
profiles AS (
    SELECT
        p.user_a_id,
        p.user_b_id,
        ua.gender AS a_gender,
        ua.date_of_birth AS a_dob,
        EXTRACT(YEAR FROM AGE(ua.date_of_birth))::integer AS a_age,
        COALESCE(ua.user_visibility_setting, false) AS a_visibility,
        COALESCE(ua.system_visibility_status, 'visible') AS a_system_visibility,
        COALESCE(ua.match_radius_default, 10000) AS a_radius_m,
        ub.gender AS b_gender,
        ub.date_of_birth AS b_dob,
        EXTRACT(YEAR FROM AGE(ub.date_of_birth))::integer AS b_age,
        COALESCE(ub.user_visibility_setting, false) AS b_visibility,
        COALESCE(ub.system_visibility_status, 'visible') AS b_system_visibility,
        COALESCE(ub.match_radius_default, 10000) AS b_radius_m,
        COALESCE(upa.active_modes, '[]'::jsonb) AS a_active_modes,
        COALESCE(upb.active_modes, '[]'::jsonb) AS b_active_modes,
        COALESCE(upa.sub_intents, '{}'::jsonb) AS a_sub_intents,
        COALESCE(upb.sub_intents, '{}'::jsonb) AS b_sub_intents,
        COALESCE(upa.lifestyle, '{}'::jsonb) AS a_lifestyle,
        COALESCE(upb.lifestyle, '{}'::jsonb) AS b_lifestyle,
        COALESCE(upa.family, '{}'::jsonb) AS a_family,
        COALESCE(upb.family, '{}'::jsonb) AS b_family,
        COALESCE(upa.religion, '{}'::jsonb) AS a_religion,
        COALESCE(upb.religion, '{}'::jsonb) AS b_religion,
        upa.height AS a_height,
        upb.height AS b_height,
        COALESCE(upa.intent_preferences, '{}'::jsonb) AS a_prefs,
        COALESCE(upb.intent_preferences, '{}'::jsonb) AS b_prefs,
        public.merge_interest_maps(
            COALESCE(upa.personal_interests, '{}'::jsonb),
            COALESCE(upa.business_interests, '{}'::jsonb)
        ) AS a_interests,
        public.merge_interest_maps(
            COALESCE(upb.personal_interests, '{}'::jsonb),
            COALESCE(upb.business_interests, '{}'::jsonb)
        ) AS b_interests
    FROM params p
    LEFT JOIN public.users ua ON ua.id = p.user_a_id
    LEFT JOIN public.users ub ON ub.id = p.user_b_id
    LEFT JOIN public.user_profiles upa ON upa.user_id = p.user_a_id
    LEFT JOIN public.user_profiles upb ON upb.user_id = p.user_b_id
),
locations AS (
    SELECT
        pr.*,
        la.latitude AS a_lat,
        la.longitude AS a_lng,
        la.updated_at AS a_location_updated,
        lb.latitude AS b_lat,
        lb.longitude AS b_lng,
        lb.updated_at AS b_location_updated,
        COALESCE(aa.is_online, false) AS a_online,
        COALESCE(ab.is_online, false) AS b_online,
        CASE
            WHEN la.latitude IS NULL OR la.longitude IS NULL
              OR lb.latitude IS NULL OR lb.longitude IS NULL THEN NULL::double precision
            ELSE 6371.0 * acos(LEAST(1.0, GREATEST(-1.0,
                cos(radians(la.latitude)) * cos(radians(lb.latitude))
                * cos(radians(lb.longitude) - radians(la.longitude))
                + sin(radians(la.latitude)) * sin(radians(lb.latitude))
            )))
        END AS distance_km
    FROM profiles pr
    LEFT JOIN public.user_locations la ON la.user_id = pr.user_a_id
    LEFT JOIN public.user_locations lb ON lb.user_id = pr.user_b_id
    LEFT JOIN public.user_activity aa ON aa.user_id = pr.user_a_id
    LEFT JOIN public.user_activity ab ON ab.user_id = pr.user_b_id
),
shared_intents AS (
    SELECT
        l.*,
        i.intent
    FROM locations l
    CROSS JOIN LATERAL (
        SELECT value AS intent
        FROM jsonb_array_elements_text(l.a_active_modes) AS a(value)
        INTERSECT
        SELECT value AS intent
        FROM jsonb_array_elements_text(l.b_active_modes) AS b(value)
    ) i
),
per_intent AS (
    SELECT
        s.*,
        COALESCE(s.a_sub_intents -> s.intent, '[]'::jsonb) AS a_sub_values,
        COALESCE(s.b_sub_intents -> s.intent, '[]'::jsonb) AS b_sub_values,
        (
            jsonb_array_length(COALESCE(s.a_sub_intents -> s.intent, '[]'::jsonb)) > 0
            AND jsonb_array_length(COALESCE(s.b_sub_intents -> s.intent, '[]'::jsonb)) > 0
            AND EXISTS (
                SELECT 1
                FROM jsonb_array_elements_text(COALESCE(s.a_sub_intents -> s.intent, '[]'::jsonb)) a_sub(value)
                WHERE a_sub.value IN (
                    SELECT value
                    FROM jsonb_array_elements_text(COALESCE(s.b_sub_intents -> s.intent, '[]'::jsonb)) b_sub(value)
                )
            )
        ) AS sub_intents_pass,
        (
            NOT ((s.b_prefs -> 'gender_preferences') ? s.intent)
            OR (s.b_prefs -> 'gender_preferences' -> s.intent) ? COALESCE(s.a_gender, '')
        )
        AND (
            NOT ((s.a_prefs -> 'gender_preferences') ? s.intent)
            OR (s.a_prefs -> 'gender_preferences' -> s.intent) ? COALESCE(s.b_gender, '')
        ) AS gender_pass,
        (
            NOT ((s.b_prefs -> 'age_preferences') ? s.intent)
            OR s.a_age IS NULL
            OR (
                jsonb_array_length(s.b_prefs -> 'age_preferences' -> s.intent) >= 2
                AND s.a_age BETWEEN
                    (s.b_prefs -> 'age_preferences' -> s.intent ->> 0)::numeric
                    AND (s.b_prefs -> 'age_preferences' -> s.intent ->> 1)::numeric
            )
        )
        AND (
            NOT ((s.a_prefs -> 'age_preferences') ? s.intent)
            OR s.b_age IS NULL
            OR (
                jsonb_array_length(s.a_prefs -> 'age_preferences' -> s.intent) >= 2
                AND s.b_age BETWEEN
                    (s.a_prefs -> 'age_preferences' -> s.intent ->> 0)::numeric
                    AND (s.a_prefs -> 'age_preferences' -> s.intent ->> 1)::numeric
            )
        ) AS age_pass,
        public.are_filters_compatible(
            s.a_lifestyle, s.a_family, s.a_religion, s.a_height,
            s.b_lifestyle, s.b_family, s.b_religion, s.b_height,
            s.b_prefs -> 'lifestyle_filters', s.b_prefs -> 'family_filters',
            s.b_prefs -> 'religion_filters', s.b_prefs -> 'height_preferences',
            s.a_prefs -> 'lifestyle_filters', s.a_prefs -> 'family_filters',
            s.a_prefs -> 'religion_filters', s.a_prefs -> 'height_preferences',
            s.intent
        ) AS filters_pass,
        EXISTS (
            SELECT 1
            FROM jsonb_object_keys(s.a_interests) AS category
            WHERE s.b_interests ? category
              AND jsonb_array_length(s.a_interests -> category) > 0
              AND jsonb_array_length(s.b_interests -> category) > 0
              AND EXISTS (
                  SELECT 1
                  FROM jsonb_array_elements_text(s.a_interests -> category) AS a_interest(value)
                  WHERE a_interest.value = ANY(
                      SELECT jsonb_array_elements_text(s.b_interests -> category)
                  )
              )
        ) AS interests_pass
    FROM shared_intents s
),
operational AS (
    SELECT
        l.*,
        (l.a_online AND l.a_visibility AND l.a_system_visibility = 'visible'
         AND l.a_location_updated >= NOW() - INTERVAL '5 minutes') AS a_in_matching_pool,
        (l.b_online AND l.b_visibility AND l.b_system_visibility = 'visible'
         AND l.b_location_updated >= NOW() - INTERVAL '5 minutes') AS b_in_matching_pool,
        (l.distance_km IS NOT NULL
         AND l.distance_km <= l.a_radius_m / 1000.0
         AND l.distance_km <= l.b_radius_m / 1000.0) AS proximity_pass,
        EXISTS (
            SELECT 1 FROM public.matches m
            WHERE (m.user1_id = l.user_a_id AND m.user2_id = l.user_b_id)
               OR (m.user1_id = l.user_b_id AND m.user2_id = l.user_a_id)
        ) AS already_matched,
        EXISTS (
            SELECT 1 FROM public.unmatched_pairs up
            WHERE (up.user1_id = l.user_a_id AND up.user2_id = l.user_b_id)
               OR (up.user1_id = l.user_b_id AND up.user2_id = l.user_a_id)
        ) AS explicitly_unmatched
    FROM locations l
)
SELECT
    'operational' AS row_type,
    o.user_a_id,
    o.user_b_id,
    NULL::text AS intent,
    jsonb_build_object(
        'a_exists', o.a_gender IS NOT NULL OR o.a_active_modes <> '[]'::jsonb,
        'b_exists', o.b_gender IS NOT NULL OR o.b_active_modes <> '[]'::jsonb,
        'a_online', o.a_online,
        'b_online', o.b_online,
        'a_visibility', o.a_visibility,
        'b_visibility', o.b_visibility,
        'a_system_visibility', o.a_system_visibility,
        'b_system_visibility', o.b_system_visibility,
        'a_location_updated', o.a_location_updated,
        'b_location_updated', o.b_location_updated,
        'a_in_matching_pool', o.a_in_matching_pool,
        'b_in_matching_pool', o.b_in_matching_pool,
        'distance_km', o.distance_km,
        'a_radius_km', o.a_radius_m / 1000.0,
        'b_radius_km', o.b_radius_m / 1000.0,
        'proximity_pass', o.proximity_pass,
        'already_matched', o.already_matched,
        'explicitly_unmatched', o.explicitly_unmatched,
        'operational_match_possible',
            o.a_in_matching_pool AND o.b_in_matching_pool
            AND o.proximity_pass AND NOT o.already_matched
            AND NOT o.explicitly_unmatched
    ) AS criteria
FROM operational o

UNION ALL

SELECT
    'intent' AS row_type,
    p.user_a_id,
    p.user_b_id,
    p.intent,
    jsonb_build_object(
        'sub_intents_pass', p.sub_intents_pass,
        'gender_pass', p.gender_pass,
        'age_pass', p.age_pass,
        'filters_pass', p.filters_pass,
        'interests_pass', p.interests_pass,
        'matcher_intent_passes', p.sub_intents_pass AND p.gender_pass
            AND p.age_pass AND p.filters_pass AND p.interests_pass,
        'a_sub_intents', p.a_sub_values,
        'b_sub_intents', p.b_sub_values,
        'a_gender', p.a_gender,
        'b_gender', p.b_gender,
        'a_age', p.a_age,
        'b_age', p.b_age,
        'a_interest_map', p.a_interests,
        'b_interest_map', p.b_interests
    ) AS criteria
FROM per_intent p
ORDER BY row_type, intent;

-- Optional: the Admin Inspector's own profile verdict. This intentionally does
-- not replace the query above: its is_compatible flag does not include the
-- matching pool, freshness, online, visibility, radius, or unmatched gates.
-- SELECT public.admin_compare_users(
--     '00000000-0000-0000-0000-000000000001'::uuid,
--     '00000000-0000-0000-0000-000000000002'::uuid
-- );