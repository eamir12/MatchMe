-- Seed missing app UI translations (en/es/he). Safe to re-run.
-- Target: profile_wizard_screen, chat_screen, ad_settings_screen,
--         auth_screen, photo_gallery_viewer, match_box, banner_ad_widget,
--         web notification/calendar/ad placeholder services.

INSERT INTO public.translations (locale, key, value) VALUES

  -- ad_settings_screen
  ('en', 'adSettingsAtLeastOneConsent', $$At least one consent option must be selected$$),
  ('es', 'adSettingsAtLeastOneConsent', $$Debe seleccionarse al menos una opción de consentimiento$$),
  ('he', 'adSettingsAtLeastOneConsent', $$יש לבחור לפחות אפשרות הסכמה אחת$$),

  ('en', 'adSettingsNonPersonalizedDesc', $$General ads not based on your interests$$),
  ('es', 'adSettingsNonPersonalizedDesc', $$Anuncios generales no basados en tus intereses$$),
  ('he', 'adSettingsNonPersonalizedDesc', $$מודעות כלליות שאינן מבוססות על תחומי העניין שלך$$),

  ('en', 'adSettingsPersonalizedDesc', $$Ads based on your interests$$),
  ('es', 'adSettingsPersonalizedDesc', $$Anuncios basados en tus intereses$$),
  ('he', 'adSettingsPersonalizedDesc', $$מודעות המבוססות על תחומי העניין שלך$$),

  ('en', 'adSettingsSaveFailed', $$Failed to save preferences$$),
  ('es', 'adSettingsSaveFailed', $$No se pudieron guardar las preferencias$$),
  ('he', 'adSettingsSaveFailed', $$שמירת ההעדפות נכשלה$$),

  ('en', 'adSettingsLoadFailed', $$Failed to load preferences$$),
  ('es', 'adSettingsLoadFailed', $$No se pudieron cargar las preferencias$$),
  ('he', 'adSettingsLoadFailed', $$טעינת ההעדפות נכשלה$$),

  ('en', 'adSettingsNotAuthenticated', $$Not authenticated$$),
  ('es', 'adSettingsNotAuthenticated', $$No autenticado$$),
  ('he', 'adSettingsNotAuthenticated', $$לא מאומת$$),

  ('en', 'adSettingsSaved', $$Ad preferences saved$$),
  ('es', 'adSettingsSaved', $$Preferencias de anuncios guardadas$$),
  ('he', 'adSettingsSaved', $$העדפות המודעות נשמרו$$),

  -- auth_screen
  ('en', 'authClearSession', $$Clear Session$$),
  ('es', 'authClearSession', $$Borrar sesión$$),
  ('he', 'authClearSession', $$ניקוי הסשן$$),

  -- banner_ad_widget
  ('en', 'adErrorGeneric', $$Error {code}: {message}$$),
  ('es', 'adErrorGeneric', $$Error {code}: {message}$$),
  ('he', 'adErrorGeneric', $$שגיאה {code}: {message}$$),

  ('en', 'adErrorInternal', $$Internal error: {message}$$),
  ('es', 'adErrorInternal', $$Error interno: {message}$$),
  ('he', 'adErrorInternal', $$שגיאה פנימית: {message}$$),

  ('en', 'adErrorInvalidRequest', $$Invalid request: {message}$$),
  ('es', 'adErrorInvalidRequest', $$Solicitud no válida: {message}$$),
  ('he', 'adErrorInvalidRequest', $$בקשה לא תקנית: {message}$$),

  ('en', 'adErrorNetwork', $$Network error - check connection: {message}$$),
  ('es', 'adErrorNetwork', $$Error de red - verifica la conexión: {message}$$),
  ('he', 'adErrorNetwork', $$שגיאת רשת - בדוק חיבור: {message}$$),

  ('en', 'adErrorNoFill', $$No fill - AdMob has no ad to serve (normal in test/development)$$),
  ('es', 'adErrorNoFill', $$Sin contenido - AdMob no tiene anuncios (normal en pruebas/desarrollo)$$),
  ('he', 'adErrorNoFill', $$אין מודעות - ל-AdMob אין מודעה להציג (נורמלי בבדיקות/פיתוח)$$),

  -- calendar service
  ('en', 'calendarNoTitle', $$No Title$$),
  ('es', 'calendarNoTitle', $$Sin título$$),
  ('he', 'calendarNoTitle', $$ללא כותרת$$),

  -- chat_screen
  ('en', 'blockNeedsOnline', $$You need to be online to block a user$$),
  ('es', 'blockNeedsOnline', $$Necesitas estar en línea para bloquear a un usuario$$),
  ('he', 'blockNeedsOnline', $$עליך להיות מחובר כדי לחסום משתמש$$),

  ('en', 'reportNeedsOnline', $$You need to be online to report a user$$),
  ('es', 'reportNeedsOnline', $$Necesitas estar en línea para reportar a un usuario$$),
  ('he', 'reportNeedsOnline', $$עליך להיות מחובר כדי לדווח על משתמש$$),

  -- match_box (default parameter)
  ('en', 'recentMatches', $$Recent Matches$$),
  ('es', 'recentMatches', $$Coincidencias recientes$$),
  ('he', 'recentMatches', $$התאמות אחרונות$$),

  -- photo_gallery_viewer
  ('en', 'failedToLoadImage', $$Failed to load image$$),
  ('es', 'failedToLoadImage', $$Error al cargar la imagen$$),
  ('he', 'failedToLoadImage', $$טעינת התמונה נכשלה$$),

  -- profile_wizard_screen
  ('en', 'profileWizardFacebookHint', $$yourusername$$),
  ('es', 'profileWizardFacebookHint', $$tuusuario$$),
  ('he', 'profileWizardFacebookHint', $$שםהמשתמששלך$$),

  ('en', 'profileWizardInstagramHint', $$yourusername$$),
  ('es', 'profileWizardInstagramHint', $$tuusuario$$),
  ('he', 'profileWizardInstagramHint', $$שםהמשתמששלך$$),

  ('en', 'profileWizardLinkedinHint', $$yourprofile$$),
  ('es', 'profileWizardLinkedinHint', $$tuperfil$$),
  ('he', 'profileWizardLinkedinHint', $$הפרופילשלך$$),

  ('en', 'profileWizardRemove', $$Remove$$),
  ('es', 'profileWizardRemove', $$Eliminar$$),
  ('he', 'profileWizardRemove', $$הסרה$$),

  ('en', 'profileWizardRemovePhotoBody', $$Are you sure you want to remove this photo?$$),
  ('es', 'profileWizardRemovePhotoBody', $$¿Estás seguro de que deseas eliminar esta foto?$$),
  ('he', 'profileWizardRemovePhotoBody', $$האם אתה בטוח שברצונך להסיר תמונה זו?$$),

  ('en', 'profileWizardRemovePhotoTitle', $$Remove photo?$$),
  ('es', 'profileWizardRemovePhotoTitle', $$¿Eliminar foto?$$),
  ('he', 'profileWizardRemovePhotoTitle', $$להסיר תמונה?$$),

  -- web notification service
  ('en', 'webNotificationNewMatchBody', $$New match! Tap to start chatting$$),
  ('es', 'webNotificationNewMatchBody', $$¡Nueva coincidencia! Toca para empezar a chatear$$),
  ('he', 'webNotificationNewMatchBody', $$התאמה חדשה! הקש כדי להתחיל לשוחח$$),

  ('en', 'webNotificationNewMatchTitle', $$💕 New match with {userName}$$),
  ('es', 'webNotificationNewMatchTitle', $$💕 Nueva coincidencia con {userName}$$),
  ('he', 'webNotificationNewMatchTitle', $$💕 התאמה חדשה עם {userName}$$),

  -- web notification service stub
  ('en', 'notAvailableOnPlatform', $$Not available on this platform$$),
  ('es', 'notAvailableOnPlatform', $$No disponible en esta plataforma$$),
  ('he', 'notAvailableOnPlatform', $$לא זמין בפלטפורמה זו$$),

  -- web placeholder ad widgets
  ('en', 'webArticleAdPlaceholder', $$Article Ad$$),
  ('es', 'webArticleAdPlaceholder', $$Anuncio de artículo$$),
  ('he', 'webArticleAdPlaceholder', $$מודעת מאמר$$),

  ('en', 'webDisplayAdPlaceholder', $$Web Display Ad$$),
  ('es', 'webDisplayAdPlaceholder', $$Anuncio de display web$$),
  ('he', 'webDisplayAdPlaceholder', $$מודעת תצוגה לאינטרנט$$),

  ('en', 'webInFeedAdPlaceholder', $$In-Feed Ad$$),
  ('es', 'webInFeedAdPlaceholder', $$Anuncio en el feed$$),
  ('he', 'webInFeedAdPlaceholder', $$מודעה בפיד$$)

ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
