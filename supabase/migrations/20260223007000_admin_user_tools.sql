BEGIN;

CREATE OR REPLACE FUNCTION public.block_protected_user_fields_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  jwt_role text;
  v_is_admin boolean;
BEGIN
  jwt_role := current_setting('request.jwt.claim.role', true);

  IF jwt_role IS NULL THEN
    RETURN NEW;
  END IF;

  IF jwt_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF COALESCE(v_is_admin, false) THEN
    RETURN NEW;
  END IF;

  IF (
    NEW.is_verified IS DISTINCT FROM OLD.is_verified OR
    NEW.verification_status IS DISTINCT FROM OLD.verification_status OR
    NEW.verification_photo_path IS DISTINCT FROM OLD.verification_photo_path OR
    NEW.verification_submitted_at IS DISTINCT FROM OLD.verification_submitted_at OR
    NEW.verification_reviewed_at IS DISTINCT FROM OLD.verification_reviewed_at OR
    NEW.verification_reviewer_id IS DISTINCT FROM OLD.verification_reviewer_id OR
    NEW.verification_similarity_score IS DISTINCT FROM OLD.verification_similarity_score OR
    NEW.verification_ai_analysis IS DISTINCT FROM OLD.verification_ai_analysis OR
    NEW.verification_auto_rejected IS DISTINCT FROM OLD.verification_auto_rejected OR
    NEW.approved_primary_photos IS DISTINCT FROM OLD.approved_primary_photos
  ) THEN
    RAISE EXCEPTION 'protected_user_fields_update_not_allowed';
  END IF;

  RETURN NEW;
END;
$$;

ALTER TABLE IF EXISTS public.users
  ADD COLUMN IF NOT EXISTS editable_profile_fields text[] NOT NULL DEFAULT '{}'::text[];

CREATE TABLE IF NOT EXISTS public.profile_edit_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  requested_fields text[] NOT NULL DEFAULT '{}'::text[],
  message text NOT NULL DEFAULT '',
  attachments jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  reviewed_at timestamptz,
  reviewed_by uuid REFERENCES auth.users(id),
  reviewer_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_profile_edit_requests_user_id ON public.profile_edit_requests(user_id);
CREATE INDEX IF NOT EXISTS idx_profile_edit_requests_status ON public.profile_edit_requests(status) WHERE status = 'pending';

CREATE OR REPLACE FUNCTION public.profile_edit_requests_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_profile_edit_requests_set_updated_at ON public.profile_edit_requests;
CREATE TRIGGER trg_profile_edit_requests_set_updated_at
BEFORE UPDATE ON public.profile_edit_requests
FOR EACH ROW
EXECUTE FUNCTION public.profile_edit_requests_set_updated_at();

ALTER TABLE public.profile_edit_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own requests" ON public.profile_edit_requests;
CREATE POLICY "Users can view their own requests" ON public.profile_edit_requests
FOR SELECT
USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can create requests" ON public.profile_edit_requests;
CREATE POLICY "Users can create requests" ON public.profile_edit_requests
FOR INSERT
WITH CHECK (user_id = (select auth.uid()));

GRANT SELECT, INSERT ON public.profile_edit_requests TO authenticated;

