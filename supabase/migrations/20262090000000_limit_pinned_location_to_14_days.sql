-- Enforce a hard 14-day cumulative lifetime for every pinned location.
-- Existing pins beyond the new limit are shortened before adding the guard.
UPDATE public.user_locations
SET pinned_created_at = COALESCE(pinned_created_at, NOW()),
    pinned_expires_at = LEAST(
        COALESCE(pinned_expires_at, NOW()),
        COALESCE(pinned_created_at, NOW()) + INTERVAL '14 days'
    )
WHERE is_pinned IS TRUE;

ALTER TABLE public.user_locations
    ADD CONSTRAINT user_locations_pinned_duration_max_14_days
    CHECK (
        is_pinned IS NOT TRUE
        OR (
            pinned_created_at IS NOT NULL
            AND pinned_expires_at IS NOT NULL
            AND pinned_expires_at <= pinned_created_at + INTERVAL '14 days'
        )
    );

-- Return the server's exact pin creation time so the client can display only
-- extension presets that remain within the cumulative limit.
CREATE OR REPLACE FUNCTION public.pin_current_location_from_observation(
    p_user_id UUID,
    p_label TEXT DEFAULT NULL,
    p_duration_seconds INT DEFAULT 86400
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_lat DOUBLE PRECISION;
    v_lng DOUBLE PRECISION;
    v_created TIMESTAMPTZ := NOW();
    v_expires TIMESTAMPTZ;
    v_label TEXT;
BEGIN
    IF auth.uid() IS DISTINCT FROM p_user_id
        AND COALESCE(auth.role(), '') <> 'service_role' THEN
        RAISE EXCEPTION 'not authorized to pin this location'
            USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'user not found';
    END IF;

    IF p_duration_seconds IS NULL
        OR p_duration_seconds < 60
        OR p_duration_seconds > 1209600 THEN
        RAISE EXCEPTION USING
            MESSAGE = 'Invalid pin duration; allowed range is 60 seconds through 14 days';
    END IF;

    v_label := NULLIF(TRIM(COALESCE(p_label, '')), '');
    IF v_label IS NOT NULL AND LENGTH(v_label) > 120 THEN
        v_label := LEFT(v_label, 120);
    END IF;

    SELECT latitude, longitude
    INTO v_lat, v_lng
    FROM public.user_locations
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF v_lat IS NULL OR v_lng IS NULL THEN
        RETURN NULL;
    END IF;

    v_expires := v_created + (p_duration_seconds || ' seconds')::INTERVAL;

    UPDATE public.user_locations
    SET speed = NULL,
        heading = NULL,
        updated_at = v_created,
        is_pinned = TRUE,
        pinned_expires_at = v_expires,
        pinned_created_at = v_created,
        pinned_label = v_label
    WHERE user_id = p_user_id;

    PERFORM public.update_user_activity(p_user_id);

    RETURN jsonb_build_object(
        'created_at', v_created,
        'expires_at', v_expires,
        'latitude', v_lat,
        'longitude', v_lng
    );
END;
$$;

REVOKE ALL ON FUNCTION public.pin_current_location_from_observation(UUID, TEXT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pin_current_location_from_observation(UUID, TEXT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pin_current_location_from_observation(UUID, TEXT, INT) TO service_role;

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'pinnedLocationMaxDurationReached', 'The maximum total pinned time is 14 days.', NOW(), NOW()),
('es', 'pinnedLocationMaxDurationReached', 'El tiempo total máximo de ubicación fijada es de 14 días.', NOW(), NOW()),
('he', 'pinnedLocationMaxDurationReached', 'משך הזמן המרבי הכולל למיקום נעוץ הוא 14 ימים.', NOW(), NOW()),
('en', 'pinnedLocationExtensionDuration', 'Add time', NOW(), NOW()),
('es', 'pinnedLocationExtensionDuration', 'Añadir tiempo', NOW(), NOW()),
('he', 'pinnedLocationExtensionDuration', 'הוספת זמן', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE
SET value = EXCLUDED.value, updated_at = NOW();
