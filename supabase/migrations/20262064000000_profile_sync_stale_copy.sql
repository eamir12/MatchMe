INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileSyncStaleTitle', 'Profile data may be out of date'),
  ('en', 'profileSyncStaleMessage', 'We couldn’t refresh your profile. Showing the last saved version.'),
  ('es', 'profileSyncStaleTitle', 'Los datos de tu perfil podrían estar desactualizados'),
  ('es', 'profileSyncStaleMessage', 'No pudimos actualizar tu perfil. Se muestra la última versión guardada.'),
  ('he', 'profileSyncStaleTitle', 'ייתכן שנתוני הפרופיל לא מעודכנים'),
  ('he', 'profileSyncStaleMessage', 'לא הצלחנו לרענן את הפרופיל שלך. מוצגת הגרסה האחרונה שנשמרה.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
