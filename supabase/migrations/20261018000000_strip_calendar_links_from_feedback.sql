-- Migration: Never let calendar-provider deep-links into imported events
--
-- The Outlook webLink (outlook.live.com/owa/?itemid=…) is a private,
-- authenticated pointer into the reporter's own mailbox — it must never
-- become a public event's link. The client now captures only usable
-- public links in feedback snapshots; this migration hardens the admin
-- import RPC with the same rule (defense in depth) and cleans up
-- provider-calendar links already stored in snapshots.
--
-- Also adds the adminEventFeedbackOpenLink translation (the dashboard
-- shows a launchable "Open event link" button instead of the raw URL).
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_review_event_import_feedback(
  p_feedback_id uuid,
  p_decision text
)
RETURNS uuid  -- the imported event id (NULL when dismissed)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'UTC'  -- match PostgREST's session TZ so naive ISO strings
                      -- from the client are stored exactly as the app's own
                      -- imports store them (dedupe equality depends on this)
AS $$
DECLARE
  v_is_admin boolean;
  v_decision text;
  v_row public.event_import_feedback%ROWTYPE;
  v_snapshot jsonb;
  v_name text;
  v_venue text;
  v_link text;
  v_link_host text;
  v_description text;
  v_start timestamptz;
  v_end timestamptz;
  v_is_all_day boolean;
  v_existing_event uuid;
  v_new_event uuid;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.is_admin = true
  ) INTO v_is_admin;
  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_decision := lower(coalesce(trim(p_decision), ''));
  IF v_decision NOT IN ('imported', 'dismissed') THEN
    RAISE EXCEPTION 'invalid decision';
  END IF;

  SELECT * INTO v_row
  FROM public.event_import_feedback
  WHERE id = p_feedback_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'feedback_not_found';
  END IF;
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION 'feedback_already_reviewed';
  END IF;

  IF v_decision = 'dismissed' THEN
    UPDATE public.event_import_feedback
       SET status = 'dismissed',
           reviewed_at = now(),
           reviewed_by = auth.uid()
     WHERE id = p_feedback_id;
    RETURN NULL;
  END IF;

  -- --- import path: mirror the client's addEventWithResult -----------------

  v_snapshot := v_row.event_snapshot;
  IF v_snapshot IS NULL THEN
    RAISE EXCEPTION 'feedback_missing_event_snapshot';
  END IF;

  v_name := coalesce(v_snapshot->>'event_name', '');
  v_venue := coalesce(v_snapshot->>'event_venue', '');
  v_description := coalesce(v_snapshot->>'event_description', '');
  v_link := nullif(btrim(coalesce(v_snapshot->>'event_link', '')), '');

  -- Scrub PII the same way the client does before saving.
  v_name := btrim(regexp_replace(
    regexp_replace(v_name, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '', 'g'),
    '\+?\d[\d\s().-]{6,}\d', '', 'g'));
  v_name := btrim(regexp_replace(v_name, '\s+', ' ', 'g'));
  v_name := left(v_name, 180);

  v_venue := btrim(regexp_replace(
    regexp_replace(v_venue, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '', 'g'),
    '\+?\d[\d\s().-]{6,}\d', '', 'g'));
  v_venue := btrim(regexp_replace(v_venue, '\s+', ' ', 'g'));
  v_venue := left(v_venue, 180);

  v_description := btrim(regexp_replace(v_description, '\s+', ' ', 'g'));
  v_description := left(v_description, 2000);

  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION 'feedback_missing_event_name';
  END IF;

  -- Only http(s) links, fragment stripped, capped like the client.
  IF v_link IS NOT NULL AND v_link !~* '^https?://' THEN
    v_link := NULL;
  END IF;
  IF v_link IS NOT NULL THEN
    v_link := left(regexp_replace(v_link, '#.*$', ''), 600);
    IF v_link = '' THEN v_link := NULL; END IF;
  END IF;

  -- Calendar-provider deep-links (Outlook OWA, Google Calendar, Apple ICS)
  -- are private pointers into the reporter's mailbox/calendar — same rule
  -- as the client's usableImportLink. Never import them as public links.
  IF v_link IS NOT NULL THEN
    v_link_host := lower(split_part(split_part(v_link, '://', 2), '/', 1));
    IF v_link_host LIKE '%outlook.%'
       OR v_link_host LIKE '%office.%'
       OR v_link_host LIKE '%live.%'
       OR v_link_host LIKE '%calendar.google.%'
       OR v_link_host LIKE '%icloud.%'
       OR (v_link_host LIKE '%microsoft.%' AND v_link ILIKE '%/calendar/%')
       OR lower(v_link) LIKE '%.ics%'
    THEN
      v_link := NULL;
    END IF;
  END IF;

  v_start := (v_snapshot->>'start_time')::timestamptz;
  IF v_start IS NULL THEN
    RAISE EXCEPTION 'feedback_missing_start_time';
  END IF;
  -- Same 30-minute grace the app enforces for new events.
  IF v_start < now() - interval '30 minutes' THEN
    RAISE EXCEPTION 'feedback_event_start_in_past';
  END IF;
  v_end := COALESCE((v_snapshot->>'end_time')::timestamptz,
                    v_start + interval '1 hour');
  v_is_all_day := COALESCE((v_snapshot->>'is_all_day')::boolean, false);

  -- Dedupe against existing public events (same start + same name, venue
  -- equal or contained) so the user joins an existing event instead of
  -- creating a duplicate.
  SELECT e.id INTO v_existing_event
  FROM public.events e
  WHERE e.start_time = v_start
    AND lower(btrim(coalesce(e.event_name, ''))) = lower(v_name)
    AND (
      COALESCE(lower(btrim(coalesce(e.event_venue, ''))), '')
        = COALESCE(lower(btrim(v_venue)), '')
      OR (
        COALESCE(btrim(v_venue), '') <> ''
        AND COALESCE(btrim(coalesce(e.event_venue, '')), '') <> ''
        AND (
          position(lower(btrim(e.event_venue)) IN lower(v_venue)) > 0 OR
          position(lower(btrim(v_venue)) IN lower(btrim(e.event_venue))) > 0
        )
      )
    )
  LIMIT 1;

  IF v_existing_event IS NULL THEN
    INSERT INTO public.events (
      event_name, event_venue, start_time, end_time, event_link,
      external_calendar_id, external_event_id, external_provider,
      is_all_day, description
    ) VALUES (
      v_name,
      NULLIF(v_venue, ''),
      v_start,
      v_end,
      v_link,
      NULLIF(btrim(coalesce(v_snapshot->>'external_calendar_id', '')), ''),
      NULLIF(btrim(coalesce(v_snapshot->>'external_event_id', '')), ''),
      NULLIF(btrim(coalesce(v_snapshot->>'external_provider', '')), ''),
      v_is_all_day,
      NULLIF(v_description, '')
    )
    RETURNING id INTO v_new_event;
    v_existing_event := v_new_event;
  END IF;

  BEGIN
    INSERT INTO public.event_attendees (event_id, user_id)
    VALUES (v_existing_event, v_row.user_id);
  EXCEPTION WHEN unique_violation THEN
    -- User already attends the matched event; still a success.
    NULL;
  END;

  UPDATE public.event_import_feedback
     SET status = 'imported',
         imported_event_id = v_existing_event,
         reviewed_at = now(),
         reviewed_by = auth.uid()
   WHERE id = p_feedback_id;

  RETURN v_existing_event;
END;
$$;

-- One-time cleanup: drop provider-calendar deep-links from snapshots
-- captured before the client-side filtering existed.
UPDATE public.event_import_feedback
SET event_snapshot = event_snapshot - 'event_link'
WHERE event_snapshot ? 'event_link'
  AND (
    lower(split_part(split_part(event_snapshot->>'event_link', '://', 2), '/', 1))
      LIKE ANY (ARRAY['%outlook.%', '%office.%', '%live.%', '%calendar.google.%', '%icloud.%'])
    OR (
      lower(split_part(split_part(event_snapshot->>'event_link', '://', 2), '/', 1))
        LIKE '%microsoft.%'
      AND lower(event_snapshot->>'event_link') LIKE '%/calendar/%'
    )
    OR lower(event_snapshot->>'event_link') LIKE '%.ics%'
  );

-- Translation for the launchable link button in the admin dashboard.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminEventFeedbackOpenLink', 'Open event link'),
  ('he', 'adminEventFeedbackOpenLink', 'פתיחת קישור האירוע'),
  ('es', 'adminEventFeedbackOpenLink', 'Abrir enlace del evento')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
