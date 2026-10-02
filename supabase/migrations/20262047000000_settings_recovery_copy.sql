INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'settingsProfileUnavailableTitle', 'Profile settings unavailable'),
  ('en', 'settingsProfileUnavailableMessage', 'We couldn’t load your profile settings. Try again to continue.'),
  ('en', 'settingsLoadErrorTitle', 'We couldn’t load Settings'),
  ('en', 'settingsLoadErrorMessage', 'Check your connection and try again. Other cached settings may still be available.'),
  ('es', 'settingsProfileUnavailableTitle', 'Ajustes del perfil no disponibles'),
  ('es', 'settingsProfileUnavailableMessage', 'No pudimos cargar los ajustes de tu perfil. Inténtalo de nuevo para continuar.'),
  ('es', 'settingsLoadErrorTitle', 'No pudimos cargar los ajustes'),
  ('es', 'settingsLoadErrorMessage', 'Comprueba tu conexión e inténtalo de nuevo. Puede que otros ajustes en caché estén disponibles.'),
  ('he', 'settingsProfileUnavailableTitle', 'הגדרות הפרופיל אינן זמינות'),
  ('he', 'settingsProfileUnavailableMessage', 'לא ניתן לטעון את הגדרות הפרופיל שלך. נסו שוב כדי להמשיך.'),
  ('he', 'settingsLoadErrorTitle', 'לא ניתן לטעון את ההגדרות'),
  ('he', 'settingsLoadErrorMessage', 'בדקו את החיבור ונסו שוב. ייתכן שהגדרות אחרות שמורות במטמון עדיין זמינות.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
