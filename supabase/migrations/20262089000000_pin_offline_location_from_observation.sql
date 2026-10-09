-- Complete a pin request that was captured while the client was offline.
-- Coordinates are never accepted from the client: use the last location
-- observed by Supabase, or return NULL so the client can upload one fresh
-- observation and retry.
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
        OR p_duration_seconds > 2592000 THEN
        RAISE EXCEPTION 'invalid duration (must be 60s..30 days)';
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

    v_expires := NOW() + (p_duration_seconds || ' seconds')::INTERVAL;

    UPDATE public.user_locations
    SET speed = NULL,
        heading = NULL,
        updated_at = NOW(),
        is_pinned = TRUE,
        pinned_expires_at = v_expires,
        pinned_created_at = NOW(),
        pinned_label = v_label
    WHERE user_id = p_user_id;

    PERFORM public.update_user_activity(p_user_id);

    RETURN jsonb_build_object(
        'expires_at', v_expires,
        'latitude', v_lat,
        'longitude', v_lng
    );
END;
$$;

REVOKE ALL ON FUNCTION public.pin_current_location_from_observation(UUID, TEXT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pin_current_location_from_observation(UUID, TEXT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pin_current_location_from_observation(UUID, TEXT, INT) TO service_role;

COMMENT ON FUNCTION public.pin_current_location_from_observation(UUID, TEXT, INT) IS
    'Completes an offline pin using only the location already observed by the server. If no server location exists, returns NULL and the authenticated client may upload one fresh location before retrying.';
