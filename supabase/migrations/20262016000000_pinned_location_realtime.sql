-- Migration: Pinned home-base realtime for match partners (step 3)
-- Date: 2026-09-29
-- Purpose: When user A pins/unpins, user B must see it IMMEDIATELY in the
--          match row + match profile. user_locations RLS only allows reading
--          your OWN row, so B can never receive postgres_changes for A's row
--          directly. The Flutter client therefore uses a public Broadcast
--          channel (pinned_location_updates/pinned_changed) + RPC refresh.
--          This migration adds a server-side safety net so even server-driven
--          changes (cron expiry while the actor is offline) still notify:
--            * users.is_pinned_location_active + users.pinned_expires_at mirror
--              the user_locations pin via trigger (users IS SELECT-readable by
--              all authenticated + in the realtime publication).
--            * Viewers already subscribe to users UPDATEs (see
--              pinned_partner_provider.dart) and refresh via the SECURITY
--              DEFINER is_pinned_location_active RPC.
-- Privacy: only the boolean flag + expiry are mirrored. Coordinates NEVER
--          touch users. The flag was already queryable by any authenticated
--          user via is_pinned_location_active(), so no new leak.

-- ---------------------------------------------------------------------------
-- 1. Mirror columns on users (idempotent)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users'
        AND column_name = 'is_pinned_location_active'
    ) THEN
        ALTER TABLE public.users
            ADD COLUMN is_pinned_location_active BOOLEAN NOT NULL DEFAULT FALSE;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users'
        AND column_name = 'pinned_expires_at'
    ) THEN
        ALTER TABLE public.users
            ADD COLUMN pinned_expires_at TIMESTAMPTZ NULL;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_users_pinned_active
    ON public.users (is_pinned_location_active)
    WHERE is_pinned_location_active = TRUE;

-- ---------------------------------------------------------------------------
-- 2. Trigger: mirror user_locations pin -> users (only on real pin changes)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_pinned_location_to_users()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_active BOOLEAN;
    v_expires TIMESTAMPTZ;
BEGIN
    -- DELETE (account removal): clear the mirror so partners converge to false.
    IF TG_OP = 'DELETE' THEN
        UPDATE public.users
        SET is_pinned_location_active = FALSE,
            pinned_expires_at = NULL
        WHERE id = OLD.user_id
          AND (
            is_pinned_location_active IS DISTINCT FROM FALSE
            OR pinned_expires_at IS NOT NULL
          );
        RETURN OLD;
    END IF;

    v_expires := NEW.pinned_expires_at;
    v_active := (
        COALESCE(NEW.is_pinned, FALSE) = TRUE
        AND v_expires IS NOT NULL
        AND v_expires > NOW()
    );

    -- Only touch users when the visible pin state actually changed. This
    -- avoids spamming users-realtime on every GPS heartbeat:
    -- touch_active_pinned_locations() bumps user_locations.updated_at every
    -- ~4 min WITHOUT changing is_pinned/pinned_expires_at.
    IF TG_OP = 'INSERT'
       OR OLD.is_pinned IS DISTINCT FROM NEW.is_pinned
       OR OLD.pinned_expires_at IS DISTINCT FROM NEW.pinned_expires_at
    THEN
        UPDATE public.users
        SET is_pinned_location_active = v_active,
            pinned_expires_at = v_expires
        WHERE id = NEW.user_id
          AND (
            is_pinned_location_active IS DISTINCT FROM v_active
            OR pinned_expires_at IS DISTINCT FROM v_expires
          );
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_pinned_to_users ON public.user_locations;
CREATE TRIGGER trg_sync_pinned_to_users
    AFTER INSERT OR UPDATE OR DELETE ON public.user_locations
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_pinned_location_to_users();

-- ---------------------------------------------------------------------------
-- 3. Backfill existing pins (one-shot)
-- ---------------------------------------------------------------------------
UPDATE public.users u
SET is_pinned_location_active = COALESCE((
        SELECT (ul.is_pinned = TRUE AND ul.pinned_expires_at > NOW())
        FROM public.user_locations ul
        WHERE ul.user_id = u.id
    ), FALSE),
    pinned_expires_at = (
        SELECT ul.pinned_expires_at
        FROM public.user_locations ul
        WHERE ul.user_id = u.id
    )
WHERE EXISTS (
    SELECT 1 FROM public.user_locations ul WHERE ul.user_id = u.id
);

-- Users without any user_locations row: ensure mirror is false/null.
UPDATE public.users u
SET is_pinned_location_active = FALSE,
    pinned_expires_at = NULL
WHERE NOT EXISTS (
    SELECT 1 FROM public.user_locations ul WHERE ul.user_id = u.id
)
AND (
    u.is_pinned_location_active IS DISTINCT FROM FALSE
    OR u.pinned_expires_at IS NOT NULL
);

-- ---------------------------------------------------------------------------
-- 4. Realtime publication (idempotent; users already added in
--    20260627000002, user_locations in 20260813000000 — kept here so a fresh
--    DB still notifies).
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'users'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.users;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'user_locations'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.user_locations;
    END IF;
END $$;
