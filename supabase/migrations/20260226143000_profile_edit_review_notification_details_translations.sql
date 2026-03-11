BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileEditRequestApprovedNotifBody', $$An admin approved your profile edit request for {fields}.$$),
  ('es', 'profileEditRequestApprovedNotifBody', $$Un administrador aprobó tu solicitud de edición del perfil para {fields}.$$),
  ('he', 'profileEditRequestApprovedNotifBody', $$מנהל אישר את בקשת עריכת הפרופיל שלך עבור {fields}.$$),

  ('en', 'profileEditRequestRejectedNotifBody', $$An admin rejected your profile edit request for {fields}.$$),
  ('es', 'profileEditRequestRejectedNotifBody', $$Un administrador rechazó tu solicitud de edición del perfil para {fields}.$$),
  ('he', 'profileEditRequestRejectedNotifBody', $$מנהל דחה את בקשת עריכת הפרופיל שלך עבור {fields}.$$),

  ('en', 'profileEditRequestReviewerNoteLine', $$Admin note: {note}$$),
  ('es', 'profileEditRequestReviewerNoteLine', $$Nota del administrador: {note}$$),
  ('he', 'profileEditRequestReviewerNoteLine', $$הערת מנהל: {note}$$),

  ('en', 'profileEditFieldLabelName', $$name$$),
  ('es', 'profileEditFieldLabelName', $$nombre$$),
  ('he', 'profileEditFieldLabelName', $$שם$$),

  ('en', 'profileEditFieldLabelGender', $$gender$$),
  ('es', 'profileEditFieldLabelGender', $$género$$),
  ('he', 'profileEditFieldLabelGender', $$מגדר$$),

  ('en', 'profileEditFieldLabelDateOfBirth', $$date of birth$$),
  ('es', 'profileEditFieldLabelDateOfBirth', $$fecha de nacimiento$$),
  ('he', 'profileEditFieldLabelDateOfBirth', $$תאריך לידה$$)
ON CONFLICT (locale, key) DO UPDATE
SET value = EXCLUDED.value;

COMMIT;
