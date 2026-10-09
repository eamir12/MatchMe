-- Allow each user to report a classifier false positive once per event,
-- rather than consuming one feedback slot for the entire account.
BEGIN;

ALTER TABLE public.event_import_feedback
  ADD COLUMN IF NOT EXISTS event_key text;

-- Existing reports with a snapshot can be matched to future submissions by
-- provider/calendar/event identity. Legacy rows without usable identity get a
-- row-specific key and do not block feedback for unrelated events.
UPDATE public.event_import_feedback
SET event_key = CASE
  WHEN COALESCE(event_snapshot->>'external_event_id', '') <> '' THEN
    md5(
      lower(trim(COALESCE(
        event_snapshot->>'external_provider',
        provider,
        ''
      )))
      || '|'
      || trim(COALESCE(event_snapshot->>'external_calendar_id', ''))
      || '|'
      || trim(event_snapshot->>'external_event_id')
    )
  ELSE md5('legacy|' || id::text)
END
WHERE event_key IS NULL;

ALTER TABLE public.event_import_feedback
  ALTER COLUMN event_key SET NOT NULL;

ALTER TABLE public.event_import_feedback
  DROP CONSTRAINT IF EXISTS event_import_feedback_user_id_unique;
ALTER TABLE public.event_import_feedback
  DROP CONSTRAINT IF EXISTS event_import_feedback_user_event_unique;
ALTER TABLE public.event_import_feedback
  ADD CONSTRAINT event_import_feedback_user_event_unique
  UNIQUE (user_id, event_key);

DROP FUNCTION IF EXISTS public.event_import_feedback_has_reported();

CREATE FUNCTION public.event_import_feedback_has_reported(p_event_key text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_event_key IS NULL OR p_event_key !~ '^[0-9a-f]{32}$' THEN
    RAISE EXCEPTION 'invalid event key';
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.event_import_feedback
    WHERE user_id = auth.uid()
      AND event_key = p_event_key
  );
END;
$$;

REVOKE ALL ON FUNCTION public.event_import_feedback_has_reported(text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.event_import_feedback_has_reported(text)
  TO authenticated;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'importBlockSheetFeedbackAlreadyUsed', 'You’ve already sent feedback for this event. Thanks for helping us improve!'),
  ('he', 'importBlockSheetFeedbackAlreadyUsed', 'כבר שלחת משוב על האירוע הזה. תודה שאתה עוזר לנו להשתפר!'),
  ('es', 'importBlockSheetFeedbackAlreadyUsed', 'Ya enviaste comentarios sobre este evento. ¡Gracias por ayudarnos a mejorar!')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
