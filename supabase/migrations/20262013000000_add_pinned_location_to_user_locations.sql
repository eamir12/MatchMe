-- Migration: Pinned home-base location reusing user_locations (step 1)
-- Date: 2026-09-18
-- Purpose: Let users pin their matching location for a chosen duration (e.g. traveling,
--          keep matching near home). While a pin is active, live GPS must NOT overwrite
--          the pinned coordinates; only the online heartbeat continues.
-- Scope of THIS migration (intentionally narrow):
--   1. Add pin columns to public.user_locations (no new table).
--   2. Add pin/extend/unpin/is_active RPCs.
--   3. Guard public.update_user_location() so live GPS cannot clobber an active pin.
-- NOT in this migration (follow-ups):
--   - cleanup_old_user_locations() exemption for active pins
--   - is_user_truly_visible() / perform_continuous_user_matching() freshness exemption
--   - cron expiry + expiry-warning pushes (clone of handleMatchExpiryWarnings)
--   - client gating (Mobile/Web/BackgroundService/LocationWorker/iOS/OfflineTrail)

-- ---------------------------------------------------------------------------
-- 1. Columns (idempotent)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_locations'
        AND column_name = 'is_pinned'
    ) THEN
        ALTER TABLE public.user_locations
            ADD COLUMN is_pinned BOOLEAN NOT NULL DEFAULT FALSE;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_locations'
        AND column_name = 'pinned_expires_at'
    ) THEN
        ALTER TABLE public.user_locations
            ADD COLUMN pinned_expires_at TIMESTAMPTZ NULL;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_locations'
        AND column_name = 'pinned_created_at'
    ) THEN
        ALTER TABLE public.user_locations
            ADD COLUMN pinned_created_at TIMESTAMPTZ NULL;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_locations'
        AND column_name = 'pinned_label'
    ) THEN
        ALTER TABLE public.user_locations
            ADD COLUMN pinned_label TEXT NULL;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_user_locations_pinned_expiry
    ON public.user_locations (pinned_expires_at) WHERE is_pinned = TRUE;

