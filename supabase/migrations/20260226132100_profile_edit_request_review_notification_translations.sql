INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileEditRequestApprovedNotifTitle', $$Profile edit request approved$$),
  ('es', 'profileEditRequestApprovedNotifTitle', $$Solicitud de edición del perfil aprobada$$),
  ('he', 'profileEditRequestApprovedNotifTitle', $$בקשת עריכת פרופיל אושרה$$),

  ('en', 'profileEditRequestApprovedNotifBody', $$An admin approved your profile edit request.$$),
  ('es', 'profileEditRequestApprovedNotifBody', $$Un administrador aprobó tu solicitud de edición del perfil.$$),
  ('he', 'profileEditRequestApprovedNotifBody', $$מנהל אישר את בקשת עריכת הפרופיל שלך.$$),

  ('en', 'profileEditRequestRejectedNotifTitle', $$Profile edit request rejected$$),
  ('es', 'profileEditRequestRejectedNotifTitle', $$Solicitud de edición del perfil rechazada$$),
  ('he', 'profileEditRequestRejectedNotifTitle', $$בקשת עריכת פרופיל נדחתה$$),

  ('en', 'profileEditRequestRejectedNotifBody', $$An admin rejected your profile edit request.$$),
  ('es', 'profileEditRequestRejectedNotifBody', $$Un administrador rechazó tu solicitud de edición del perfil.$$),
  ('he', 'profileEditRequestRejectedNotifBody', $$מנהל דחה את בקשת עריכת הפרופיל שלך.$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
