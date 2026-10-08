-- Migration: Pinning may only freeze a position the server has observed
-- Date: 2026-10-05
-- Depends on: 20262013000000 (pin columns + RPCs), 20262014000000 (touch/expire),
--             20262085000000 / 20262086000000 (pinned presence exemptions)
--
-- Fraud rationale: until now pin_current_location() accepted CLIENT-supplied
-- coordinates. Any modified client, script, or rooted device could therefore
-- pin a point thousands of km away and keep matching there without ever
-- traveling — proximity fraud the UI never had to expose. A pin is a
-- temporary "keep matching near a place I actually visit" measure, so the
-- only honest source for the pin's coordinates is the server's own live-GPS
-- observation of that user.
--
-- New rule: the pin coordinates are taken from the user's existing
-- user_locations row (written exclusively by public.update_user_location()
-- live-GPS writes, which the pin guard and client gates keep honest).
-- Client-supplied p_latitude / p_longitude are still accepted (signature
-- compatibility — existing app versions keep calling unchanged) but are
-- IGNORED. The server becomes the single authority: a user physically in
-- Paris cannot pin Cairo, because the server has no Cairo row to pin.
--
-- Presence proof: the observed row must be FRESH — updated_at within the
-- last 15 minutes (same window is_user_truly_visible uses for a fresh live
-- location; cleanup_old_user_locations(15) deletes anything older anyway).
-- No fresh observation = the user is not provably transmitting from the
-- spot, so no pin. Re-pinning after unpin/expiry therefore requires a real
-- GPS write first: re-presence is automatic, no extra machinery.
--
-- Interaction with existing flows (unchanged behavior):
--   - Re-pinning while a pin is active: the row's updated_at is kept fresh
--     by touch_active_pinned_locations(), so "pin again" works and simply
--     overwrites expiry/label at the same pinned coordinates.
--   - update_user_location() still clears stale pin flags on the next live
--     write, so an expired pin reverts to live mode even without unpin.
--
-- NOTE: while a pin is active the client deliberately stops GPS writes, so
-- "fresh" during a pin is maintained by the cron touch (bumps updated_at
-- without touching coordinates) — the coordinates remain the pinned point.

CREATE OR REPLACE FUNCTION public.pin_current_location(
    p_user_id UUID,
    p_latitude DOUBLE PRECISION,
    p_longitude DOUBLE PRECISION,
    p_label TEXT DEFAULT NULL,
    p_duration_seconds INT DEFAULT 86400
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_expires TIMESTAMPTZ;
    v_label TEXT;
    v_observed_lat DOUBLE PRECISION;
    v_observed_lng DOUBLE PRECISION;
    v_observed_at TIMESTAMPTZ;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'user not found';
    END IF;

    -- p_latitude / p_longitude are accepted for signature compatibility but
    -- deliberately IGNORED: pinning is only allowed at a position the server
    -- has observed from live GPS (anti-fraud — see migration header).

    -- Min 60s (allows testing), max 30 days.
    IF p_duration_seconds IS NULL OR p_duration_seconds < 60 OR p_duration_seconds > 2592000 THEN
        RAISE EXCEPTION 'invalid duration (must be 60s..30 days)';
    END IF;

    v_label := NULLIF(TRIM(COALESCE(p_label, '')), '');
    IF v_label IS NOT NULL AND LENGTH(v_label) > 120 THEN
        v_label := LEFT(v_label, 120);
    END IF;

    -- The pin freezes the server-observed position, never a client claim.
    SELECT latitude, longitude, updated_at
    INTO v_observed_lat, v_observed_lng, v_observed_at
    FROM public.user_locations
    WHERE user_id = p_user_id;

    IF v_observed_lat IS NULL OR v_observed_lng IS NULL OR v_observed_at IS NULL THEN
        RAISE EXCEPTION 'no observed location to pin';
    END IF;

    IF v_observed_at < NOW() - INTERVAL '15 minutes' THEN
        RAISE EXCEPTION 'observed location too old to pin';
    END IF;

    v_expires := NOW() + (p_duration_seconds || ' seconds')::INTERVAL;

    INSERT INTO public.user_locations (
        user_id, latitude, longitude, speed, heading, updated_at,
        is_pinned, pinned_expires_at, pinned_created_at, pinned_label
    )
    VALUES (
        p_user_id, v_observed_lat, v_observed_lng, NULL, NULL, NOW(),
        TRUE, v_expires, NOW(), v_label
    )
    ON CONFLICT (user_id)
    DO UPDATE SET
        latitude = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude,
        speed = NULL,
        heading = NULL,
        updated_at = NOW(),
        is_pinned = TRUE,
        pinned_expires_at = EXCLUDED.pinned_expires_at,
        pinned_created_at = NOW(),
        pinned_label = EXCLUDED.pinned_label;

    -- Keep the user online; this does NOT touch coordinates.
    PERFORM public.update_user_activity(p_user_id);

    RETURN v_expires;
END;
$$;

GRANT EXECUTE ON FUNCTION public.pin_current_location(UUID, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pin_current_location(UUID, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, INT) TO service_role;

COMMENT ON FUNCTION public.pin_current_location IS
  'Pins the user''s SERVER-OBSERVED position (from live GPS in user_locations, must be <= 15 min old) for p_duration_seconds. Client-supplied p_latitude/p_longitude are accepted for backwards compatibility but IGNORED — a user can only pin where the server has actually seen them.';