-- ---------------------------------------------------------------------------
-- 2. Helper: is a pin currently active for this user?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_pinned_location_active(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT COALESCE((
        SELECT (ul.is_pinned = TRUE AND ul.pinned_expires_at > NOW())
        FROM public.user_locations ul
        WHERE ul.user_id = p_user_id
    ), FALSE);
$$;

GRANT EXECUTE ON FUNCTION public.is_pinned_location_active(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_pinned_location_active(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Pin / extend / unpin RPCs
-- ---------------------------------------------------------------------------

-- Pin the matching location. Overwrites the row once with the pinned point,
-- then clients must stop sending live GPS until expiry/unpin.
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
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'user not found';
    END IF;

    IF p_latitude IS NULL OR p_longitude IS NULL
        OR p_latitude < -90 OR p_latitude > 90
        OR p_longitude < -180 OR p_longitude > 180 THEN
        RAISE EXCEPTION 'invalid coordinates';
    END IF;

    -- Min 60s (allows testing), max 30 days.
    IF p_duration_seconds IS NULL OR p_duration_seconds < 60 OR p_duration_seconds > 2592000 THEN
        RAISE EXCEPTION 'invalid duration (must be 60s..30 days)';
    END IF;

    v_label := NULLIF(TRIM(COALESCE(p_label, '')), '');
    IF v_label IS NOT NULL AND LENGTH(v_label) > 120 THEN
        v_label := LEFT(v_label, 120);
    END IF;

    v_expires := NOW() + (p_duration_seconds || ' seconds')::INTERVAL;

    INSERT INTO public.user_locations (
        user_id, latitude, longitude, speed, heading, updated_at,
        is_pinned, pinned_expires_at, pinned_created_at, pinned_label
    )
    VALUES (
        p_user_id, p_latitude, p_longitude, NULL, NULL, NOW(),
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

-- Extend an active pin. Caps total pinned time at 30 days from creation.
CREATE OR REPLACE FUNCTION public.extend_pinned_location(
    p_user_id UUID,
    p_extra_seconds INT
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_row RECORD;
    v_new_expiry TIMESTAMPTZ;
    v_max_expiry TIMESTAMPTZ;
BEGIN
    IF p_extra_seconds IS NULL OR p_extra_seconds < 60 OR p_extra_seconds > 2592000 THEN
        RAISE EXCEPTION 'invalid duration (must be 60s..30 days)';
    END IF;

    SELECT is_pinned, pinned_expires_at, pinned_created_at
    INTO v_row
    FROM public.user_locations
    WHERE user_id = p_user_id;

    IF v_row IS NULL OR COALESCE(v_row.is_pinned, FALSE) = FALSE
        OR v_row.pinned_expires_at IS NULL OR v_row.pinned_expires_at <= NOW() THEN
        RAISE EXCEPTION 'no active pinned location';
    END IF;

    v_new_expiry := v_row.pinned_expires_at + (p_extra_seconds || ' seconds')::INTERVAL;
    v_max_expiry := COALESCE(v_row.pinned_created_at, NOW()) + INTERVAL '30 days';

    IF v_new_expiry > v_max_expiry THEN
        RAISE EXCEPTION 'extension exceeds 30-day maximum pinned time';
    END IF;

    UPDATE public.user_locations
    SET pinned_expires_at = v_new_expiry,
        updated_at = NOW()
    WHERE user_id = p_user_id;

    RETURN v_new_expiry;
END;
$$;

GRANT EXECUTE ON FUNCTION public.extend_pinned_location(UUID, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.extend_pinned_location(UUID, INT) TO service_role;

-- Unpin and force a fresh-GPS state: mark the row stale so the user stays
-- invisible until the next live GPS write arrives (avoids one false match
-- at the old pin). Online heartbeat is preserved.
CREATE OR REPLACE FUNCTION public.unpin_location(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.user_locations
    SET is_pinned = FALSE,
        pinned_expires_at = NULL,
        pinned_created_at = NULL,
        pinned_label = NULL,
        updated_at = NOW() - INTERVAL '16 minutes'
    WHERE user_id = p_user_id;

    PERFORM public.update_user_activity(p_user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.unpin_location(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unpin_location(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Guard: live GPS must never overwrite an active pin.
--    Keeps the deleted-user early return from 20260413000000.
--    Signature unchanged so all existing callers keep working.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_user_location(
    p_user_id UUID,
    p_latitude DOUBLE PRECISION,
    p_longitude DOUBLE PRECISION,
    p_speed DOUBLE PRECISION DEFAULT NULL,
    p_heading DOUBLE PRECISION DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    user_exists BOOLEAN;
    pinned_active BOOLEAN;
BEGIN
    -- Deleted users: silently return (see 20260413000000).
    SELECT EXISTS(SELECT 1 FROM public.users WHERE id = p_user_id)
    INTO user_exists;

    IF NOT user_exists THEN
        RETURN;
    END IF;

    -- Active pin: keep heartbeat only, never touch coordinates.
    SELECT COALESCE(
        (SELECT (ul.is_pinned = TRUE AND ul.pinned_expires_at > NOW())
         FROM public.user_locations ul
         WHERE ul.user_id = p_user_id),
        FALSE
    )
    INTO pinned_active;

    IF pinned_active THEN
        PERFORM public.update_user_activity(p_user_id);
        RETURN;
    END IF;

    -- No active pin (or pin already expired): normal live write.
    -- An expired pin flag is cleared here so the row returns to live mode
    -- even if the client never calls unpin_location().
    INSERT INTO public.user_locations (user_id, latitude, longitude, speed, heading, updated_at)
    VALUES (p_user_id, p_latitude, p_longitude, p_speed, p_heading, NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET
        latitude = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude,
        speed = EXCLUDED.speed,
        heading = EXCLUDED.heading,
        updated_at = NOW(),
        is_pinned = FALSE,
        pinned_expires_at = NULL,
        pinned_created_at = NULL,
        pinned_label = NULL;

    PERFORM public.update_user_activity(p_user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_user_location(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_location(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO anon;
GRANT EXECUTE ON FUNCTION public.update_user_location(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO service_role;