DROP FUNCTION IF EXISTS public.admin_list_verification_users(text, text, integer, integer);
CREATE OR REPLACE FUNCTION public.admin_list_verification_users(
  p_status text DEFAULT NULL,
  p_query text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  name text,
  verification_status text,
  is_verified boolean,
  verification_photo_path text,
  verification_submitted_at timestamptz,
  verification_reviewed_at timestamptz,
  verification_similarity_score numeric,
  verification_auto_rejected boolean
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
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_status := NULLIF(trim(p_status), '');
  v_query := NULLIF(trim(p_query), '');

  RETURN QUERY
  SELECT
    u.id,
    u.name,
    u.verification_status,
    u.is_verified,
    u.verification_photo_path,
    u.verification_submitted_at,
    u.verification_reviewed_at,
    u.verification_similarity_score,
    u.verification_auto_rejected
  FROM public.users u
  WHERE (v_status IS NULL OR u.verification_status = v_status)
    AND (
      v_query IS NULL OR
      u.id::text ILIKE '%' || v_query || '%' OR
      COALESCE(u.name, '') ILIKE '%' || v_query || '%' OR
      COALESCE(u.verification_status, '') ILIKE '%' || v_query || '%'
    )
  ORDER BY u.verification_submitted_at DESC NULLS LAST, u.id DESC
  LIMIT GREATEST(LEAST(COALESCE(p_limit, 100), 500), 1)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_user_verification_status(
  p_user_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_status text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_status := NULLIF(trim(p_status), '');
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'p_status is required';
  END IF;

  IF v_status NOT IN ('unverified', 'analyzing', 'pending', 'approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid status';
  END IF;

  UPDATE public.users
  SET
    verification_status = v_status,
    is_verified = (v_status = 'approved'),
    verification_reviewed_at = CASE WHEN v_status IN ('approved', 'rejected') THEN now() ELSE NULL END,
    verification_reviewer_id = CASE WHEN v_status IN ('approved', 'rejected') THEN auth.uid() ELSE NULL END
  WHERE id = p_user_id;
END;
$$;

DROP FUNCTION IF EXISTS public.admin_list_profile_edit_requests(text, text, integer, integer);
CREATE OR REPLACE FUNCTION public.admin_list_profile_edit_requests(
  p_status text DEFAULT NULL,
  p_query text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  user_name text,
  requested_fields text[],
  message text,
  attachments jsonb,
  status text,
  created_at timestamptz,
  updated_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid,
  reviewer_note text,
  reviewer_name text
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
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_status := NULLIF(trim(p_status), '');
  v_query := NULLIF(trim(p_query), '');

  RETURN QUERY
  SELECT
    r.id,
    r.user_id,
    u.name AS user_name,
    r.requested_fields,
    r.message,
    r.attachments,
    r.status,
    r.created_at,
    r.updated_at,
    r.reviewed_at,
    r.reviewed_by,
    r.reviewer_note,
    COALESCE(ru.name, '') AS reviewer_name
  FROM public.profile_edit_requests r
  JOIN public.users u ON u.id = r.user_id
  LEFT JOIN public.users ru ON ru.id = r.reviewed_by
  WHERE (v_status IS NULL OR r.status = v_status)
    AND (
      v_query IS NULL OR
      r.user_id::text ILIKE '%' || v_query || '%' OR
      COALESCE(u.name, '') ILIKE '%' || v_query || '%' OR
      COALESCE(ru.name, '') ILIKE '%' || v_query || '%' OR
      COALESCE(r.message, '') ILIKE '%' || v_query || '%' OR
      array_to_string(COALESCE(r.requested_fields, '{}'::text[]), ',') ILIKE '%' || v_query || '%'
    )
  ORDER BY r.created_at DESC NULLS LAST, r.id DESC
  LIMIT GREATEST(LEAST(COALESCE(p_limit, 100), 500), 1)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_review_profile_edit_request(
  p_request_id uuid,
  p_decision text,
  p_reviewer_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_decision text;
  v_req record;
  v_user_fields_type text;
  v_user_fields_udt text;
  v_cur_fields text[];
  v_req_fields text[];
  v_new_fields text[];
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_admin = true
  ) INTO v_is_admin;

  IF NOT COALESCE(v_is_admin, false) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_decision := NULLIF(trim(p_decision), '');
  IF v_decision IS NULL THEN
    RAISE EXCEPTION 'p_decision is required';
  END IF;

  IF v_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid decision';
  END IF;

  SELECT r.* INTO v_req
  FROM public.profile_edit_requests r
  WHERE r.id = p_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'request not found';
  END IF;

  UPDATE public.profile_edit_requests
  SET
    status = v_decision,
    reviewed_at = now(),
    reviewed_by = auth.uid(),
    reviewer_note = NULLIF(trim(p_reviewer_note), '')
  WHERE id = p_request_id;

  IF v_decision <> 'approved' THEN
    RETURN;
  END IF;

  SELECT c.data_type, c.udt_name INTO v_user_fields_type, v_user_fields_udt
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'users'
    AND c.column_name = 'editable_profile_fields';

  v_req_fields := COALESCE(v_req.requested_fields, '{}'::text[]);

  IF v_user_fields_type = 'ARRAY' AND v_user_fields_udt = '_text' THEN
    SELECT COALESCE(u.editable_profile_fields, '{}'::text[]) INTO v_cur_fields
    FROM public.users u
    WHERE u.id = v_req.user_id;

    SELECT COALESCE(array_agg(DISTINCT f), '{}'::text[]) INTO v_new_fields
    FROM unnest(COALESCE(v_cur_fields, '{}'::text[]) || COALESCE(v_req_fields, '{}'::text[])) AS t(f)
    WHERE NULLIF(trim(f), '') IS NOT NULL;

    UPDATE public.users
    SET editable_profile_fields = v_new_fields
    WHERE id = v_req.user_id;
  ELSE
    SELECT COALESCE(array_agg(v), '{}'::text[]) INTO v_cur_fields
    FROM (
      SELECT jsonb_array_elements_text(COALESCE(u.editable_profile_fields::jsonb, '[]'::jsonb)) AS v
      FROM public.users u
      WHERE u.id = v_req.user_id
    ) t;

    SELECT COALESCE(array_agg(DISTINCT f), '{}'::text[]) INTO v_new_fields
    FROM unnest(COALESCE(v_cur_fields, '{}'::text[]) || COALESCE(v_req_fields, '{}'::text[])) AS t(f)
    WHERE NULLIF(trim(f), '') IS NOT NULL;

    UPDATE public.users
    SET editable_profile_fields = to_jsonb(v_new_fields)
    WHERE id = v_req.user_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_list_verification_users(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_verification_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_profile_edit_requests(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_review_profile_edit_request(uuid, text, text) TO authenticated;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminYes', $$Yes$$),
  ('es', 'adminYes', $$Sí$$),
  ('he', 'adminYes', $$כן$$),

  ('en', 'adminApprove', $$Approve$$),
  ('es', 'adminApprove', $$Aprobar$$),
  ('he', 'adminApprove', $$אישור$$),

  ('en', 'adminReject', $$Reject$$),
  ('es', 'adminReject', $$Rechazar$$),
  ('he', 'adminReject', $$דחייה$$),

  ('en', 'adminAttachment', $$Attachment$$),
  ('es', 'adminAttachment', $$Adjunto$$),
  ('he', 'adminAttachment', $$קובץ מצורף$$),

  ('en', 'adminAttachmentLoadFailed', $$Failed to load attachment.$$),
  ('es', 'adminAttachmentLoadFailed', $$No se pudo cargar el adjunto.$$),
  ('he', 'adminAttachmentLoadFailed', $$טעינת הקובץ נכשלה.$$),

  ('en', 'adminReviewerNote', $$Reviewer note$$),
  ('es', 'adminReviewerNote', $$Nota del revisor$$),
  ('he', 'adminReviewerNote', $$הערת בודק$$),

  ('en', 'adminStatusAll', $$All$$),
  ('es', 'adminStatusAll', $$Todos$$),
  ('he', 'adminStatusAll', $$הכול$$),

  ('en', 'adminStatusPending', $$Pending$$),
  ('es', 'adminStatusPending', $$Pendiente$$),
  ('he', 'adminStatusPending', $$ממתין$$),

  ('en', 'adminStatusApproved', $$Approved$$),
  ('es', 'adminStatusApproved', $$Aprobado$$),
  ('he', 'adminStatusApproved', $$אושר$$),

  ('en', 'adminStatusRejected', $$Rejected$$),
  ('es', 'adminStatusRejected', $$Rechazado$$),
  ('he', 'adminStatusRejected', $$נדחה$$),

  ('en', 'adminStatusUnverified', $$Unverified$$),
  ('es', 'adminStatusUnverified', $$No verificado$$),
  ('he', 'adminStatusUnverified', $$לא מאומת$$),

  ('en', 'adminStatusAnalyzing', $$Analyzing$$),
  ('es', 'adminStatusAnalyzing', $$Analizando$$),
  ('he', 'adminStatusAnalyzing', $$בניתוח$$),

  ('en', 'adminVerificationLoadFailed', $$Failed to load verification users.$$),
  ('es', 'adminVerificationLoadFailed', $$No se pudieron cargar los usuarios de verificación.$$),
  ('he', 'adminVerificationLoadFailed', $$טעינת משתמשי האימות נכשלה.$$),

  ('en', 'adminVerificationUpdateFailed', $$Failed to update verification. Please try again.$$),
  ('es', 'adminVerificationUpdateFailed', $$No se pudo actualizar la verificación. Inténtalo de nuevo.$$),
  ('he', 'adminVerificationUpdateFailed', $$עדכון האימות נכשל. נסו שוב.$$),

  ('en', 'adminVerificationSearchHint', $$Search by user id, name, or status$$),
  ('es', 'adminVerificationSearchHint', $$Buscar por id de usuario, nombre o estado$$),
  ('he', 'adminVerificationSearchHint', $$חיפוש לפי מזהה משתמש, שם או סטטוס$$),

  ('en', 'adminVerificationStatusFilter', $$Status$$),
  ('es', 'adminVerificationStatusFilter', $$Estado$$),
  ('he', 'adminVerificationStatusFilter', $$סטטוס$$),

  ('en', 'adminVerificationCount', $${count} users$$),
  ('es', 'adminVerificationCount', $${count} usuarios$$),
  ('he', 'adminVerificationCount', $${count} משתמשים$$),

  ('en', 'adminVerificationEmpty', $$No users found.$$),
  ('es', 'adminVerificationEmpty', $$No se encontraron usuarios.$$),
  ('he', 'adminVerificationEmpty', $$לא נמצאו משתמשים.$$),

  ('en', 'adminVerificationStatus', $$Status$$),
  ('es', 'adminVerificationStatus', $$Estado$$),
  ('he', 'adminVerificationStatus', $$סטטוס$$),

  ('en', 'adminVerificationSubmitted', $$Submitted$$),
  ('es', 'adminVerificationSubmitted', $$Enviado$$),
  ('he', 'adminVerificationSubmitted', $$נשלח$$),

  ('en', 'adminVerificationReviewed', $$Reviewed$$),
  ('es', 'adminVerificationReviewed', $$Revisado$$),
  ('he', 'adminVerificationReviewed', $$נבדק$$),

  ('en', 'adminVerificationScore', $$Score$$),
  ('es', 'adminVerificationScore', $$Puntuación$$),
  ('he', 'adminVerificationScore', $$ציון$$),

  ('en', 'adminVerificationAutoRejected', $$Auto-rejected$$),
  ('es', 'adminVerificationAutoRejected', $$Rechazo automático$$),
  ('he', 'adminVerificationAutoRejected', $$נדחה אוטומטית$$),

  ('en', 'adminVerificationViewPhoto', $$View photo$$),
  ('es', 'adminVerificationViewPhoto', $$Ver foto$$),
  ('he', 'adminVerificationViewPhoto', $$צפייה בתמונה$$),

  ('en', 'adminVerificationNoPhoto', $$No verification photo.$$),
  ('es', 'adminVerificationNoPhoto', $$No hay foto de verificación.$$),
  ('he', 'adminVerificationNoPhoto', $$אין תמונת אימות.$$),

  ('en', 'adminVerificationPhotoTitle', $$Verification photo$$),
  ('es', 'adminVerificationPhotoTitle', $$Foto de verificación$$),
  ('he', 'adminVerificationPhotoTitle', $$תמונת אימות$$),

  ('en', 'adminVerificationPhotoLoadFailed', $$Failed to load photo.$$),
  ('es', 'adminVerificationPhotoLoadFailed', $$No se pudo cargar la foto.$$),
  ('he', 'adminVerificationPhotoLoadFailed', $$טעינת התמונה נכשלה.$$),

  ('en', 'adminProfileEditsLoadFailed', $$Failed to load profile edit requests.$$),
  ('es', 'adminProfileEditsLoadFailed', $$No se pudieron cargar las solicitudes de edición de perfil.$$),
  ('he', 'adminProfileEditsLoadFailed', $$טעינת בקשות עריכת הפרופיל נכשלה.$$),

  ('en', 'adminProfileEditsUpdateFailed', $$Failed to update request. Please try again.$$),
  ('es', 'adminProfileEditsUpdateFailed', $$No se pudo actualizar la solicitud. Inténtalo de nuevo.$$),
  ('he', 'adminProfileEditsUpdateFailed', $$עדכון הבקשה נכשל. נסו שוב.$$),

  ('en', 'adminProfileEditsSearchHint', $$Search by user, field, or message$$),
  ('es', 'adminProfileEditsSearchHint', $$Buscar por usuario, campo o mensaje$$),
  ('he', 'adminProfileEditsSearchHint', $$חיפוש לפי משתמש, שדה או הודעה$$),

  ('en', 'adminProfileEditsStatusFilter', $$Status$$),
  ('es', 'adminProfileEditsStatusFilter', $$Estado$$),
  ('he', 'adminProfileEditsStatusFilter', $$סטטוס$$),

  ('en', 'adminProfileEditsCount', $${count} requests$$),
  ('es', 'adminProfileEditsCount', $${count} solicitudes$$),
  ('he', 'adminProfileEditsCount', $${count} בקשות$$),

  ('en', 'adminProfileEditsEmpty', $$No requests found.$$),
  ('es', 'adminProfileEditsEmpty', $$No se encontraron solicitudes.$$),
  ('he', 'adminProfileEditsEmpty', $$לא נמצאו בקשות.$$),

  ('en', 'adminProfileEditsStatus', $$Status$$),
  ('es', 'adminProfileEditsStatus', $$Estado$$),
  ('he', 'adminProfileEditsStatus', $$סטטוס$$),

  ('en', 'adminProfileEditsCreated', $$Created$$),
  ('es', 'adminProfileEditsCreated', $$Creado$$),
  ('he', 'adminProfileEditsCreated', $$נוצר$$),

  ('en', 'adminProfileEditsFields', $$Fields$$),
  ('es', 'adminProfileEditsFields', $$Campos$$),
  ('he', 'adminProfileEditsFields', $$שדות$$),

  ('en', 'adminProfileEditsAttachments', $$Attachments$$),
  ('es', 'adminProfileEditsAttachments', $$Adjuntos$$),
  ('he', 'adminProfileEditsAttachments', $$קבצים מצורפים$$),

  ('en', 'adminProfileEditsAttachmentsShort', $$Files$$),
  ('es', 'adminProfileEditsAttachmentsShort', $$Archivos$$),
  ('he', 'adminProfileEditsAttachmentsShort', $$קבצים$$),

  ('en', 'adminProfileEditsNoAttachments', $$No attachments.$$),
  ('es', 'adminProfileEditsNoAttachments', $$Sin adjuntos.$$),
  ('he', 'adminProfileEditsNoAttachments', $$אין קבצים מצורפים.$$),

  ('en', 'adminProfileEditsDetails', $$Details$$),
  ('es', 'adminProfileEditsDetails', $$Detalles$$),
  ('he', 'adminProfileEditsDetails', $$פרטים$$),

  ('en', 'adminProfileEditsDetailsTitle', $$Request details$$),
  ('es', 'adminProfileEditsDetailsTitle', $$Detalles de la solicitud$$),
  ('he', 'adminProfileEditsDetailsTitle', $$פרטי הבקשה$$),

  ('en', 'adminProfileEditsUser', $$User$$),
  ('es', 'adminProfileEditsUser', $$Usuario$$),
  ('he', 'adminProfileEditsUser', $$משתמש$$),

  ('en', 'adminProfileEditsMessage', $$Message$$),
  ('es', 'adminProfileEditsMessage', $$Mensaje$$),
  ('he', 'adminProfileEditsMessage', $$הודעה$$),

  ('en', 'adminProfileEditsApproveTitle', $$Approve request$$),
  ('es', 'adminProfileEditsApproveTitle', $$Aprobar solicitud$$),
  ('he', 'adminProfileEditsApproveTitle', $$אישור בקשה$$),

  ('en', 'adminProfileEditsRejectTitle', $$Reject request$$),
  ('es', 'adminProfileEditsRejectTitle', $$Rechazar solicitud$$),
  ('he', 'adminProfileEditsRejectTitle', $$דחיית בקשה$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
