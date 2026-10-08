-- Migration: Admin review of event-import feedback + one feedback per user
--
-- Complements the calendar-import privacy classifier feedback loop:
--  * each user can report at most one "this event is actually public"
--    (unique constraint on user_id, plus an RPC the app uses to show
--    appropriate messaging),
--  * feedback rows carry an event_snapshot (scrubbed event fields captured
--    at block time) so an admin can review and, if the event is deemed
--    public, import it into the reporter's MatchMe events via
--    admin_review_event_import_feedback (mirrors the client import: insert
--    into events + event_attendees; existing triggers handle matching),
--  * admin listing/review goes through security-definer admin_* RPCs —
--    the table itself stays insert-only for clients.
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. One feedback per user
-- ---------------------------------------------------------------------------

-- Anonymous rows can never be attributed or reviewed.
DELETE FROM public.event_import_feedback WHERE user_id IS NULL;

-- Keep only the latest row per user (defensive; table is new).
DELETE FROM public.event_import_feedback f
WHERE EXISTS (
  SELECT 1
  FROM public.event_import_feedback g
  WHERE g.user_id = f.user_id
    AND (g.created_at > f.created_at
         OR (g.created_at = f.created_at AND g.id > f.id))
);

ALTER TABLE public.event_import_feedback
  ALTER COLUMN user_id SET NOT NULL;

ALTER TABLE public.event_import_feedback
  DROP CONSTRAINT IF EXISTS event_import_feedback_user_id_unique;
ALTER TABLE public.event_import_feedback
  ADD CONSTRAINT event_import_feedback_user_id_unique UNIQUE (user_id);

-- ---------------------------------------------------------------------------
-- 2. Event snapshot + admin review state
-- ---------------------------------------------------------------------------

ALTER TABLE public.event_import_feedback
  ADD COLUMN IF NOT EXISTS event_snapshot jsonb,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS imported_event_id uuid,
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS reviewed_by uuid REFERENCES auth.users (id) ON DELETE SET NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'event_import_feedback_status_check'
      AND conrelid = 'public.event_import_feedback'::regclass
  ) THEN
    ALTER TABLE public.event_import_feedback
      ADD CONSTRAINT event_import_feedback_status_check
      CHECK (status IN ('pending', 'imported', 'dismissed'));
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS event_import_feedback_status_created_idx
  ON public.event_import_feedback (status, created_at DESC);

-- ---------------------------------------------------------------------------
-- 3. Client RPC: has this user already reported feedback?
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.event_import_feedback_has_reported()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.event_import_feedback
    WHERE user_id = auth.uid()
  );
$$;

REVOKE ALL ON FUNCTION public.event_import_feedback_has_reported() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.event_import_feedback_has_reported() TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Admin RPCs (same security-definer pattern as other admin_* functions)
-- ---------------------------------------------------------------------------

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

