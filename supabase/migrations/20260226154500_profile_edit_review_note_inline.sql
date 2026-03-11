BEGIN;

CREATE OR REPLACE FUNCTION public.enqueue_profile_edit_request_review_fcm()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_allowed boolean;
  v_locale text;
  v_fields text[];
  v_title_key text;
  v_body_key text;
  v_title text;
  v_body_template text;
  v_body text;
  v_note text;
  v_note_line_template text;
  v_note_line text;
  v_token text;
  v_platform text;
  v_field text;
  v_label_key text;
  v_label text;
  v_labels text[] := '{}'::text[];
  v_fields_text text := '';
BEGIN
  IF TG_OP <> 'UPDATE' THEN
    RETURN NEW;
  END IF;

  IF NEW.status IS NULL OR OLD.status IS NULL OR NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status NOT IN ('approved', 'rejected') THEN
    RETURN NEW;
  END IF;

  v_fields := ARRAY(
    SELECT f
    FROM unnest(COALESCE(NEW.requested_fields, '{}'::text[])) AS t(f)
    WHERE f IN ('name', 'gender', 'date_of_birth')
  );

  IF COALESCE(array_length(v_fields, 1), 0) = 0 THEN
    RETURN NEW;
  END IF;

  SELECT (
    COALESCE((u.notification_preferences->'global_methods'->>'push')::boolean, true) = true
    AND COALESCE(
      (u.notification_preferences->'matrix'->'admin_announcements'->>'push')::boolean,
      (u.notification_preferences->>'enable_admin_notifications')::boolean,
      true
    ) = true
  )
  , lower(btrim(COALESCE(u.preferred_language, 'en')))
  INTO v_allowed, v_locale
  FROM public.users u
  WHERE u.id = NEW.user_id;

  IF NOT COALESCE(v_allowed, false) THEN
    RETURN NEW;
  END IF;

  IF v_locale NOT IN ('en', 'es', 'he') THEN
    v_locale := 'en';
  END IF;

  FOREACH v_field IN ARRAY v_fields
  LOOP
    v_label_key := CASE v_field
      WHEN 'name' THEN 'profileEditFieldLabelName'
      WHEN 'gender' THEN 'profileEditFieldLabelGender'
      WHEN 'date_of_birth' THEN 'profileEditFieldLabelDateOfBirth'
      ELSE NULL
    END;

    v_label := NULL;
    IF v_label_key IS NOT NULL THEN
      SELECT t.value INTO v_label
      FROM public.translations t
      WHERE t.locale = v_locale
        AND t.key = v_label_key;

      IF v_label IS NULL THEN
        SELECT t.value INTO v_label
        FROM public.translations t
        WHERE t.locale = 'en'
          AND t.key = v_label_key;
      END IF;
    END IF;

    IF v_label IS NULL THEN
      v_label := v_field;
    END IF;

    v_labels := array_append(v_labels, v_label);
  END LOOP;

  v_fields_text := array_to_string(v_labels, ', ');

  v_title_key := CASE
    WHEN NEW.status = 'approved' THEN 'profileEditRequestApprovedNotifTitle'
    ELSE 'profileEditRequestRejectedNotifTitle'
  END;

  v_body_key := CASE
    WHEN NEW.status = 'approved' THEN 'profileEditRequestApprovedNotifBody'
    ELSE 'profileEditRequestRejectedNotifBody'
  END;

  SELECT t.value
  INTO v_title
  FROM public.translations t
  WHERE t.locale = v_locale
    AND t.key = v_title_key;

  IF v_title IS NULL THEN
    SELECT t.value
    INTO v_title
    FROM public.translations t
    WHERE t.locale = 'en'
      AND t.key = v_title_key;
  END IF;

  SELECT t.value
  INTO v_body_template
  FROM public.translations t
  WHERE t.locale = v_locale
    AND t.key = v_body_key;

  IF v_body_template IS NULL THEN
    SELECT t.value
    INTO v_body_template
    FROM public.translations t
    WHERE t.locale = 'en'
      AND t.key = v_body_key;
  END IF;

  IF v_title IS NULL THEN
    v_title := CASE
      WHEN NEW.status = 'approved' THEN 'Profile edit request approved'
      ELSE 'Profile edit request rejected'
    END;
  END IF;

  IF v_body_template IS NULL THEN
    v_body_template := CASE
      WHEN NEW.status = 'approved' THEN 'An admin approved your profile edit request for {fields}.'
      ELSE 'An admin rejected your profile edit request for {fields}.'
    END;
  END IF;

  v_body := replace(v_body_template, '{fields}', v_fields_text);

  v_note := NULLIF(btrim(COALESCE(NEW.reviewer_note, '')), '');
  IF v_note IS NOT NULL THEN
    SELECT t.value
    INTO v_note_line_template
    FROM public.translations t
    WHERE t.locale = v_locale
      AND t.key = 'profileEditRequestReviewerNoteLine';

    IF v_note_line_template IS NULL THEN
      SELECT t.value
      INTO v_note_line_template
      FROM public.translations t
      WHERE t.locale = 'en'
        AND t.key = 'profileEditRequestReviewerNoteLine';
    END IF;

    IF v_note_line_template IS NULL THEN
      v_note_line_template := 'Admin note: {note}';
    END IF;

    v_note_line := replace(v_note_line_template, '{note}', v_note);
    v_body := v_body || ' ' || v_note_line;
  END IF;

  FOR v_token, v_platform IN
    SELECT DISTINCT ON (NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''))
      NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') AS fcm_token,
      us.platform
    FROM public.user_session us
    WHERE us.user_id = NEW.user_id
      AND us.revoked = false
      AND NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), '') IS NOT NULL
    ORDER BY NULLIF(btrim(COALESCE(us.metadata->>'fcm_token', '')), ''), us.last_active_at DESC NULLS LAST
  LOOP
    INSERT INTO public.notification_queue (
      user_id,
      fcm_token,
      title,
      body,
      data,
      platform
    )
    VALUES (
      NEW.user_id,
      v_token,
      v_title,
      v_body,
      jsonb_build_object(
        'type', 'profile_edit_review',
        'request_id', NEW.id::text,
        'decision', NEW.status,
        'fields', v_fields,
        'reviewer_note', v_note
      ),
      COALESCE(NULLIF(btrim(v_platform), ''), 'unknown')
    );
  END LOOP;

  RETURN NEW;
EXCEPTION WHEN others THEN
  RETURN NEW;
END;
$$;

COMMIT;

