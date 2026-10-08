-- Migration: Imported feedback rows disappear when their event is removed
--
-- When an imported event is completely removed (e.g. its only attendee —
-- the user it was imported for — leaves it and trg_delete_event_when_empty
-- fires), the feedback row must not linger in the admin Event Feedback
-- area as "Imported" pointing at nothing. The feedback report's lifecycle
-- ends with the event: the row is deleted, which also frees the
-- reporter's one-feedback-per-user slot (their report was fully handled).
BEGIN;

CREATE OR REPLACE FUNCTION public.delete_event_when_last_attendee_leaves()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.event_attendees a
    WHERE a.event_id = OLD.event_id
  ) THEN
    -- Feedback rows imported into this event: the report's lifecycle ends
    -- with the event (also frees the reporter's feedback slot).
    DELETE FROM public.event_import_feedback f
    WHERE f.imported_event_id = OLD.event_id;

    -- Defensive: event matches reference the event; drop them first so a
    -- foreign key can't block the deletion.
    DELETE FROM public.matches m
    WHERE m.event_id = OLD.event_id
      AND m.match_type = 'event';

    BEGIN
      DELETE FROM public.events e WHERE e.id = OLD.event_id;
    EXCEPTION WHEN OTHERS THEN
      -- Never block the leave itself; leaving a zombie behind is the
      -- pre-trigger status quo and can be cleaned up later.
      NULL;
    END;
  END IF;
  RETURN OLD;
END;
$$;

-- List RPC: never surface imported rows whose event no longer exists
-- (defensive; the trigger above should already have removed them).
CREATE OR REPLACE FUNCTION public.admin_list_event_import_feedback(
  p_status text DEFAULT NULL,
  p_query text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  user_name text,
  block_reason text,
  event_title text,
  provider text,
  app_locale text,
  event_snapshot jsonb,
  status text,
  imported_event_id uuid,
  reviewed_at timestamptz,
  reviewed_by uuid,
  reviewer_name text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_status text;
  v_query text;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.is_admin = true
  ) INTO v_is_admin;
  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_status := NULLIF(trim(p_status), '');
  v_query := NULLIF(trim(p_query), '');

  RETURN QUERY
  SELECT
    f.id,
    f.user_id,
    u.name AS user_name,
    f.block_reason,
    f.event_title,
    f.provider,
    f.app_locale,
    f.event_snapshot,
    f.status,
    f.imported_event_id,
    f.reviewed_at,
    f.reviewed_by,
    COALESCE(ru.name, '') AS reviewer_name,
    f.created_at
  FROM public.event_import_feedback f
  JOIN public.users u ON u.id = f.user_id
  LEFT JOIN public.users ru ON ru.id = f.reviewed_by
  WHERE (v_status IS NULL OR v_status = 'all' OR f.status = v_status)
    AND (
      f.status <> 'imported'
      OR f.imported_event_id IS NULL
      OR EXISTS (
        SELECT 1 FROM public.events e WHERE e.id = f.imported_event_id
      )
    )
    AND (
      v_query IS NULL OR
      COALESCE(f.event_title, '') ILIKE '%' || v_query || '%' OR
      COALESCE(u.name, '') ILIKE '%' || v_query || '%' OR
      f.user_id::text ILIKE '%' || v_query || '%'
    )
  ORDER BY f.created_at DESC, f.id DESC
  LIMIT GREATEST(LEAST(COALESCE(p_limit, 100), 500), 1)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
END;
$$;

-- One-time cleanup: drop feedback rows imported into events that no
-- longer exist (orphans created before the trigger extension above).
DELETE FROM public.event_import_feedback f
WHERE f.status = 'imported'
  AND f.imported_event_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.events e WHERE e.id = f.imported_event_id
  );

COMMIT;