REVOKE ALL ON FUNCTION public.admin_list_event_import_feedback(text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_event_import_feedback(text, text, integer, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_review_event_import_feedback(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_review_event_import_feedback(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Translations for the new client + admin strings (en fallbacks in code)
-- ---------------------------------------------------------------------------

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'importBlockSheetFeedbackAlreadyUsed', 'You’ve already sent feedback. Thanks for helping us improve!'),
  ('en', 'adminNavEventFeedback', 'Event Feedback'),
  ('en', 'adminEventFeedbackEmpty', 'No import feedback yet.'),
  ('en', 'adminEventFeedbackSearchHint', 'Search title or user'),
  ('en', 'adminEventFeedbackFilterAll', 'All'),
  ('en', 'adminEventFeedbackFilterPending', 'Pending'),
  ('en', 'adminEventFeedbackFilterImported', 'Imported'),
  ('en', 'adminEventFeedbackFilterDismissed', 'Dismissed'),
  ('en', 'adminEventFeedbackImportButton', 'Import event'),
  ('en', 'adminEventFeedbackDismissButton', 'Dismiss'),
  ('en', 'adminEventFeedbackSnapshotTitle', 'Event details'),
  ('en', 'adminEventFeedbackReportedBy', 'Reported by {name}'),
  ('en', 'adminEventFeedbackBlockReason', 'Blocked as: {reason}'),
  ('en', 'adminEventFeedbackProvider', 'Source: {provider}'),
  ('en', 'adminEventFeedbackStart', 'Start: {start}'),
  ('en', 'adminEventFeedbackReviewedBy', 'Reviewed by {name}'),
  ('en', 'adminEventFeedbackImportSuccess', 'Event imported for the user.'),
  ('en', 'adminEventFeedbackDismissSuccess', 'Feedback dismissed.'),
  ('en', 'adminEventFeedbackErrorGeneric', 'The action failed. Try again.'),
  ('en', 'adminEventFeedbackErrorStartInPast', 'The event date has passed and can no longer be imported.'),
  ('en', 'adminEventFeedbackErrorAlreadyReviewed', 'This feedback was already reviewed.'),
  ('en', 'adminEventFeedbackErrorNoSnapshot', 'This feedback has no importable event data.'),
  ('en', 'adminEventFeedbackErrorNotFound', 'This feedback no longer exists.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'importBlockSheetFeedbackAlreadyUsed', 'כבר שלחת משוב. תודה שאתה עוזר לנו להשתפר!'),
  ('he', 'adminNavEventFeedback', 'משוב אירועים'),
  ('he', 'adminEventFeedbackEmpty', 'אין עדיין משוב על ייבוא אירועים.'),
  ('he', 'adminEventFeedbackSearchHint', 'חיפוש לפי כותרת או משתמש'),
  ('he', 'adminEventFeedbackFilterAll', 'הכול'),
  ('he', 'adminEventFeedbackFilterPending', 'ממתין'),
  ('he', 'adminEventFeedbackFilterImported', 'יובא'),
  ('he', 'adminEventFeedbackFilterDismissed', 'נדחה'),
  ('he', 'adminEventFeedbackImportButton', 'ייבוא האירוע'),
  ('he', 'adminEventFeedbackDismissButton', 'סגירה'),
  ('he', 'adminEventFeedbackSnapshotTitle', 'פרטי האירוע'),
  ('he', 'adminEventFeedbackReportedBy', 'דווח על ידי {name}'),
  ('he', 'adminEventFeedbackBlockReason', 'נחסם כ: {reason}'),
  ('he', 'adminEventFeedbackProvider', 'מקור: {provider}'),
  ('he', 'adminEventFeedbackStart', 'התחלה: {start}'),
  ('he', 'adminEventFeedbackReviewedBy', 'נבדק על ידי {name}'),
  ('he', 'adminEventFeedbackImportSuccess', 'האירוע יובא עבור המשתמש.'),
  ('he', 'adminEventFeedbackDismissSuccess', 'המשוב נסגר.'),
  ('he', 'adminEventFeedbackErrorGeneric', 'הפעולה נכשלה. נסה שוב.'),
  ('he', 'adminEventFeedbackErrorStartInPast', 'תאריך האירוע עבר ולא ניתן עוד לייבא אותו.'),
  ('he', 'adminEventFeedbackErrorAlreadyReviewed', 'המשוב הזה כבר נבדק.'),
  ('he', 'adminEventFeedbackErrorNoSnapshot', 'למשוב הזה אין נתוני אירוע לייבוא.'),
  ('he', 'adminEventFeedbackErrorNotFound', 'המשוב הזה כבר לא קיים.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'importBlockSheetFeedbackAlreadyUsed', 'Ya enviaste comentarios. ¡Gracias por ayudarnos a mejorar!'),
  ('es', 'adminNavEventFeedback', 'Comentarios de eventos'),
  ('es', 'adminEventFeedbackEmpty', 'Aún no hay comentarios de importación.'),
  ('es', 'adminEventFeedbackSearchHint', 'Buscar por título o usuario'),
  ('es', 'adminEventFeedbackFilterAll', 'Todos'),
  ('es', 'adminEventFeedbackFilterPending', 'Pendiente'),
  ('es', 'adminEventFeedbackFilterImported', 'Importado'),
  ('es', 'adminEventFeedbackFilterDismissed', 'Descartado'),
  ('es', 'adminEventFeedbackImportButton', 'Importar evento'),
  ('es', 'adminEventFeedbackDismissButton', 'Descartar'),
  ('es', 'adminEventFeedbackSnapshotTitle', 'Detalles del evento'),
  ('es', 'adminEventFeedbackReportedBy', 'Reportado por {name}'),
  ('es', 'adminEventFeedbackBlockReason', 'Bloqueado como: {reason}'),
  ('es', 'adminEventFeedbackProvider', 'Fuente: {provider}'),
  ('es', 'adminEventFeedbackStart', 'Inicio: {start}'),
  ('es', 'adminEventFeedbackReviewedBy', 'Revisado por {name}'),
  ('es', 'adminEventFeedbackImportSuccess', 'Evento importado para el usuario.'),
  ('es', 'adminEventFeedbackDismissSuccess', 'Comentario descartado.'),
  ('es', 'adminEventFeedbackErrorGeneric', 'La acción falló. Inténtalo de nuevo.'),
  ('es', 'adminEventFeedbackErrorStartInPast', 'La fecha del evento ya pasó y ya no se puede importar.'),
  ('es', 'adminEventFeedbackErrorAlreadyReviewed', 'Este comentario ya fue revisado.'),
  ('es', 'adminEventFeedbackErrorNoSnapshot', 'Este comentario no tiene datos de evento para importar.'),
  ('es', 'adminEventFeedbackErrorNotFound', 'Este comentario ya no existe.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
