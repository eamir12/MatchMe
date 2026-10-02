-- Seed missing admin app UI translations (en/es/he). Safe to re-run.
-- These keys exist in main.dart _defaultTranslations but were missing
-- from the Supabase translations table.

INSERT INTO public.translations (locale, key, value) VALUES

  -- Auth keys
  ('en', 'authEmailInvalid', $$Enter a valid email address.$$),
  ('es', 'authEmailInvalid', $$Introduzca una dirección de correo electrónico válida.$$),
  ('he', 'authEmailInvalid', $$נא להזין כתובת אימייל חוקית.$$),

  ('en', 'authSigningIn', $$Signing in...$$),
  ('es', 'authSigningIn', $$Iniciando sesión...$$),
  ('he', 'authSigningIn', $$מתחבר...$$),

  -- Admin AI provider names
  ('en', 'adminAiProviderDeepL', $$DeepL$$),
  ('es', 'adminAiProviderDeepL', $$DeepL$$),
  ('he', 'adminAiProviderDeepL', $$DeepL$$),

  ('en', 'adminAiProviderGemini', $$Gemini$$),
  ('es', 'adminAiProviderGemini', $$Gemini$$),
  ('he', 'adminAiProviderGemini', $$Gemini$$),

  -- Admin AI quota status labels
  ('en', 'adminAiQuotaStatusCritical', $$Critical$$),
  ('es', 'adminAiQuotaStatusCritical', $$Crítico$$),
  ('he', 'adminAiQuotaStatusCritical', $$קריטי$$),

  ('en', 'adminAiQuotaStatusOk', $$OK$$),
  ('es', 'adminAiQuotaStatusOk', $$OK$$),
  ('he', 'adminAiQuotaStatusOk', $$תקין$$),

  ('en', 'adminAiQuotaStatusUnknown', $$Unknown$$),
  ('es', 'adminAiQuotaStatusUnknown', $$Desconocido$$),
  ('he', 'adminAiQuotaStatusUnknown', $$לא ידוע$$),

  ('en', 'adminAiQuotaStatusWarn', $$Warning$$),
  ('es', 'adminAiQuotaStatusWarn', $$Advertencia$$),
  ('he', 'adminAiQuotaStatusWarn', $$אזהרה$$),

  -- Admin attachment
  ('en', 'adminAttachmentOpenFailed', $$Failed to open attachment.$$),
  ('es', 'adminAttachmentOpenFailed', $$No se pudo abrir el adjunto.$$),
  ('he', 'adminAttachmentOpenFailed', $$פתיחת הקובץ המצורף נכשלה.$$),

  -- Admin broadcasts confirmation
  ('en', 'adminBroadcastsConfirmTitle', $$Confirm$$),
  ('es', 'adminBroadcastsConfirmTitle', $$Confirmar$$),
  ('he', 'adminBroadcastsConfirmTitle', $$אישור$$),

  ('en', 'adminBroadcastsConfirmScheduleBody', $$Review the message and recipients before scheduling for {time}.$$),
  ('es', 'adminBroadcastsConfirmScheduleBody', $$Revise el mensaje y los destinatarios antes de programar para {time}.$$),
  ('he', 'adminBroadcastsConfirmScheduleBody', $$עיינו בהודעה ובנמענים לפני תזמון ל-{time}.$$),

  ('en', 'adminBroadcastsConfirmSendNowBody', $$Review the message and recipients before sending.$$),
  ('es', 'adminBroadcastsConfirmSendNowBody', $$Revise el mensaje y los destinatarios antes de enviar.$$),
  ('he', 'adminBroadcastsConfirmSendNowBody', $$עיינו בהודעה ובנמענים לפני השליחה.$$),

  -- Admin broadcasts recipients
  ('en', 'adminBroadcastsRecipientsButton', $$Recipients$$),
  ('es', 'adminBroadcastsRecipientsButton', $$Destinatarios$$),
  ('he', 'adminBroadcastsRecipientsButton', $$נמענים$$),

  ('en', 'adminBroadcastsRecipientsChip', $$Recipients: {count}$$),
  ('es', 'adminBroadcastsRecipientsChip', $$Destinatarios: {count}$$),
  ('he', 'adminBroadcastsRecipientsChip', $$נמענים: {count}$$),

  -- Admin broadcasts reschedule
  ('en', 'adminBroadcastsSchedule', $$Schedule$$),
  ('es', 'adminBroadcastsSchedule', $$Programar$$),
  ('he', 'adminBroadcastsSchedule', $$תזמון$$),

  ('en', 'adminBroadcastsSendNow', $$Send now$$),
  ('es', 'adminBroadcastsSendNow', $$Enviar ahora$$),
  ('he', 'adminBroadcastsSendNow', $$שלח עכשיו$$),

  ('en', 'adminBroadcastsRescheduled', $$Broadcast rescheduled.$$),
  ('es', 'adminBroadcastsRescheduled', $$Retransmisión reprogramada.$$),
  ('he', 'adminBroadcastsRescheduled', $$השידור תוזמן מחדש.$$),

  ('en', 'adminBroadcastsRescheduleFailed', $$Failed to reschedule broadcast$$),
  ('es', 'adminBroadcastsRescheduleFailed', $$No se pudo reprogramar la retransmisión$$),
  ('he', 'adminBroadcastsRescheduleFailed', $$תזמון מחדש של השידור נכשל$$),

  ('en', 'adminBroadcastsRescheduleMustBeFuture', $$Please pick a time in the future.$$),
  ('es', 'adminBroadcastsRescheduleMustBeFuture', $$Por favor, elija una hora futura.$$),
  ('he', 'adminBroadcastsRescheduleMustBeFuture', $$נא לבחור זמן עתידי.$$),

  ('en', 'adminBroadcastsResendFailed', $$Failed to resend broadcast$$),
  ('es', 'adminBroadcastsResendFailed', $$No se pudo reenviar la retransmisión$$),
  ('he', 'adminBroadcastsResendFailed', $$שליחה מחדש של השידור נכשלה$$),

  ('en', 'adminBroadcastsResent', $$Broadcast resent.$$),
  ('es', 'adminBroadcastsResent', $$Retransmisión reenviada.$$),
  ('he', 'adminBroadcastsResent', $$השידור נשלח מחדש.$$),

  -- Admin dashboard AI quota
  ('en', 'adminDashboardAIQuotaTitle', $$AI quotas$$),
  ('es', 'adminDashboardAIQuotaTitle', $$Cuotas de IA$$),
  ('he', 'adminDashboardAIQuotaTitle', $$מכסות AI$$),

  ('en', 'adminDashboardAIQuotaEmpty', $$No quota data yet.$$),
  ('es', 'adminDashboardAIQuotaEmpty', $$Aún no hay datos de cuota.$$),
  ('he', 'adminDashboardAIQuotaEmpty', $$עדיין אין נתוני מכסה.$$),

  ('en', 'adminDashboardAIQuotaLimit', $$Limit$$),
  ('es', 'adminDashboardAIQuotaLimit', $$Límite$$),
  ('he', 'adminDashboardAIQuotaLimit', $$גבלה$$),

  ('en', 'adminDashboardAIQuotaMetric', $$Metric$$),
  ('es', 'adminDashboardAIQuotaMetric', $$Métrica$$),
  ('he', 'adminDashboardAIQuotaMetric', $$מדד$$),

  ('en', 'adminDashboardAIQuotaStatus', $$Status$$),
  ('es', 'adminDashboardAIQuotaStatus', $$Estado$$),
  ('he', 'adminDashboardAIQuotaStatus', $$סטטוס$$),

  ('en', 'adminDashboardAIQuotaUsed', $$Used$$),
  ('es', 'adminDashboardAIQuotaUsed', $$Usado$$),
  ('he', 'adminDashboardAIQuotaUsed', $$בשימוש$$),

  ('en', 'adminDashboardAIQuotaWindow', $$Window$$),
  ('es', 'adminDashboardAIQuotaWindow', $$Ventana$$),
  ('he', 'adminDashboardAIQuotaWindow', $$חלון$$),

  ('en', 'adminDashboardAIQuotaWindowBillingPeriod', $$Billing period$$),
  ('es', 'adminDashboardAIQuotaWindowBillingPeriod', $$Período de facturación$$),
  ('he', 'adminDashboardAIQuotaWindowBillingPeriod', $$תקופת חיוב$$),

  -- Admin login screen
  ('en', 'adminLoginSubtitle', $$Sign in with your authorized admin account.$$),
  ('es', 'adminLoginSubtitle', $$Inicie sesión con su cuenta de administrador autorizada.$$),
  ('he', 'adminLoginSubtitle', $$התחברו עם חשבון המנהל המורשה שלכם.$$),

  ('en', 'adminLoginAuthorizedOnly', $$Authorized admins only$$),
  ('es', 'adminLoginAuthorizedOnly', $$Solo administradores autorizados$$),
  ('he', 'adminLoginAuthorizedOnly', $$מנהלים מורשים בלבד$$),

  ('en', 'adminLoginHelper', $$Use the same email and password linked to your MatchMe admin access.$$),
  ('es', 'adminLoginHelper', $$Use el mismo correo y contraseña vinculados a su acceso de administrador de MatchMe.$$),
  ('he', 'adminLoginHelper', $$השתמשו באותו אימייל וסיסמה המקושרים לגישת הניהול שלכם ב-MatchMe.$$),

  ('en', 'adminLoginRememberEmail', $$Remember this email on this device$$),
  ('es', 'adminLoginRememberEmail', $$Recordar este correo en este dispositivo$$),
  ('he', 'adminLoginRememberEmail', $$זכור אימייל זה במכשיר זה$$),

  ('en', 'adminLoginRetry', $$Try again$$),
  ('es', 'adminLoginRetry', $$Intentar de nuevo$$),
  ('he', 'adminLoginRetry', $$נסו שוב$$),

  ('en', 'adminLoginTroubleTitle', $$Having trouble signing in?$$),
  ('es', 'adminLoginTroubleTitle', $$¿Problemas para iniciar sesión?$$),
  ('he', 'adminLoginTroubleTitle', $$מתקשים להתחבר?$$),

  ('en', 'adminLoginTroubleBody', $$Check your connection, confirm your email if needed, and make sure this account has admin access.$$),
  ('es', 'adminLoginTroubleBody', $$Revise su conexión, confirme su correo si es necesario y asegúrese de que esta cuenta tenga acceso de administrador.$$),
  ('he', 'adminLoginTroubleBody', $$בדקו את החיבור, אשרו את האימייל במידת הצורך, וודאו שלחשבון זה יש הרשאת ניהול.$$),

  -- Admin nav
  ('en', 'adminNavPromoCodes', $$Promo Codes$$),
  ('es', 'adminNavPromoCodes', $$Códigos promocionales$$),
  ('he', 'adminNavPromoCodes', $$קודי קופון$$),

  ('en', 'adminNavSponsoredAds', $$Sponsored Ads$$),
  ('es', 'adminNavSponsoredAds', $$Anuncios patrocinados$$),
  ('he', 'adminNavSponsoredAds', $$מודעות ממומנות$$),

  -- Admin profile edits
  ('en', 'adminProfileEditsChangeComplete', $$Change complete$$),
  ('es', 'adminProfileEditsChangeComplete', $$Cambio completado$$),
  ('he', 'adminProfileEditsChangeComplete', $$השינוי הושלם$$),

  -- Admin reset
  ('en', 'adminReset', $$Reset$$),
  ('es', 'adminReset', $$Restablecer$$),
  ('he', 'adminReset', $$איפוס$$),

  -- Admin verification
  ('en', 'adminVerificationReviewedBy', $$Reviewed by$$),
  ('es', 'adminVerificationReviewedBy', $$Revisado por$$),
  ('he', 'adminVerificationReviewedBy', $$נבדק על ידי$$),

  ('en', 'adminVerificationReviewerAi', $$AI$$),
  ('es', 'adminVerificationReviewerAi', $$IA$$),
  ('he', 'adminVerificationReviewerAi', $$AI$$),

  -- Admin ad display order (Sponsored Ads / External Ads configuration)
  ('en', 'adminAdDisplayOrderLabel', $$Display Order$$),
  ('es', 'adminAdDisplayOrderLabel', $$Orden de visualización$$),
  ('he', 'adminAdDisplayOrderLabel', $$סדר תצוגה$$),

  ('en', 'adminAdDisplayOrderExternalFirst', $$External First$$),
  ('es', 'adminAdDisplayOrderExternalFirst', $$Externo primero$$),
  ('he', 'adminAdDisplayOrderExternalFirst', $$חיצוני תחילה$$),

  ('en', 'adminAdDisplayOrderInternalFirst', $$Internal First$$),
  ('es', 'adminAdDisplayOrderInternalFirst', $$Interno primero$$),
  ('he', 'adminAdDisplayOrderInternalFirst', $$פנימי תחילה$$),

  -- Admin Unified Ad Management (new unified dashboard)
  ('en', 'adminUnifiedAdManagement', $$Ad Management$$),
  ('es', 'adminUnifiedAdManagement', $$Gestión de anuncios$$),
  ('he', 'adminUnifiedAdManagement', $$ניהול מודעות$$),

  ('en', 'adminUnifiedAdMasterTitle', $$Master Control$$),
  ('es', 'adminUnifiedAdMasterTitle', $$Control maestro$$),
  ('he', 'adminUnifiedAdMasterTitle', $$בקרה ראשית$$),

  ('en', 'adminUnifiedAdMasterSubtitle', $$Enable or disable internal and external ad systems.$$),
  ('es', 'adminUnifiedAdMasterSubtitle', $$Habilite o deshabilite los sistemas de anuncios internos y externos.$$),
  ('he', 'adminUnifiedAdMasterSubtitle', $$הפעל או השבת מערכות מודעות פנימיות וחיצוניות.$$),

  ('en', 'adminUnifiedAdDisabledWarning', $$Ad system is currently disabled. Enable it to serve ads.$$),
  ('es', 'adminUnifiedAdDisabledWarning', $$El sistema de anuncios está deshabilitado. Actívelo para mostrar anuncios.$$),
  ('he', 'adminUnifiedAdDisabledWarning', $$מערכת המודעות מושבתת כרגע. הפעל אותה כדי להציג מודעות.$$),

  ('en', 'adminUnifiedAdInternalTitle', $$Internal Ads$$),
  ('es', 'adminUnifiedAdInternalTitle', $$Anuncios internos$$),
  ('he', 'adminUnifiedAdInternalTitle', $$מודעות פנימיות$$),

  ('en', 'adminUnifiedAdInternalToggle', $$Internal ads enabled$$),
  ('es', 'adminUnifiedAdInternalToggle', $$Anuncios internos habilitados$$),
  ('he', 'adminUnifiedAdInternalToggle', $$מודעות פנימיות מופעלות$$),

  ('en', 'adminUnifiedAdExternalTitle', $$External Ads$$),
  ('es', 'adminUnifiedAdExternalTitle', $$Anuncios externos$$),
  ('he', 'adminUnifiedAdExternalTitle', $$מודעות חיצוניות$$),

  ('en', 'adminUnifiedAdExternalToggle', $$External ads enabled$$),
  ('es', 'adminUnifiedAdExternalToggle', $$Anuncios externos habilitados$$),
  ('he', 'adminUnifiedAdExternalToggle', $$מודעות חיצוניות מופעלות$$),

  ('en', 'adminUnifiedAdMasterFirst', $$Master Control takes precedence over individual toggles.$$),
  ('es', 'adminUnifiedAdMasterFirst', $$El control maestro tiene prioridad sobre los interruptores individuales.$$),
  ('he', 'adminUnifiedAdMasterFirst', $$לבקרה הראשית יש עדיפות על פני המתגים הבודדים.$$),

  ('en', 'adminUnifiedAdPlacements', $$Placements$$),
  ('es', 'adminUnifiedAdPlacements', $$Ubicaciones$$),
  ('he', 'adminUnifiedAdPlacements', $$מיקומים$$),

  ('en', 'adminUnifiedAdUserTiers', $$User Tiers$$),
  ('es', 'adminUnifiedAdUserTiers', $$Niveles de usuario$$),
  ('he', 'adminUnifiedAdUserTiers', $$דרגות משתמש$$),

  ('en', 'adminUnifiedAdSchedule', $$Schedule$$),
  ('es', 'adminUnifiedAdSchedule', $$Horario$$),
  ('he', 'adminUnifiedAdSchedule', $$לוח זמנים$$),

  ('en', 'adminUnifiedAdStartTime', $$Start time$$),
  ('es', 'adminUnifiedAdStartTime', $$Hora de inicio$$),
  ('he', 'adminUnifiedAdStartTime', $$שעת התחלה$$),

  ('en', 'adminUnifiedAdEndTime', $$End time$$),
  ('es', 'adminUnifiedAdEndTime', $$Hora de fin$$),
  ('he', 'adminUnifiedAdEndTime', $$שעת סיום$$),

  ('en', 'adminUnifiedAdRateLimiting', $$Rate Limiting$$),
  ('es', 'adminUnifiedAdRateLimiting', $$Límite de frecuencia$$),
  ('he', 'adminUnifiedAdRateLimiting', $$הגבלת קצב$$),

  ('en', 'adminUnifiedAdMaxImpressions', $$Maximum impressions per session$$),
  ('es', 'adminUnifiedAdMaxImpressions', $$Máximo de impresiones por sesión$$),
  ('he', 'adminUnifiedAdMaxImpressions', $$מקסימום הופעות לכל סשן$$),

  ('en', 'adminUnifiedAdMinMinutes', $$Minimum minutes between ads$$),
  ('es', 'adminUnifiedAdMinMinutes', $$Minutos mínimos entre anuncios$$),
  ('he', 'adminUnifiedAdMinMinutes', $$מינימום דקות בין מודעות$$),

  ('en', 'adminUnifiedAdFirstImpressionDelay', $$First impression delay (seconds)$$),
  ('es', 'adminUnifiedAdFirstImpressionDelay', $$Retraso de primera impresión (segundos)$$),
  ('he', 'adminUnifiedAdFirstImpressionDelay', $$השהיית הופעה ראשונה (שניות)$$),

  ('en', 'adminUnifiedAdSaveSettings', $$Save Settings$$),
  ('es', 'adminUnifiedAdSaveSettings', $$Guardar configuración$$),
  ('he', 'adminUnifiedAdSaveSettings', $$שמירת הגדרות$$),

  ('en', 'adminUnifiedAdSaveSuccess', $$Settings saved.$$),
  ('es', 'adminUnifiedAdSaveSuccess', $$Configuración guardada.$$),
  ('he', 'adminUnifiedAdSaveSuccess', $$ההגדרות נשמרו.$$),

  ('en', 'adminUnifiedAdLoadError', $$Failed to load: {error}$$),
  ('es', 'adminUnifiedAdLoadError', $$Error al cargar: {error}$$),
  ('he', 'adminUnifiedAdLoadError', $$הטעינה נכשלה: {error}$$),

  ('en', 'adminUnifiedAdSaveError', $$Failed to save: {error}$$),
  ('es', 'adminUnifiedAdSaveError', $$Error al guardar: {error}$$),
  ('he', 'adminUnifiedAdSaveError', $$השמירה נכשלה: {error}$$),

  -- Admin time format hint
  ('en', 'adminTimeFormatHintHHMM', $$HH:MM$$),
  ('es', 'adminTimeFormatHintHHMM', $$HH:MM$$),
  ('he', 'adminTimeFormatHintHHMM', $$HH:MM$$),

  -- Admin internal / external ads system tabs
  ('en', 'adminInternalSystemTab', $$Internal$$),
  ('es', 'adminInternalSystemTab', $$Interno$$),
  ('he', 'adminInternalSystemTab', $$פנימי$$),

  ('en', 'adminExternalSystemTab', $$External$$),
  ('es', 'adminExternalSystemTab', $$Externo$$),
  ('he', 'adminExternalSystemTab', $$חיצוני$$),

  -- Admin Internal Ads configuration
  ('en', 'adminInternalAdsMasterControlsTitle', $$Master Controls$$),
  ('es', 'adminInternalAdsMasterControlsTitle', $$Controles maestros$$),
  ('he', 'adminInternalAdsMasterControlsTitle', $$בקרות ראשיות$$),

  ('en', 'adminInternalAdsMasterControlsSubtitle', $$Configure internal ad serving behavior.$$),
  ('es', 'adminInternalAdsMasterControlsSubtitle', $$Configure el comportamiento de los anuncios internos.$$),
  ('he', 'adminInternalAdsMasterControlsSubtitle', $$הגדרת התנהגות הצגת מודעות פנימיות.$$),

  ('en', 'adminInternalAdsAllowedPlacements', $$Allowed Placements$$),
  ('es', 'adminInternalAdsAllowedPlacements', $$Ubicaciones permitidas$$),
  ('he', 'adminInternalAdsAllowedPlacements', $$מיקומים מותרים$$),

  ('en', 'adminInternalAdsAllowedPlatforms', $$Allowed Platforms$$),
  ('es', 'adminInternalAdsAllowedPlatforms', $$Plataformas permitidas$$),
  ('he', 'adminInternalAdsAllowedPlatforms', $$פלטפורמות מותרות$$),

  ('en', 'adminInternalAdsAllowedTiers', $$Allowed Tiers$$),
  ('es', 'adminInternalAdsAllowedTiers', $$Niveles permitidos$$),
  ('he', 'adminInternalAdsAllowedTiers', $$דרגות מותרות$$),

  ('en', 'adminInternalAdsTargetTiers', $$Target Tiers$$),
  ('es', 'adminInternalAdsTargetTiers', $$Niveles objetivo$$),
  ('he', 'adminInternalAdsTargetTiers', $$דרגות יעד$$),

  ('en', 'adminInternalAdsTargetTiersSubtitle', $$Select which subscription tiers can see internal ads.$$),
  ('es', 'adminInternalAdsTargetTiersSubtitle', $$Seleccione qué niveles de suscripción pueden ver anuncios internos.$$),
  ('he', 'adminInternalAdsTargetTiersSubtitle', $$בחר אילו דרגות מנוי יכולות לראות מודעות פנימיות.$$),

  ('en', 'adminInternalAdsPlacementDisabledByMaster', $$Disabled by master control$$),
  ('es', 'adminInternalAdsPlacementDisabledByMaster', $$Deshabilitado por el control maestro$$),
  ('he', 'adminInternalAdsPlacementDisabledByMaster', $$מושבת על ידי הבקרה הראשית$$),

  -- Admin External Ads configuration (new keys)
  ('en', 'adminExternalAdsActive', $$Active$$),
  ('es', 'adminExternalAdsActive', $$Activo$$),
  ('he', 'adminExternalAdsActive', $$פעיל$$),

  ('en', 'adminExternalAdsInactive', $$Inactive$$),
  ('es', 'adminExternalAdsInactive', $$Inactivo$$),
  ('he', 'adminExternalAdsInactive', $$לא פעיל$$),

  ('en', 'adminExternalAdsAnalytics', $$Analytics$$),
  ('es', 'adminExternalAdsAnalytics', $$Analíticas$$),
  ('he', 'adminExternalAdsAnalytics', $$אנליטיקה$$),

  ('en', 'adminExternalAdsNoData', $$No data available.$$),
  ('es', 'adminExternalAdsNoData', $$No hay datos disponibles.$$),
  ('he', 'adminExternalAdsNoData', $$אין נתונים זמינים.$$),

  ('en', 'adminExternalAdsLoadError', $$Failed to load external ads data.$$),
  ('es', 'adminExternalAdsLoadError', $$Error al cargar datos de anuncios externos.$$),
  ('he', 'adminExternalAdsLoadError', $$טעינת נתוני המודעות החיצוניות נכשלה.$$),

  ('en', 'adminExternalAdsMasterControlsSubtitle', $$Configure external ad serving behavior.$$),
  ('es', 'adminExternalAdsMasterControlsSubtitle', $$Configure el comportamiento de los anuncios externos.$$),
  ('he', 'adminExternalAdsMasterControlsSubtitle', $$הגדרת התנהגות הצגת מודעות חיצוניות.$$),

  ('en', 'adminExternalAdsPlatformConfigTitle', $$Platform Config$$),
  ('es', 'adminExternalAdsPlatformConfigTitle', $$Configuración de plataforma$$),
  ('he', 'adminExternalAdsPlatformConfigTitle', $$תצורת פלטפורמה$$),

  ('en', 'adminExternalAdsPlatformConfigSubtitle', $$Configure platform-specific ad settings.$$),
  ('es', 'adminExternalAdsPlatformConfigSubtitle', $$Configure ajustes específicos de la plataforma.$$),
  ('he', 'adminExternalAdsPlatformConfigSubtitle', $$הגדרת הגדרות מודעות ספציפיות לפלטפורמה.$$),

  ('en', 'adminExternalAdsPlacementConfigTitle', $$Placement Config$$),
  ('es', 'adminExternalAdsPlacementConfigTitle', $$Configuración de ubicación$$),
  ('he', 'adminExternalAdsPlacementConfigTitle', $$תצורת מיקום$$),

  ('en', 'adminExternalAdsPlacementConfigSubtitle', $$Configure placement-specific ad settings.$$),
  ('es', 'adminExternalAdsPlacementConfigSubtitle', $$Configure ajustes específicos de ubicación.$$),
  ('he', 'adminExternalAdsPlacementConfigSubtitle', $$הגדרת הגדרות מודעות ספציפיות למיקום.$$),

  ('en', 'adminExternalAdsTierConfigTitle', $$Tier Config$$),
  ('es', 'adminExternalAdsTierConfigTitle', $$Configuración de nivel$$),
  ('he', 'adminExternalAdsTierConfigTitle', $$תצורת דרגה$$),

  ('en', 'adminExternalAdsTierConfigSubtitle', $$Configure tier-specific ad settings.$$),
  ('es', 'adminExternalAdsTierConfigSubtitle', $$Configure ajustes específicos del nivel.$$),
  ('he', 'adminExternalAdsTierConfigSubtitle', $$הגדרת הגדרות מודעות ספציפיות לדרגה.$$),

  ('en', 'adminExternalAdsRateLimitingTitle', $$Rate Limiting$$),
  ('es', 'adminExternalAdsRateLimitingTitle', $$Límite de frecuencia$$),
  ('he', 'adminExternalAdsRateLimitingTitle', $$הגבלת קצב$$),

  ('en', 'adminExternalAdsRateLimitingSubtitle', $$Configure rate limits for external ad serving.$$),
  ('es', 'adminExternalAdsRateLimitingSubtitle', $$Configure límites de frecuencia para anuncios externos.$$),
  ('he', 'adminExternalAdsRateLimitingSubtitle', $$הגדרת מגבלות קצב להצגת מודעות חיצוניות.$$),

  ('en', 'adminExternalAdsRateLimitPerHour', $$Per hour$$),
  ('es', 'adminExternalAdsRateLimitPerHour', $$Por hora$$),
  ('he', 'adminExternalAdsRateLimitPerHour', $$לשעה$$),

  ('en', 'adminExternalAdsRateLimitPerUser', $$Per user$$),
  ('es', 'adminExternalAdsRateLimitPerUser', $$Por usuario$$),
  ('he', 'adminExternalAdsRateLimitPerUser', $$למשתמש$$),

  ('en', 'adminExternalAdsMetricActiveNetworks', $$Active Networks$$),
  ('es', 'adminExternalAdsMetricActiveNetworks', $$Redes activas$$),
  ('he', 'adminExternalAdsMetricActiveNetworks', $$רשתות פעילות$$),

  ('en', 'adminExternalAdsRecentEvents', $$Recent Events$$),
  ('es', 'adminExternalAdsRecentEvents', $$Eventos recientes$$),
  ('he', 'adminExternalAdsRecentEvents', $$אירועים אחרונים$$),

  ('en', 'adminExternalAdsTimestamp', $$Timestamp$$),
  ('es', 'adminExternalAdsTimestamp', $$Marca de tiempo$$),
  ('he', 'adminExternalAdsTimestamp', $$חותמת זמן$$),

  ('en', 'adminExternalAdsUser', $$User$$),
  ('es', 'adminExternalAdsUser', $$Usuario$$),
  ('he', 'adminExternalAdsUser', $$משתמש$$),

  ('en', 'adminExternalAdsEventType', $$Event Type$$),
  ('es', 'adminExternalAdsEventType', $$Tipo de evento$$),
  ('he', 'adminExternalAdsEventType', $$סוג אירוע$$),

  ('en', 'adminExternalAdsRevenue', $$Revenue$$),
  ('es', 'adminExternalAdsRevenue', $$Ingresos$$),
  ('he', 'adminExternalAdsRevenue', $$הכנסות$$),

  ('en', 'adminExternalAdsCpm', $$CPM$$),
  ('es', 'adminExternalAdsCpm', $$CPM$$),
  ('he', 'adminExternalAdsCpm', $$CPM$$),

  ('en', 'adminExternalAdsCtr', $$CTR$$),
  ('es', 'adminExternalAdsCtr', $$CTR$$),
  ('he', 'adminExternalAdsCtr', $$CTR$$),

  ('en', 'adminExternalAdsConfigEnabled', $$Enabled$$),
  ('es', 'adminExternalAdsConfigEnabled', $$Habilitado$$),
  ('he', 'adminExternalAdsConfigEnabled', $$מופעל$$),

  ('en', 'adminExternalAdsConfigureNetworksHint', $$Configure at least one ad network below.$$),
  ('es', 'adminExternalAdsConfigureNetworksHint', $$Configure al menos una red de anuncios a continuación.$$),
  ('he', 'adminExternalAdsConfigureNetworksHint', $$הגדר לפחות רשת מודעות אחת להלן.$$),

  ('en', 'adminExternalAdsNoNetworks', $$No ad networks configured.$$),
  ('es', 'adminExternalAdsNoNetworks', $$No hay redes de anuncios configuradas.$$),
  ('he', 'adminExternalAdsNoNetworks', $$לא הוגדרו רשתות מודעות.$$),

  ('en', 'adminExternalAdsAnalyticsByNetwork', $$By Network$$),
  ('es', 'adminExternalAdsAnalyticsByNetwork', $$Por red$$),
  ('he', 'adminExternalAdsAnalyticsByNetwork', $$לפי רשת$$),

  ('en', 'adminExternalAdsAnalyticsByPlacement', $$By Placement$$),
  ('es', 'adminExternalAdsAnalyticsByPlacement', $$Por ubicación$$),
  ('he', 'adminExternalAdsAnalyticsByPlacement', $$לפי מיקום$$),

  ('en', 'adminExternalAdsAnalyticsByPlatform', $$By Platform$$),
  ('es', 'adminExternalAdsAnalyticsByPlatform', $$Por plataforma$$),
  ('he', 'adminExternalAdsAnalyticsByPlatform', $$לפי פלטפורמה$$),

  -- Admin Ad Unit management
  ('en', 'adminAdUnitManagement', $$Ad Units$$),
  ('es', 'adminAdUnitManagement', $$Unidades de anuncio$$),
  ('he', 'adminAdUnitManagement', $$יחידות מודעה$$),

  ('en', 'adminAdUnitAdd', $$Add Ad Unit$$),
  ('es', 'adminAdUnitAdd', $$Agregar unidad de anuncio$$),
  ('he', 'adminAdUnitAdd', $$הוספת יחידת מודעה$$),

  ('en', 'adminAdUnitAddTitle', $$New Ad Unit$$),
  ('es', 'adminAdUnitAddTitle', $$Nueva unidad de anuncio$$),
  ('he', 'adminAdUnitAddTitle', $$יחידת מודעה חדשה$$),

  ('en', 'adminAdUnitEditTitle', $$Edit Ad Unit$$),
  ('es', 'adminAdUnitEditTitle', $$Editar unidad de anuncio$$),
  ('he', 'adminAdUnitEditTitle', $$עריכת יחידת מודעה$$),

  ('en', 'adminAdUnitDeleteTitle', $$Delete Ad Unit?$$),
  ('es', 'adminAdUnitDeleteTitle', $$¿Eliminar unidad de anuncio?$$),
  ('he', 'adminAdUnitDeleteTitle', $$למחוק יחידת מודעה?$$),

  ('en', 'adminAdUnitDeleteBody', $$Delete this ad unit? This action cannot be undone.$$),
  ('es', 'adminAdUnitDeleteBody', $$¿Eliminar esta unidad de anuncio? Esta acción no se puede deshacer.$$),
  ('he', 'adminAdUnitDeleteBody', $$למחוק יחידת מודעה זו? לא ניתן לבטל פעולה זו.$$),

  ('en', 'adminAdUnitDeleteSuccess', $$Ad unit deleted.$$),
  ('es', 'adminAdUnitDeleteSuccess', $$Unidad de anuncio eliminada.$$),
  ('he', 'adminAdUnitDeleteSuccess', $$יחידת המודעה נמחקה.$$),

  ('en', 'adminAdUnitEmpty', $$No ad units found.$$),
  ('es', 'adminAdUnitEmpty', $$No se encontraron unidades de anuncio.$$),
  ('he', 'adminAdUnitEmpty', $$לא נמצאו יחידות מודעה.$$),

  ('en', 'adminAdUnitEmptyHint', $$Add your first ad unit to get started.$$),
  ('es', 'adminAdUnitEmptyHint', $$Agregue su primera unidad de anuncio para comenzar.$$),
  ('he', 'adminAdUnitEmptyHint', $$הוסף את יחידת המודעה הראשונה שלך כדי להתחיל.$$),

  ('en', 'adminAdUnitActive', $$Active$$),
  ('es', 'adminAdUnitActive', $$Activo$$),
  ('he', 'adminAdUnitActive', $$פעיל$$),

  ('en', 'adminAdUnitInactive', $$Inactive$$),
  ('es', 'adminAdUnitInactive', $$Inactivo$$),
  ('he', 'adminAdUnitInactive', $$לא פעיל$$),

  ('en', 'adminAdUnitIdLabel', $$Ad Unit ID$$),
  ('es', 'adminAdUnitIdLabel', $$ID de unidad de anuncio$$),
  ('he', 'adminAdUnitIdLabel', $$מזהה יחידת מודעה$$),

  ('en', 'adminAdUnitFieldAdUnitId', $$Ad Unit ID$$),
  ('es', 'adminAdUnitFieldAdUnitId', $$ID de unidad de anuncio$$),
  ('he', 'adminAdUnitFieldAdUnitId', $$מזהה יחידת מודעה$$),

  ('en', 'adminAdUnitFieldAdUnitIdHint', $$For example: ca-app-pub-xxx/yyy$$),
  ('es', 'adminAdUnitFieldAdUnitIdHint', $$Por ejemplo: ca-app-pub-xxx/yyy$$),
  ('he', 'adminAdUnitFieldAdUnitIdHint', $$לדוגמה ca-app-pub-xxx/yyy$$),

  ('en', 'adminAdUnitFieldNetwork', $$Network$$),
  ('es', 'adminAdUnitFieldNetwork', $$Red$$),
  ('he', 'adminAdUnitFieldNetwork', $$רשת$$),

  ('en', 'adminAdUnitNetworkAdmob', $$AdMob$$),
  ('es', 'adminAdUnitNetworkAdmob', $$AdMob$$),
  ('he', 'adminAdUnitNetworkAdmob', $$AdMob$$),

  ('en', 'adminAdUnitNetworkFacebook', $$Facebook$$),
  ('es', 'adminAdUnitNetworkFacebook', $$Facebook$$),
  ('he', 'adminAdUnitNetworkFacebook', $$פייסבוק$$),

  ('en', 'adminAdUnitFieldPlatform', $$Platform$$),
  ('es', 'adminAdUnitFieldPlatform', $$Plataforma$$),
  ('he', 'adminAdUnitFieldPlatform', $$פלטפורמה$$),

  ('en', 'adminAdUnitAllPlatforms', $$All Platforms$$),
  ('es', 'adminAdUnitAllPlatforms', $$Todas las plataformas$$),
  ('he', 'adminAdUnitAllPlatforms', $$כל הפלטפורמות$$),

  ('en', 'adminAdUnitFieldAdFormat', $$Ad Format$$),
  ('es', 'adminAdUnitFieldAdFormat', $$Formato de anuncio$$),
  ('he', 'adminAdUnitFieldAdFormat', $$פורמט מודעה$$),

  ('en', 'adminAdUnitAllFormats', $$All Formats$$),
  ('es', 'adminAdUnitAllFormats', $$Todos los formatos$$),
  ('he', 'adminAdUnitAllFormats', $$כל הפורמטים$$),

  ('en', 'adminAdUnitFormatBanner', $$Banner$$),
  ('es', 'adminAdUnitFormatBanner', $$Banner$$),
  ('he', 'adminAdUnitFormatBanner', $$באנר$$),

  ('en', 'adminAdUnitFormatInterstitial', $$Interstitial$$),
  ('es', 'adminAdUnitFormatInterstitial', $$Intersticial$$),
  ('he', 'adminAdUnitFormatInterstitial', $$בין-דפי$$),

  ('en', 'adminAdUnitFormatRewarded', $$Rewarded$$),
  ('es', 'adminAdUnitFormatRewarded', $$Recompensado$$),
  ('he', 'adminAdUnitFormatRewarded', $$מתוגמל$$),

  ('en', 'adminAdUnitFormatNative', $$Native$$),
  ('es', 'adminAdUnitFormatNative', $$Nativo$$),
  ('he', 'adminAdUnitFormatNative', $$טבעי$$),

  ('en', 'adminAdUnitFormatDisplay', $$Display$$),
  ('es', 'adminAdUnitFormatDisplay', $$Display$$),
  ('he', 'adminAdUnitFormatDisplay', $$תצוגה$$),

  ('en', 'adminAdUnitFieldPlacement', $$Placement$$),
  ('es', 'adminAdUnitFieldPlacement', $$Ubicación$$),
  ('he', 'adminAdUnitFieldPlacement', $$מיקום$$),

  ('en', 'adminAdUnitPlacementHomeInline', $$Home Inline$$),
  ('es', 'adminAdUnitPlacementHomeInline', $$Inicio en línea$$),
  ('he', 'adminAdUnitPlacementHomeInline', $$בית מוטבע$$),

  ('en', 'adminAdUnitPlacementMatchesInline', $$Matches Inline$$),
  ('es', 'adminAdUnitPlacementMatchesInline', $$Coincidencias en línea$$),
  ('he', 'adminAdUnitPlacementMatchesInline', $$התאמות מוטבע$$),

  ('en', 'adminAdUnitPlacementChatsInline', $$Chats Inline$$),
  ('es', 'adminAdUnitPlacementChatsInline', $$Charlas en línea$$),
  ('he', 'adminAdUnitPlacementChatsInline', $$צ'אטים מוטבע$$),

  ('en', 'adminAdUnitPlacementEventsInline', $$Events Inline$$),
  ('es', 'adminAdUnitPlacementEventsInline', $$Eventos en línea$$),
  ('he', 'adminAdUnitPlacementEventsInline', $$אירועים מוטבע$$),

  ('en', 'adminAdUnitFieldPriority', $$Priority$$),
  ('es', 'adminAdUnitFieldPriority', $$Prioridad$$),
  ('he', 'adminAdUnitFieldPriority', $$עדיפות$$),

  ('en', 'adminAdUnitFieldPriorityHint', $$Lower number = higher priority$$),
  ('es', 'adminAdUnitFieldPriorityHint', $$Número más bajo = mayor prioridad$$),
  ('he', 'adminAdUnitFieldPriorityHint', $$מספר נמוך יותר = עדיפות גבוהה יותר$$),

  ('en', 'adminAdUnitAllNetworks', $$All Networks$$),
  ('es', 'adminAdUnitAllNetworks', $$Todas las redes$$),
  ('he', 'adminAdUnitAllNetworks', $$כל הרשתות$$),

  ('en', 'adminAdUnitValidationIdRequired', $$Ad Unit ID is required$$),
  ('es', 'adminAdUnitValidationIdRequired', $$El ID de unidad de anuncio es obligatorio$$),
  ('he', 'adminAdUnitValidationIdRequired', $$מזהה יחידת מודעה הוא שדה חובה$$),

  -- Admin Network management
  ('en', 'adminNetworkManagement', $$Ad Networks$$),
  ('es', 'adminNetworkManagement', $$Redes de anuncios$$),
  ('he', 'adminNetworkManagement', $$רשתות מודעות$$),

  ('en', 'adminNetworkAdd', $$Add Network$$),
  ('es', 'adminNetworkAdd', $$Agregar red$$),
  ('he', 'adminNetworkAdd', $$הוספת רשת$$),

  ('en', 'adminNetworkAddTitle', $$New Ad Network$$),
  ('es', 'adminNetworkAddTitle', $$Nueva red de anuncios$$),
  ('he', 'adminNetworkAddTitle', $$רשת מודעות חדשה$$),

  ('en', 'adminNetworkEditTitle', $$Edit Ad Network$$),
  ('es', 'adminNetworkEditTitle', $$Editar red de anuncios$$),
  ('he', 'adminNetworkEditTitle', $$עריכת רשת מודעות$$),

  ('en', 'adminNetworkDeleteTitle', $$Delete Ad Network?$$),
  ('es', 'adminNetworkDeleteTitle', $$¿Eliminar red de anuncios?$$),
  ('he', 'adminNetworkDeleteTitle', $$למחוק רשת מודעות?$$),

  ('en', 'adminNetworkDeleteBody', $$Delete this ad network? This action cannot be undone.$$),
  ('es', 'adminNetworkDeleteBody', $$¿Eliminar esta red de anuncios? Esta acción no se puede deshacer.$$),
  ('he', 'adminNetworkDeleteBody', $$למחוק רשת מודעות זו? לא ניתן לבטל פעולה זו.$$),

  ('en', 'adminNetworkDeleteSuccess', $$Ad network deleted.$$),
  ('es', 'adminNetworkDeleteSuccess', $$Red de anuncios eliminada.$$),
  ('he', 'adminNetworkDeleteSuccess', $$רשת המודעות נמחקה.$$),

  ('en', 'adminNetworkEmpty', $$No ad networks found.$$),
  ('es', 'adminNetworkEmpty', $$No se encontraron redes de anuncios.$$),
  ('he', 'adminNetworkEmpty', $$לא נמצאו רשתות מודעות.$$),

  ('en', 'adminNetworkEmptyHint', $$Add your first ad network to get started.$$),
  ('es', 'adminNetworkEmptyHint', $$Agregue su primera red de anuncios para comenzar.$$),
  ('he', 'adminNetworkEmptyHint', $$הוסף את רשת המודעות הראשונה שלך כדי להתחיל.$$),

  ('en', 'adminNetworkEnabled', $$Enabled$$),
  ('es', 'adminNetworkEnabled', $$Habilitada$$),
  ('he', 'adminNetworkEnabled', $$מופעלת$$),

  ('en', 'adminNetworkDisabled', $$Disabled$$),
  ('es', 'adminNetworkDisabled', $$Deshabilitada$$),
  ('he', 'adminNetworkDisabled', $$מושבתת$$),

  ('en', 'adminNetworkFieldDisplayName', $$Display Name$$),
  ('es', 'adminNetworkFieldDisplayName', $$Nombre mostrado$$),
  ('he', 'adminNetworkFieldDisplayName', $$שם תצוגה$$),

  ('en', 'adminNetworkFieldDisplayNameHint', $$For example: Google AdMob$$),
  ('es', 'adminNetworkFieldDisplayNameHint', $$Por ejemplo: Google AdMob$$),
  ('he', 'adminNetworkFieldDisplayNameHint', $$לדוגמה Google AdMob$$),

  ('en', 'adminNetworkFieldProvider', $$Provider$$),
  ('es', 'adminNetworkFieldProvider', $$Proveedor$$),
  ('he', 'adminNetworkFieldProvider', $$ספק$$),

  ('en', 'adminNetworkFieldPriority', $$Priority$$),
  ('es', 'adminNetworkFieldPriority', $$Prioridad$$),
  ('he', 'adminNetworkFieldPriority', $$עדיפות$$),

  ('en', 'adminNetworkFieldPriorityHint', $$Lower number = higher priority$$),
  ('es', 'adminNetworkFieldPriorityHint', $$Número más bajo = mayor prioridad$$),
  ('he', 'adminNetworkFieldPriorityHint', $$מספר נמוך יותר = עדיפות גבוהה יותר$$),

  ('en', 'adminNetworkPriority', $$Priority$$),
  ('es', 'adminNetworkPriority', $$Prioridad$$),
  ('he', 'adminNetworkPriority', $$עדיפות$$),

  ('en', 'adminNetworkProvider', $$Provider$$),
  ('es', 'adminNetworkProvider', $$Proveedor$$),
  ('he', 'adminNetworkProvider', $$ספק$$),

  ('en', 'adminNetworkNameAdmob', $$AdMob$$),
  ('es', 'adminNetworkNameAdmob', $$AdMob$$),
  ('he', 'adminNetworkNameAdmob', $$AdMob$$),

  ('en', 'adminNetworkNameFacebook', $$Facebook$$),
  ('es', 'adminNetworkNameFacebook', $$Facebook$$),
  ('he', 'adminNetworkNameFacebook', $$פייסבוק$$),

  ('en', 'adminNetworkNameFacebookFull', $$Meta Audience Network$$),
  ('es', 'adminNetworkNameFacebookFull', $$Meta Audience Network$$),
  ('he', 'adminNetworkNameFacebookFull', $$Meta Audience Network$$),

  ('en', 'adminNetworkNameApplovin', $$AppLovin$$),
  ('es', 'adminNetworkNameApplovin', $$AppLovin$$),
  ('he', 'adminNetworkNameApplovin', $$AppLovin$$),

  ('en', 'adminNetworkNameUnity', $$Unity Ads$$),
  ('es', 'adminNetworkNameUnity', $$Unity Ads$$),
  ('he', 'adminNetworkNameUnity', $$Unity Ads$$),

  ('en', 'adminNetworkValidationNameRequired', $$Network name is required$$),
  ('es', 'adminNetworkValidationNameRequired', $$El nombre de la red es obligatorio$$),
  ('he', 'adminNetworkValidationNameRequired', $$שם הרשת הוא שדה חובה$$),

  -- Admin Sponsored Ads (new keys)
  ('en', 'adminSponsoredAdsInternalName', $$Internal Name$$),
  ('es', 'adminSponsoredAdsInternalName', $$Nombre interno$$),
  ('he', 'adminSponsoredAdsInternalName', $$שם פנימי$$),

  ('en', 'adminSponsoredAdsAdvertiserName', $$Advertiser Name$$),
  ('es', 'adminSponsoredAdsAdvertiserName', $$Nombre del anunciante$$),
  ('he', 'adminSponsoredAdsAdvertiserName', $$שם המפרסם$$),

  ('en', 'adminSponsoredAdsDestinationUrl', $$Destination URL$$),
  ('es', 'adminSponsoredAdsDestinationUrl', $$URL de destino$$),
  ('he', 'adminSponsoredAdsDestinationUrl', $$כתובת URL ליעד$$),

  ('en', 'adminSponsoredAdsImageUrl', $$Image URL$$),
  ('es', 'adminSponsoredAdsImageUrl', $$URL de la imagen$$),
  ('he', 'adminSponsoredAdsImageUrl', $$כתובת URL של התמונה$$),

  ('en', 'adminSponsoredAdsImageEmpty', $$No image selected.$$),
  ('es', 'adminSponsoredAdsImageEmpty', $$No hay imagen seleccionada.$$),
  ('he', 'adminSponsoredAdsImageEmpty', $$לא נבחרה תמונה.$$),

  ('en', 'adminSponsoredAdsClearImage', $$Clear Image$$),
  ('es', 'adminSponsoredAdsClearImage', $$Borrar imagen$$),
  ('he', 'adminSponsoredAdsClearImage', $$ניקוי תמונה$$),

  ('en', 'adminSponsoredAdsUploadImage', $$Upload Image$$),
  ('es', 'adminSponsoredAdsUploadImage', $$Subir imagen$$),
  ('he', 'adminSponsoredAdsUploadImage', $$העלאת תמונה$$),

  ('en', 'adminSponsoredAdsUploadSuccess', $$Image uploaded.$$),
  ('es', 'adminSponsoredAdsUploadSuccess', $$Imagen subida.$$),
  ('he', 'adminSponsoredAdsUploadSuccess', $$התמונה הועלתה.$$),

  ('en', 'adminSponsoredAdsUploadFailed', $$Failed to upload image.$$),
  ('es', 'adminSponsoredAdsUploadFailed', $$Error al subir la imagen.$$),
  ('he', 'adminSponsoredAdsUploadFailed', $$העלאת התמונה נכשלה.$$),

  ('en', 'adminSponsoredAdsImagePreviewTitle', $$Image Preview$$),
  ('es', 'adminSponsoredAdsImagePreviewTitle', $$Vista previa de la imagen$$),
  ('he', 'adminSponsoredAdsImagePreviewTitle', $$תצוגה מקדימה של התמונה$$),

  ('en', 'adminSponsoredAdsImagePreviewFailed', $$Failed to load image preview.$$),
  ('es', 'adminSponsoredAdsImagePreviewFailed', $$Error al cargar la vista previa.$$),
  ('he', 'adminSponsoredAdsImagePreviewFailed', $$טעינת התצוגה המקדימה נכשלה.$$),

  ('en', 'adminSponsoredAdsUseDemoPreset', $$Use demo preset$$),
  ('es', 'adminSponsoredAdsUseDemoPreset', $$Usar preset de demostración$$),
  ('he', 'adminSponsoredAdsUseDemoPreset', $$שימוש בתצורת הדגמה$$),

  ('en', 'adminSponsoredAdsSaveNew', $$Save as new$$),
  ('es', 'adminSponsoredAdsSaveNew', $$Guardar como nuevo$$),
  ('he', 'adminSponsoredAdsSaveNew', $$שמור כחדש$$),

  ('en', 'adminSponsoredAdsSaveChanges', $$Save Changes$$),
  ('es', 'adminSponsoredAdsSaveChanges', $$Guardar cambios$$),
  ('he', 'adminSponsoredAdsSaveChanges', $$שמירת שינויים$$),

  ('en', 'adminSponsoredAdsCreateSuccess', $$Ad creative created.$$),
  ('es', 'adminSponsoredAdsCreateSuccess', $$Creativo publicitario creado.$$),
  ('he', 'adminSponsoredAdsCreateSuccess', $$המודעה נוצרה.$$),

  ('en', 'adminSponsoredAdsUpdateSuccess', $$Ad creative updated.$$),
  ('es', 'adminSponsoredAdsUpdateSuccess', $$Creativo publicitario actualizado.$$),
  ('he', 'adminSponsoredAdsUpdateSuccess', $$המודעה עודכנה.$$),

  ('en', 'adminSponsoredAdsDeleteSuccess', $$Ad creative deleted.$$),
  ('es', 'adminSponsoredAdsDeleteSuccess', $$Creativo publicitario eliminado.$$),
  ('he', 'adminSponsoredAdsDeleteSuccess', $$המודעה נמחקה.$$),

  ('en', 'adminSponsoredAdsDeleteFailed', $$Failed to delete ad creative.$$),
  ('es', 'adminSponsoredAdsDeleteFailed', $$Error al eliminar el creativo.$$),
  ('he', 'adminSponsoredAdsDeleteFailed', $$מחיקת המודעה נכשלה.$$),

  ('en', 'adminSponsoredAdsDeleteTitle', $$Delete Ad Creative?$$),
  ('es', 'adminSponsoredAdsDeleteTitle', $$¿Eliminar creativo publicitario?$$),
  ('he', 'adminSponsoredAdsDeleteTitle', $$למחוק את המודעה?$$),

  ('en', 'adminSponsoredAdsLoadFailed', $$Failed to load ad creatives.$$),
  ('es', 'adminSponsoredAdsLoadFailed', $$Error al cargar los creativos.$$),
  ('he', 'adminSponsoredAdsLoadFailed', $$טעינת המודעות נכשלה.$$),

  ('en', 'adminSponsoredAdsSaveFailed', $$Failed to save ad creative.$$),
  ('es', 'adminSponsoredAdsSaveFailed', $$Error al guardar el creativo.$$),
  ('he', 'adminSponsoredAdsSaveFailed', $$שמירת המודעה נכשלה.$$),

  ('en', 'adminSponsoredAdsSearchHint', $$Search by name, advertiser, or URL$$),
  ('es', 'adminSponsoredAdsSearchHint', $$Buscar por nombre, anunciante o URL$$),
  ('he', 'adminSponsoredAdsSearchHint', $$חיפוש לפי שם, מפרסם או URL$$),

  ('en', 'adminSponsoredAdsEmpty', $$No ad creatives found.$$),
  ('es', 'adminSponsoredAdsEmpty', $$No se encontraron creativos.$$),
  ('he', 'adminSponsoredAdsEmpty', $$לא נמצאו מודעות.$$),

  ('en', 'adminSponsoredAdsFilterAll', $$All$$),
  ('es', 'adminSponsoredAdsFilterAll', $$Todos$$),
  ('he', 'adminSponsoredAdsFilterAll', $$הכול$$),

  ('en', 'adminSponsoredAdsFilterDraft', $$Draft$$),
  ('es', 'adminSponsoredAdsFilterDraft', $$Borrador$$),
  ('he', 'adminSponsoredAdsFilterDraft', $$טיוטה$$),

  ('en', 'adminSponsoredAdsFilterApproved', $$Approved$$),
  ('es', 'adminSponsoredAdsFilterApproved', $$Aprobado$$),
  ('he', 'adminSponsoredAdsFilterApproved', $$מאושר$$),

  ('en', 'adminSponsoredAdsFilterPaused', $$Paused$$),
  ('es', 'adminSponsoredAdsFilterPaused', $$Pausado$$),
  ('he', 'adminSponsoredAdsFilterPaused', $$מושהה$$),

  ('en', 'adminSponsoredAdsStatusDraft', $$Draft$$),
  ('es', 'adminSponsoredAdsStatusDraft', $$Borrador$$),
  ('he', 'adminSponsoredAdsStatusDraft', $$טיוטה$$),

  ('en', 'adminSponsoredAdsStatusApproved', $$Approved$$),
  ('es', 'adminSponsoredAdsStatusApproved', $$Aprobado$$),
  ('he', 'adminSponsoredAdsStatusApproved', $$מאושר$$),

  ('en', 'adminSponsoredAdsStatusPaused', $$Paused$$),
  ('es', 'adminSponsoredAdsStatusPaused', $$Pausado$$),
  ('he', 'adminSponsoredAdsStatusPaused', $$מושהה$$),

  ('en', 'adminSponsoredAdsStatusRejected', $$Rejected$$),
  ('es', 'adminSponsoredAdsStatusRejected', $$Rechazado$$),
  ('he', 'adminSponsoredAdsStatusRejected', $$נדחה$$),

  ('en', 'adminSponsoredAdsCampaignActive', $$Active$$),
  ('es', 'adminSponsoredAdsCampaignActive', $$Activo$$),
  ('he', 'adminSponsoredAdsCampaignActive', $$פעיל$$),

  ('en', 'adminSponsoredAdsCreativeActive', $$Creative Active$$),
  ('es', 'adminSponsoredAdsCreativeActive', $$Creativo activo$$),
  ('he', 'adminSponsoredAdsCreativeActive', $$מודעה פעילה$$),

  ('en', 'adminSponsoredAdsStartsAt', $$Starts at$$),
  ('es', 'adminSponsoredAdsStartsAt', $$Comienza en$$),
  ('he', 'adminSponsoredAdsStartsAt', $$מתחיל בתאריך$$),

  ('en', 'adminSponsoredAdsEndsAt', $$Ends at$$),
  ('es', 'adminSponsoredAdsEndsAt', $$Termina en$$),
  ('he', 'adminSponsoredAdsEndsAt', $$מסתיים בתאריך$$),

  ('en', 'adminSponsoredAdsSortPriority', $$Sort by priority$$),
  ('es', 'adminSponsoredAdsSortPriority', $$Ordenar por prioridad$$),
  ('he', 'adminSponsoredAdsSortPriority', $$מיין לפי עדיפות$$),

  ('en', 'adminSponsoredAdsPlacement', $$Placement$$),
  ('es', 'adminSponsoredAdsPlacement', $$Ubicación$$),
  ('he', 'adminSponsoredAdsPlacement', $$מיקום$$),

  ('en', 'adminSponsoredAdsPlacements', $$Placements$$),
  ('es', 'adminSponsoredAdsPlacements', $$Ubicaciones$$),
  ('he', 'adminSponsoredAdsPlacements', $$מיקומים$$),

  ('en', 'adminSponsoredAdsPlacementHome', $$Home$$),
  ('es', 'adminSponsoredAdsPlacementHome', $$Inicio$$),
  ('he', 'adminSponsoredAdsPlacementHome', $$בית$$),

  ('en', 'adminSponsoredAdsPlacementMatches', $$Matches$$),
  ('es', 'adminSponsoredAdsPlacementMatches', $$Coincidencias$$),
  ('he', 'adminSponsoredAdsPlacementMatches', $$התאמות$$),

  ('en', 'adminSponsoredAdsPlacementChats', $$Chats$$),
  ('es', 'adminSponsoredAdsPlacementChats', $$Charlas$$),
  ('he', 'adminSponsoredAdsPlacementChats', $$צ'אטים$$),

  ('en', 'adminSponsoredAdsPlacementEvents', $$Events$$),
  ('es', 'adminSponsoredAdsPlacementEvents', $$Eventos$$),
  ('he', 'adminSponsoredAdsPlacementEvents', $$אירועים$$),

  ('en', 'adminSponsoredAdsPlacementProfile', $$Profile$$),
  ('es', 'adminSponsoredAdsPlacementProfile', $$Perfil$$),
  ('he', 'adminSponsoredAdsPlacementProfile', $$פרופיל$$),

  ('en', 'adminSponsoredAdsPlatform', $$Platform$$),
  ('es', 'adminSponsoredAdsPlatform', $$Plataforma$$),
  ('he', 'adminSponsoredAdsPlatform', $$פלטפורמה$$),

  ('en', 'adminSponsoredAdsPlatformAll', $$All Platforms$$),
  ('es', 'adminSponsoredAdsPlatformAll', $$Todas las plataformas$$),
  ('he', 'adminSponsoredAdsPlatformAll', $$כל הפלטפורמות$$),

  ('en', 'adminSponsoredAdsPlatformAndroid', $$Android$$),
  ('es', 'adminSponsoredAdsPlatformAndroid', $$Android$$),
  ('he', 'adminSponsoredAdsPlatformAndroid', $$אנדרואיד$$),

  ('en', 'adminSponsoredAdsPlatformIos', $$iOS$$),
  ('es', 'adminSponsoredAdsPlatformIos', $$iOS$$),
  ('he', 'adminSponsoredAdsPlatformIos', $$iOS$$),

  ('en', 'adminSponsoredAdsPlatformWeb', $$Web$$),
  ('es', 'adminSponsoredAdsPlatformWeb', $$Web$$),
  ('he', 'adminSponsoredAdsPlatformWeb', $$אינטרנט$$),

  ('en', 'adminSponsoredAdsPlatformLinux', $$Linux$$),
  ('es', 'adminSponsoredAdsPlatformLinux', $$Linux$$),
  ('he', 'adminSponsoredAdsPlatformLinux', $$Linux$$),

  ('en', 'adminSponsoredAdsPlatformMacos', $$macOS$$),
  ('es', 'adminSponsoredAdsPlatformMacos', $$macOS$$),
  ('he', 'adminSponsoredAdsPlatformMacos', $$macOS$$),

  ('en', 'adminSponsoredAdsPlatformWindows', $$Windows$$),
  ('es', 'adminSponsoredAdsPlatformWindows', $$Windows$$),
  ('he', 'adminSponsoredAdsPlatformWindows', $$Windows$$),

  ('en', 'adminSponsoredAdsEnableAction', $$Enable$$),
  ('es', 'adminSponsoredAdsEnableAction', $$Habilitar$$),
  ('he', 'adminSponsoredAdsEnableAction', $$הפעל$$),

  ('en', 'adminSponsoredAdsDisableAction', $$Disable$$),
  ('es', 'adminSponsoredAdsDisableAction', $$Deshabilitar$$),
  ('he', 'adminSponsoredAdsDisableAction', $$השבת$$),

  ('en', 'adminSponsoredAdsFamilySafe', $$Family Safe$$),
  ('es', 'adminSponsoredAdsFamilySafe', $$Apto para familias$$),
  ('he', 'adminSponsoredAdsFamilySafe', $$מתאים למשפחות$$),

  ('en', 'adminSponsoredAdsModerationStatus', $$Moderation Status$$),
  ('es', 'adminSponsoredAdsModerationStatus', $$Estado de moderación$$),
  ('he', 'adminSponsoredAdsModerationStatus', $$סטטוס ניהול תוכן$$),

  ('en', 'adminSponsoredAdsFormSectionCampaign', $$Campaign$$),
  ('es', 'adminSponsoredAdsFormSectionCampaign', $$Campaña$$),
  ('he', 'adminSponsoredAdsFormSectionCampaign', $$קמפיין$$),

  ('en', 'adminSponsoredAdsFormSectionCreative', $$Creative$$),
  ('es', 'adminSponsoredAdsFormSectionCreative', $$Creativo$$),
  ('he', 'adminSponsoredAdsFormSectionCreative', $$מודעה$$),

  ('en', 'adminSponsoredAdsFormActions', $$Actions$$),
  ('es', 'adminSponsoredAdsFormActions', $$Acciones$$),
  ('he', 'adminSponsoredAdsFormActions', $$פעולות$$),

  ('en', 'adminSponsoredAdsUnsavedTitle', $$Unsaved Changes$$),
  ('es', 'adminSponsoredAdsUnsavedTitle', $$Cambios sin guardar$$),
  ('he', 'adminSponsoredAdsUnsavedTitle', $$שינויים שלא נשמרו$$),

  ('en', 'adminSponsoredAdsUnsavedBody', $$You have unsaved changes. Discard them?$$),
  ('es', 'adminSponsoredAdsUnsavedBody', $$Tiene cambios sin guardar. ¿Descartarlos?$$),
  ('he', 'adminSponsoredAdsUnsavedBody', $$יש לך שינויים שלא נשמרו. לבטלם?$$),

  ('en', 'adminSponsoredAdsUnsavedDiscard', $$Discard$$),
  ('es', 'adminSponsoredAdsUnsavedDiscard', $$Descartar$$),
  ('he', 'adminSponsoredAdsUnsavedDiscard', $$בטל$$),

  ('en', 'adminSponsoredAdsValidationInternalName', $$Internal name is required$$),
  ('es', 'adminSponsoredAdsValidationInternalName', $$El nombre interno es obligatorio$$),
  ('he', 'adminSponsoredAdsValidationInternalName', $$שם פנימי הוא שדה חובה$$),

  ('en', 'adminSponsoredAdsValidationAdvertiserName', $$Advertiser name is required$$),
  ('es', 'adminSponsoredAdsValidationAdvertiserName', $$El nombre del anunciante es obligatorio$$),
  ('he', 'adminSponsoredAdsValidationAdvertiserName', $$שם המפרסם הוא שדה חובה$$),

  ('en', 'adminSponsoredAdsValidationDestinationUrl', $$Destination URL is required$$),
  ('es', 'adminSponsoredAdsValidationDestinationUrl', $$La URL de destino es obligatoria$$),
  ('he', 'adminSponsoredAdsValidationDestinationUrl', $$כתובת URL ליעד היא שדה חובה$$),

  ('en', 'adminSponsoredAdsValidationDestinationUrlRequired', $$Please enter a valid URL$$),
  ('es', 'adminSponsoredAdsValidationDestinationUrlRequired', $$Introduzca una URL válida$$),
  ('he', 'adminSponsoredAdsValidationDestinationUrlRequired', $$נא להזין כתובת URL חוקית$$),

  ('en', 'adminSponsoredAdsValidationPlacementRequired', $$At least one placement is required$$),
  ('es', 'adminSponsoredAdsValidationPlacementRequired', $$Se requiere al menos una ubicación$$),
  ('he', 'adminSponsoredAdsValidationPlacementRequired', $$נדרש לפחות מיקום אחד$$),

  ('en', 'adminSponsoredAdsValidationContentRequired', $$Content is required for all selected locales$$),
  ('es', 'adminSponsoredAdsValidationContentRequired', $$El contenido es obligatorio para todos los idiomas seleccionados$$),
  ('he', 'adminSponsoredAdsValidationContentRequired', $$תוכן נדרש עבור כל השפות שנבחרו$$),

  ('en', 'adminSponsoredAdsAnalyticsTitle', $$Analytics$$),
  ('es', 'adminSponsoredAdsAnalyticsTitle', $$Analíticas$$),
  ('he', 'adminSponsoredAdsAnalyticsTitle', $$אנליטיקה$$),

  ('en', 'adminSponsoredAdsMetricImpressions', $$Impressions$$),
  ('es', 'adminSponsoredAdsMetricImpressions', $$Impresiones$$),
  ('he', 'adminSponsoredAdsMetricImpressions', $$הופעות$$),

  ('en', 'adminSponsoredAdsMetricClicks', $$Clicks$$),
  ('es', 'adminSponsoredAdsMetricClicks', $$Clics$$),
  ('he', 'adminSponsoredAdsMetricClicks', $$קליקים$$),

  ('en', 'adminSponsoredAdsMetricCtr', $$CTR$$),
  ('es', 'adminSponsoredAdsMetricCtr', $$CTR$$),
  ('he', 'adminSponsoredAdsMetricCtr', $$CTR$$),

  ('en', 'adminSponsoredAdsMetricLastEvent', $$Last Event$$),
  ('es', 'adminSponsoredAdsMetricLastEvent', $$Último evento$$),
  ('he', 'adminSponsoredAdsMetricLastEvent', $$אירוע אחרון$$),

  ('en', 'adminSponsoredAdsMetricReports', $$Reports$$),
  ('es', 'adminSponsoredAdsMetricReports', $$Reportes$$),
  ('he', 'adminSponsoredAdsMetricReports', $$דוחות$$),

  ('en', 'adminSponsoredAdsImpressionsDialogTitle', $$Impressions Detail$$),
  ('es', 'adminSponsoredAdsImpressionsDialogTitle', $$Detalle de impresiones$$),
  ('he', 'adminSponsoredAdsImpressionsDialogTitle', $$פירוט הופעות$$),

  ('en', 'adminSponsoredAdsClicksDialogTitle', $$Clicks Detail$$),
  ('es', 'adminSponsoredAdsClicksDialogTitle', $$Detalle de clics$$),
  ('he', 'adminSponsoredAdsClicksDialogTitle', $$פירוט קליקים$$),

  ('en', 'adminSponsoredAdsEventLocale', $$Locale$$),
  ('es', 'adminSponsoredAdsEventLocale', $$Idioma$$),
  ('he', 'adminSponsoredAdsEventLocale', $$שפה$$),

  ('en', 'adminSponsoredAdsEventPlacement', $$Placement$$),
  ('es', 'adminSponsoredAdsEventPlacement', $$Ubicación$$),
  ('he', 'adminSponsoredAdsEventPlacement', $$מיקום$$),

  ('en', 'adminSponsoredAdsEventPlatform', $$Platform$$),
  ('es', 'adminSponsoredAdsEventPlatform', $$Plataforma$$),
  ('he', 'adminSponsoredAdsEventPlatform', $$פלטפורמה$$),

  ('en', 'adminSponsoredAdsEventDestinationUrl', $$Destination URL$$),
  ('es', 'adminSponsoredAdsEventDestinationUrl', $$URL de destino$$),
  ('he', 'adminSponsoredAdsEventDestinationUrl', $$כתובת URL ליעד$$),

  ('en', 'adminSponsoredAdsEventNoData', $$No event data.$$),
  ('es', 'adminSponsoredAdsEventNoData', $$Sin datos de evento.$$),
  ('he', 'adminSponsoredAdsEventNoData', $$אין נתוני אירוע.$$),

  ('en', 'adminSponsoredAdsReportsTitle', $$Reports$$),
  ('es', 'adminSponsoredAdsReportsTitle', $$Reportes$$),
  ('he', 'adminSponsoredAdsReportsTitle', $$דוחות$$),

  ('en', 'adminSponsoredAdsReportsEmpty', $$No reports yet.$$),
  ('es', 'adminSponsoredAdsReportsEmpty', $$Aún no hay reportes.$$),
  ('he', 'adminSponsoredAdsReportsEmpty', $$עדיין אין דוחות.$$),

  ('en', 'adminSponsoredAdsReportsDialogTitle', $$Reports Detail$$),
  ('es', 'adminSponsoredAdsReportsDialogTitle', $$Detalle de reportes$$),
  ('he', 'adminSponsoredAdsReportsDialogTitle', $$פירוט דוחות$$),

  ('en', 'adminSponsoredAdsReportDetailsFallback', $$No details available.$$),
  ('es', 'adminSponsoredAdsReportDetailsFallback', $$No hay detalles disponibles.$$),
  ('he', 'adminSponsoredAdsReportDetailsFallback', $$אין פרטים זמינים.$$),

  ('en', 'adminSponsoredAdsReportReporterFallback', $$Unknown reporter$$),
  ('es', 'adminSponsoredAdsReportReporterFallback', $$Denunciante desconocido$$),
  ('he', 'adminSponsoredAdsReportReporterFallback', $$מדווח לא ידוע$$),

  ('en', 'adminSponsoredAdsReportReasonUserReported', $$User reported$$),
  ('es', 'adminSponsoredAdsReportReasonUserReported', $$Denunciado por usuario$$),
  ('he', 'adminSponsoredAdsReportReasonUserReported', $$דווח על ידי משתמש$$),

  ('en', 'adminSponsoredAdsReportLastDialogTitle', $$Last Report Detail$$),
  ('es', 'adminSponsoredAdsReportLastDialogTitle', $$Detalle del último reporte$$),
  ('he', 'adminSponsoredAdsReportLastDialogTitle', $$פירוט הדוח האחרון$$),

  ('en', 'adminSponsoredAdsReportUsersDialogTitle', $$Users Who Reported$$),
  ('es', 'adminSponsoredAdsReportUsersDialogTitle', $$Usuarios que denunciaron$$),
  ('he', 'adminSponsoredAdsReportUsersDialogTitle', $$משתמשים שדיווחו$$),

  ('en', 'adminSponsoredAdsReportSummaryTimes', $$Times reported$$),
  ('es', 'adminSponsoredAdsReportSummaryTimes', $$Veces denunciado$$),
  ('he', 'adminSponsoredAdsReportSummaryTimes', $$מספר דיווחים$$),

  ('en', 'adminSponsoredAdsReportSummaryUsers', $$Unique users$$),
  ('es', 'adminSponsoredAdsReportSummaryUsers', $$Usuarios únicos$$),
  ('he', 'adminSponsoredAdsReportSummaryUsers', $$משתמשים ייחודיים$$),

  ('en', 'adminSponsoredAdsReportSummaryLatestPlacement', $$Latest placement$$),
  ('es', 'adminSponsoredAdsReportSummaryLatestPlacement', $$Última ubicación$$),
  ('he', 'adminSponsoredAdsReportSummaryLatestPlacement', $$מיקום אחרון$$),

  ('en', 'adminSponsoredAdsReportSummaryLatestReason', $$Latest reason$$),
  ('es', 'adminSponsoredAdsReportSummaryLatestReason', $$Última razón$$),
  ('he', 'adminSponsoredAdsReportSummaryLatestReason', $$סיבה אחרונה$$),

  ('en', 'adminSponsoredAdsReportSummaryLastReported', $$Last reported$$),
  ('es', 'adminSponsoredAdsReportSummaryLastReported', $$Último reporte$$),
  ('he', 'adminSponsoredAdsReportSummaryLastReported', $$דווח לאחרונה$$),

  ('en', 'adminSponsoredAdsLocalePrimary', $$Primary$$),
  ('es', 'adminSponsoredAdsLocalePrimary', $$Principal$$),
  ('he', 'adminSponsoredAdsLocalePrimary', $$ראשי$$),

  ('en', 'adminSponsoredAdsLocaleClear', $$Clear$$),
  ('es', 'adminSponsoredAdsLocaleClear', $$Borrar$$),
  ('he', 'adminSponsoredAdsLocaleClear', $$נקה$$),

  ('en', 'adminSponsoredAdsLocaleRemove', $$Remove$$),
  ('es', 'adminSponsoredAdsLocaleRemove', $$Eliminar$$),
  ('he', 'adminSponsoredAdsLocaleRemove', $$הסר$$),

  ('en', 'adminSponsoredAdsLocaleCopyEnglish', $$Copy from English$$),
  ('es', 'adminSponsoredAdsLocaleCopyEnglish', $$Copiar del inglés$$),
  ('he', 'adminSponsoredAdsLocaleCopyEnglish', $$העתק מאנגלית$$),

  ('en', 'adminSponsoredAdsLocaleFieldHeadline', $$Headline$$),
  ('es', 'adminSponsoredAdsLocaleFieldHeadline', $$Titular$$),
  ('he', 'adminSponsoredAdsLocaleFieldHeadline', $$כותרת$$),

  ('en', 'adminSponsoredAdsLocaleFieldBody', $$Body$$),
  ('es', 'adminSponsoredAdsLocaleFieldBody', $$Cuerpo$$),
  ('he', 'adminSponsoredAdsLocaleFieldBody', $$גוף$$),

  ('en', 'adminSponsoredAdsLocaleFieldCta', $$CTA$$),
  ('es', 'adminSponsoredAdsLocaleFieldCta', $$CTA$$),
  ('he', 'adminSponsoredAdsLocaleFieldCta', $$CTA$$),

  ('en', 'adminSponsoredAdsLocaleFieldSponsor', $$Sponsor$$),
  ('es', 'adminSponsoredAdsLocaleFieldSponsor', $$Patrocinador$$),
  ('he', 'adminSponsoredAdsLocaleFieldSponsor', $$נותן חסות$$),

  ('en', 'adminSponsoredAdsLocalesAdd', $$Add Locale$$),
  ('es', 'adminSponsoredAdsLocalesAdd', $$Agregar idioma$$),
  ('he', 'adminSponsoredAdsLocalesAdd', $$הוספת שפה$$),

  ('en', 'adminSponsoredAdsLocalesCode', $$Locale Code$$),
  ('es', 'adminSponsoredAdsLocalesCode', $$Código de idioma$$),
  ('he', 'adminSponsoredAdsLocalesCode', $$קוד שפה$$),

  ('en', 'adminSponsoredAdsLocalesHelp', $$Select a locale to add localized content.$$),
  ('es', 'adminSponsoredAdsLocalesHelp', $$Seleccione un idioma para agregar contenido localizado.$$),
  ('he', 'adminSponsoredAdsLocalesHelp', $$בחר שפה להוספת תוכן מותאם.$$),

  ('en', 'adminSponsoredAdsLocalesEmptyState', $$No locales added. Add one to provide localized ad content.$$),
  ('es', 'adminSponsoredAdsLocalesEmptyState', $$Sin idiomas agregados. Agregue uno para proporcionar contenido localizado.$$),
  ('he', 'adminSponsoredAdsLocalesEmptyState', $$לא נוספו שפות. הוסף שפה כדי לספק תוכן מודעה מותאם.$$),

  ('en', 'adminSponsoredAdsLocalesSearchHint', $$Search locales$$),
  ('es', 'adminSponsoredAdsLocalesSearchHint', $$Buscar idiomas$$),
  ('he', 'adminSponsoredAdsLocalesSearchHint', $$חיפוש שפות$$),

  ('en', 'adminSponsoredAdsLocalesSelected', $$Selected: {count}$$),
  ('es', 'adminSponsoredAdsLocalesSelected', $$Seleccionados: {count}$$),
  ('he', 'adminSponsoredAdsLocalesSelected', $$נבחרו: {count}$$),

  ('en', 'adminSponsoredAdsLocalesSectionHint', $$Select which locales to include.$$),
  ('es', 'adminSponsoredAdsLocalesSectionHint', $$Seleccione qué idiomas incluir.$$),
  ('he', 'adminSponsoredAdsLocalesSectionHint', $$בחר אילו שפות לכלול.$$),

  ('en', 'adminSponsoredAdsLocalesCompleted', $$Completed: {count}$$),
  ('es', 'adminSponsoredAdsLocalesCompleted', $$Completados: {count}$$),
  ('he', 'adminSponsoredAdsLocalesCompleted', $$הושלמו: {count}$$),

  ('en', 'adminSponsoredAdsLocalesMissing', $$Missing: {count}$$),
  ('es', 'adminSponsoredAdsLocalesMissing', $$Faltantes: {count}$$),
  ('he', 'adminSponsoredAdsLocalesMissing', $$חסרים: {count}$$),

  ('en', 'adminSponsoredAdsLocaleStatusComplete', $$Complete$$),
  ('es', 'adminSponsoredAdsLocaleStatusComplete', $$Completo$$),
  ('he', 'adminSponsoredAdsLocaleStatusComplete', $$הושלם$$),

  ('en', 'adminSponsoredAdsLocaleStatusMissing', $$Missing$$),
  ('es', 'adminSponsoredAdsLocaleStatusMissing', $$Faltante$$),
  ('he', 'adminSponsoredAdsLocaleStatusMissing', $$חסר$$),

  ('en', 'adminSponsoredAdsLeaveEmptyForNoLimit', $$Leave empty for no limit$$),
  ('es', 'adminSponsoredAdsLeaveEmptyForNoLimit', $$Dejar vacío para sin límite$$),
  ('he', 'adminSponsoredAdsLeaveEmptyForNoLimit', $$השאר ריק ללא הגבלה$$),

  -- Admin Promo Codes (new keys)
  ('en', 'adminPromoCodesTabAllCodes', $$All Codes$$),
  ('es', 'adminPromoCodesTabAllCodes', $$Todos los códigos$$),
  ('he', 'adminPromoCodesTabAllCodes', $$כל הקודים$$),

  ('en', 'adminPromoCodesTabAnalytics', $$Analytics$$),
  ('es', 'adminPromoCodesTabAnalytics', $$Analíticas$$),
  ('he', 'adminPromoCodesTabAnalytics', $$אנליטיקה$$),

  ('en', 'adminPromoCodesTabControls', $$Controls$$),
  ('es', 'adminPromoCodesTabControls', $$Controles$$),
  ('he', 'adminPromoCodesTabControls', $$בקרות$$),

  ('en', 'adminPromoCodesTabCreate', $$Create Code$$),
  ('es', 'adminPromoCodesTabCreate', $$Crear código$$),
  ('he', 'adminPromoCodesTabCreate', $$יצירת קוד$$),

  ('en', 'adminPromoCodesSectionCodeInfo', $$Code Information$$),
  ('es', 'adminPromoCodesSectionCodeInfo', $$Información del código$$),
  ('he', 'adminPromoCodesSectionCodeInfo', $$מידע על הקוד$$),

  ('en', 'adminPromoCodesSectionDiscountType', $$Discount Type$$),
  ('es', 'adminPromoCodesSectionDiscountType', $$Tipo de descuento$$),
  ('he', 'adminPromoCodesSectionDiscountType', $$סוג הנחה$$),

  ('en', 'adminPromoCodesSectionApplicableTiers', $$Applicable Tiers$$),
  ('es', 'adminPromoCodesSectionApplicableTiers', $$Niveles aplicables$$),
  ('he', 'adminPromoCodesSectionApplicableTiers', $$דרגות ישימות$$),

  ('en', 'adminPromoCodesSectionUsageLimits', $$Usage Limits$$),
  ('es', 'adminPromoCodesSectionUsageLimits', $$Límites de uso$$),
  ('he', 'adminPromoCodesSectionUsageLimits', $$מגבלות שימוש$$),

  ('en', 'adminPromoCodesSectionValidity', $$Validity Period$$),
  ('es', 'adminPromoCodesSectionValidity', $$Período de validez$$),
  ('he', 'adminPromoCodesSectionValidity', $$תקופת תוקף$$),

  ('en', 'adminPromoCodesFieldCode', $$Code$$),
  ('es', 'adminPromoCodesFieldCode', $$Código$$),
  ('he', 'adminPromoCodesFieldCode', $$קוד$$),

  ('en', 'adminPromoCodesFieldCodeHint', $$For example: SUMMER2024$$),
  ('es', 'adminPromoCodesFieldCodeHint', $$Por ejemplo: VERANO2024$$),
  ('he', 'adminPromoCodesFieldCodeHint', $$לדוגמה SUMMER2024$$),

  ('en', 'adminPromoCodesFieldDescription', $$Description$$),
  ('es', 'adminPromoCodesFieldDescription', $$Descripción$$),
  ('he', 'adminPromoCodesFieldDescription', $$תיאור$$),

  ('en', 'adminPromoCodesFieldDescriptionHint', $$Internal note about this code$$),
  ('es', 'adminPromoCodesFieldDescriptionHint', $$Nota interna sobre este código$$),
  ('he', 'adminPromoCodesFieldDescriptionHint', $$הערה פנימית על קוד זה$$),

  ('en', 'adminPromoCodesFieldDiscountPercentage', $$Discount Percentage$$),
  ('es', 'adminPromoCodesFieldDiscountPercentage', $$Porcentaje de descuento$$),
  ('he', 'adminPromoCodesFieldDiscountPercentage', $$אחוז הנחה$$),

  ('en', 'adminPromoCodesFieldDiscountPercentageHint', $$For example: 20 for 20%$$),
  ('es', 'adminPromoCodesFieldDiscountPercentageHint', $$Por ejemplo: 20 para 20%$$),
  ('he', 'adminPromoCodesFieldDiscountPercentageHint', $$לדוגמה 20 עבור 20%$$),

  ('en', 'adminPromoCodesFieldDiscountAmount', $$Discount Amount (cents)$$),
  ('es', 'adminPromoCodesFieldDiscountAmount', $$Monto de descuento (centavos)$$),
  ('he', 'adminPromoCodesFieldDiscountAmount', $$סכום הנחה (סנט)$$),

  ('en', 'adminPromoCodesFieldDiscountAmountHint', $$For example: 500 for $5.00$$),
  ('es', 'adminPromoCodesFieldDiscountAmountHint', $$Por ejemplo: 500 para $5.00$$),
  ('he', 'adminPromoCodesFieldDiscountAmountHint', $$לדוגמה 500 עבור $5.00$$),

  ('en', 'adminPromoCodesFieldFreeDays', $$Free Days$$),
  ('es', 'adminPromoCodesFieldFreeDays', $$Días gratis$$),
  ('he', 'adminPromoCodesFieldFreeDays', $$ימים בחינם$$),

  ('en', 'adminPromoCodesFieldFreeDaysHint', $$Number of free days$$),
  ('es', 'adminPromoCodesFieldFreeDaysHint', $$Número de días gratis$$),
  ('he', 'adminPromoCodesFieldFreeDaysHint', $$מספר ימים בחינם$$),

  ('en', 'adminPromoCodesFieldFreeDaysSuffix', $$days$$),
  ('es', 'adminPromoCodesFieldFreeDaysSuffix', $$días$$),
  ('he', 'adminPromoCodesFieldFreeDaysSuffix', $$ימים$$),

  ('en', 'adminPromoCodesFieldMaxUses', $$Maximum uses (total)$$),
  ('es', 'adminPromoCodesFieldMaxUses', $$Usos máximos (total)$$),
  ('he', 'adminPromoCodesFieldMaxUses', $$מקסימום שימושים (סה"כ)$$),

  ('en', 'adminPromoCodesFieldMaxUsesPerUser', $$Maximum uses per user$$),
  ('es', 'adminPromoCodesFieldMaxUsesPerUser', $$Usos máximos por usuario$$),
  ('he', 'adminPromoCodesFieldMaxUsesPerUser', $$מקסימום שימושים למשתמש$$),

  ('en', 'adminPromoCodesActionCreate', $$Create Code$$),
  ('es', 'adminPromoCodesActionCreate', $$Crear código$$),
  ('he', 'adminPromoCodesActionCreate', $$יצירת קוד$$),

  ('en', 'adminPromoCodesActionSaveChanges', $$Save Changes$$),
  ('es', 'adminPromoCodesActionSaveChanges', $$Guardar cambios$$),
  ('he', 'adminPromoCodesActionSaveChanges', $$שמירת שינויים$$),

  ('en', 'adminPromoCodesActionEnable', $$Enable$$),
  ('es', 'adminPromoCodesActionEnable', $$Habilitar$$),
  ('he', 'adminPromoCodesActionEnable', $$הפעל$$),

  ('en', 'adminPromoCodesActionDisable', $$Disable$$),
  ('es', 'adminPromoCodesActionDisable', $$Deshabilitar$$),
  ('he', 'adminPromoCodesActionDisable', $$השבת$$),

  ('en', 'adminPromoCodesCreateSuccess', $$Promo code created.$$),
  ('es', 'adminPromoCodesCreateSuccess', $$Código promocional creado.$$),
  ('he', 'adminPromoCodesCreateSuccess', $$קוד קופון נוצר.$$),

  ('en', 'adminPromoCodesUpdateSuccess', $$Promo code updated.$$),
  ('es', 'adminPromoCodesUpdateSuccess', $$Código promocional actualizado.$$),
  ('he', 'adminPromoCodesUpdateSuccess', $$קוד קופון עודכן.$$),

  ('en', 'adminPromoCodesDeleteSuccess', $$Promo code deleted.$$),
  ('es', 'adminPromoCodesDeleteSuccess', $$Código promocional eliminado.$$),
  ('he', 'adminPromoCodesDeleteSuccess', $$קוד קופון נמחק.$$),

  ('en', 'adminPromoCodesDeleteTitle', $$Delete Promo Code?$$),
  ('es', 'adminPromoCodesDeleteTitle', $$¿Eliminar código promocional?$$),
  ('he', 'adminPromoCodesDeleteTitle', $$למחוק קוד קופון?$$),

  ('en', 'adminPromoCodesStatusEnabled', $$Enabled$$),
  ('es', 'adminPromoCodesStatusEnabled', $$Habilitado$$),
  ('he', 'adminPromoCodesStatusEnabled', $$מופעל$$),

  ('en', 'adminPromoCodesStatusDisabled', $$Disabled$$),
  ('es', 'adminPromoCodesStatusDisabled', $$Deshabilitado$$),
  ('he', 'adminPromoCodesStatusDisabled', $$מושבת$$),

  ('en', 'adminPromoCodesStatusExpired', $$Expired$$),
  ('es', 'adminPromoCodesStatusExpired', $$Expirado$$),
  ('he', 'adminPromoCodesStatusExpired', $$פג תוקף$$),

  ('en', 'adminPromoCodesFilterAll', $$All$$),
  ('es', 'adminPromoCodesFilterAll', $$Todos$$),
  ('he', 'adminPromoCodesFilterAll', $$הכול$$),

  ('en', 'adminPromoCodesFilterEnabled', $$Enabled$$),
  ('es', 'adminPromoCodesFilterEnabled', $$Habilitados$$),
  ('he', 'adminPromoCodesFilterEnabled', $$מופעלים$$),

  ('en', 'adminPromoCodesFilterDisabled', $$Disabled$$),
  ('es', 'adminPromoCodesFilterDisabled', $$Deshabilitados$$),
  ('he', 'adminPromoCodesFilterDisabled', $$מושבתים$$),

  ('en', 'adminPromoCodesFilterExpired', $$Expired$$),
  ('es', 'adminPromoCodesFilterExpired', $$Expirados$$),
  ('he', 'adminPromoCodesFilterExpired', $$פגי תוקף$$),

  ('en', 'adminPromoCodesEmpty', $$No promo codes found.$$),
  ('es', 'adminPromoCodesEmpty', $$No se encontraron códigos promocionales.$$),
  ('he', 'adminPromoCodesEmpty', $$לא נמצאו קודי קופון.$$),

  ('en', 'adminPromoCodesEmptyFiltered', $$No codes match the filter.$$),
  ('es', 'adminPromoCodesEmptyFiltered', $$Ningún código coincide con el filtro.$$),
  ('he', 'adminPromoCodesEmptyFiltered', $$אין קודים התואמים את המסנן.$$),

  ('en', 'adminPromoCodesSearchLabel', $$Search codes$$),
  ('es', 'adminPromoCodesSearchLabel', $$Buscar códigos$$),
  ('he', 'adminPromoCodesSearchLabel', $$חיפוש קודים$$),

  ('en', 'adminPromoCodesSearchHint', $$Search by code or description$$),
  ('es', 'adminPromoCodesSearchHint', $$Buscar por código o descripción$$),
  ('he', 'adminPromoCodesSearchHint', $$חיפוש לפי קוד או תיאור$$),

  ('en', 'adminPromoCodesClearSearch', $$Clear$$),
  ('es', 'adminPromoCodesClearSearch', $$Borrar$$),
  ('he', 'adminPromoCodesClearSearch', $$נקה$$),

  ('en', 'adminPromoCodesInfoAllTiers', $$All tiers eligible$$),
  ('es', 'adminPromoCodesInfoAllTiers', $$Todos los niveles elegibles$$),
  ('he', 'adminPromoCodesInfoAllTiers', $$כל הדרגות זכאיות$$),

  ('en', 'adminPromoCodesInfoApplicableTiers', $$Applicable Tiers$$),
  ('es', 'adminPromoCodesInfoApplicableTiers', $$Niveles aplicables$$),
  ('he', 'adminPromoCodesInfoApplicableTiers', $$דרגות ישימות$$),

  ('en', 'adminPromoCodesInfoExpires', $$Expires$$),
  ('es', 'adminPromoCodesInfoExpires', $$Vence$$),
  ('he', 'adminPromoCodesInfoExpires', $$פג תוקף$$),

  ('en', 'adminPromoCodesInfoMaxUses', $$Maximum uses$$),
  ('es', 'adminPromoCodesInfoMaxUses', $$Usos máximos$$),
  ('he', 'adminPromoCodesInfoMaxUses', $$שימושים מקסימליים$$),

  ('en', 'adminPromoCodesInfoUsesPerUser', $$Per User$$),
  ('es', 'adminPromoCodesInfoUsesPerUser', $$Por usuario$$),
  ('he', 'adminPromoCodesInfoUsesPerUser', $$למשתמש$$),

  ('en', 'adminPromoCodesUsesUnlimited', $$Unlimited$$),
  ('es', 'adminPromoCodesUsesUnlimited', $$Ilimitado$$),
  ('he', 'adminPromoCodesUsesUnlimited', $$ללא הגבלה$$),

  ('en', 'adminPromoCodesExpiresDefault', $$No expiry$$),
  ('es', 'adminPromoCodesExpiresDefault', $$Sin vencimiento$$),
  ('he', 'adminPromoCodesExpiresDefault', $$ללא תאריך תפוגה$$),

  ('en', 'adminPromoCodesDateToday', $$Today$$),
  ('es', 'adminPromoCodesDateToday', $$Hoy$$),
  ('he', 'adminPromoCodesDateToday', $$היום$$),

  ('en', 'adminPromoCodesDateTomorrow', $$Tomorrow$$),
  ('es', 'adminPromoCodesDateTomorrow', $$Mañana$$),
  ('he', 'adminPromoCodesDateTomorrow', $$מחר$$),

  ('en', 'adminPromoCodesDateExpired', $$Expired$$),
  ('es', 'adminPromoCodesDateExpired', $$Expirado$$),
  ('he', 'adminPromoCodesDateExpired', $$פג תוקף$$),

  ('en', 'adminPromoCodesDateDays', $${count} days ago$$),
  ('es', 'adminPromoCodesDateDays', $${count} días atrás$$),
  ('he', 'adminPromoCodesDateDays', $$לפני {count} ימים$$),

  ('en', 'adminPromoCodesMenuViewStats', $$View Stats$$),
  ('es', 'adminPromoCodesMenuViewStats', $$Ver estadísticas$$),
  ('he', 'adminPromoCodesMenuViewStats', $$הצגת סטטיסטיקות$$),

  ('en', 'adminPromoCodesValidationCodeRequired', $$Code is required$$),
  ('es', 'adminPromoCodesValidationCodeRequired', $$El código es obligatorio$$),
  ('he', 'adminPromoCodesValidationCodeRequired', $$קוד הוא שדה חובה$$),

  ('en', 'adminPromoCodesOfflineCreateError', $$Cannot create code while offline.$$),
  ('es', 'adminPromoCodesOfflineCreateError', $$No se puede crear un código sin conexión.$$),
  ('he', 'adminPromoCodesOfflineCreateError', $$לא ניתן ליצור קוד במצב לא מקוון.$$),

  ('en', 'adminPromoCodesOfflineUpdateError', $$Cannot update code while offline.$$),
  ('es', 'adminPromoCodesOfflineUpdateError', $$No se puede actualizar un código sin conexión.$$),
  ('he', 'adminPromoCodesOfflineUpdateError', $$לא ניתן לעדכן קוד במצב לא מקוון.$$),

  ('en', 'adminPromoCodesOfflineDeleteError', $$Cannot delete code while offline.$$),
  ('es', 'adminPromoCodesOfflineDeleteError', $$No se puede eliminar un código sin conexión.$$),
  ('he', 'adminPromoCodesOfflineDeleteError', $$לא ניתן למחוק קוד במצב לא מקוון.$$),

  ('en', 'adminPromoCodesOfflineToggleError', $$Cannot toggle code while offline.$$),
  ('es', 'adminPromoCodesOfflineToggleError', $$No se puede cambiar el estado del código sin conexión.$$),
  ('he', 'adminPromoCodesOfflineToggleError', $$לא ניתן לשנות מצב קוד במצב לא מקוון.$$),

  ('en', 'adminPromoCodesOfflineSyncWarning', $$Changes will sync when online.$$),
  ('es', 'adminPromoCodesOfflineSyncWarning', $$Los cambios se sincronizarán al estar en línea.$$),
  ('he', 'adminPromoCodesOfflineSyncWarning', $$השינויים יסתנכרנו כשהחיבור יחזור.$$),

  ('en', 'adminPromoCodesToggleEnabledSuccess', $$Code enabled.$$),
  ('es', 'adminPromoCodesToggleEnabledSuccess', $$Código habilitado.$$),
  ('he', 'adminPromoCodesToggleEnabledSuccess', $$הקוד הופעל.$$),

  ('en', 'adminPromoCodesToggleDisabledSuccess', $$Code disabled.$$),
  ('es', 'adminPromoCodesToggleDisabledSuccess', $$Código deshabilitado.$$),
  ('he', 'adminPromoCodesToggleDisabledSuccess', $$הקוד הושבת.$$),

  ('en', 'adminPromoCodesAnalyticsTitle', $$Analytics Overview$$),
  ('es', 'adminPromoCodesAnalyticsTitle', $$Resumen de analíticas$$),
  ('he', 'adminPromoCodesAnalyticsTitle', $$סקירת נתונים$$),

  ('en', 'adminPromoCodesAnalyticsSubtitle', $$Overall promo code usage.$$),
  ('es', 'adminPromoCodesAnalyticsSubtitle', $$Uso general de códigos promocionales.$$),
  ('he', 'adminPromoCodesAnalyticsSubtitle', $$שימוש כללי בקודי קופון.$$),

  ('en', 'adminPromoCodesStatsTotalUses', $$Total Uses$$),
  ('es', 'adminPromoCodesStatsTotalUses', $$Usos totales$$),
  ('he', 'adminPromoCodesStatsTotalUses', $$סה"כ שימושים$$),

  ('en', 'adminPromoCodesStatsUniqueUsers', $$Unique Users$$),
  ('es', 'adminPromoCodesStatsUniqueUsers', $$Usuarios únicos$$),
  ('he', 'adminPromoCodesStatsUniqueUsers', $$משתמשים ייחודיים$$),

  ('en', 'adminPromoCodesStatsTotalDiscount', $$Total Discount$$),
  ('es', 'adminPromoCodesStatsTotalDiscount', $$Descuento total$$),
  ('he', 'adminPromoCodesStatsTotalDiscount', $$הנחה כוללת$$),

  ('en', 'adminPromoCodesStatsDialogTitle', $$Code Statistics$$),
  ('es', 'adminPromoCodesStatsDialogTitle', $$Estadísticas del código$$),
  ('he', 'adminPromoCodesStatsDialogTitle', $$סטטיסטיקות קוד$$),

  ('en', 'adminPromoCodesUserHistory', $$User History$$),
  ('es', 'adminPromoCodesUserHistory', $$Historial de usuario$$),
  ('he', 'adminPromoCodesUserHistory', $$היסטוריית משתמש$$),

  ('en', 'adminPromoCodesDrillDownTotalUses', $$Total Uses$$),
  ('es', 'adminPromoCodesDrillDownTotalUses', $$Usos totales$$),
  ('he', 'adminPromoCodesDrillDownTotalUses', $$סה"כ שימושים$$),

  ('en', 'adminPromoCodesDrillDownUniqueUsers', $$Unique Users$$),
  ('es', 'adminPromoCodesDrillDownUniqueUsers', $$Usuarios únicos$$),
  ('he', 'adminPromoCodesDrillDownUniqueUsers', $$משתמשים ייחודיים$$),

  ('en', 'adminPromoCodesDrillDownTotalDiscount', $$Total Discount$$),
  ('es', 'adminPromoCodesDrillDownTotalDiscount', $$Descuento total$$),
  ('he', 'adminPromoCodesDrillDownTotalDiscount', $$הנחה כוללת$$),

  ('en', 'adminPromoCodesTypeDiscountFixed', $$Fixed Amount$$),
  ('es', 'adminPromoCodesTypeDiscountFixed', $$Monto fijo$$),
  ('he', 'adminPromoCodesTypeDiscountFixed', $$סכום קבוע$$),

  ('en', 'adminPromoCodesTypeDiscountPercentage', $$Percentage$$),
  ('es', 'adminPromoCodesTypeDiscountPercentage', $$Porcentaje$$),
  ('he', 'adminPromoCodesTypeDiscountPercentage', $$אחוז$$),

  ('en', 'adminPromoCodesTypeFreeDays', $$Free Days$$),
  ('es', 'adminPromoCodesTypeFreeDays', $$Días gratis$$),
  ('he', 'adminPromoCodesTypeFreeDays', $$ימים בחינם$$),

  ('en', 'adminPromoCodesTypeTierUpgrade', $$Tier Upgrade$$),
  ('es', 'adminPromoCodesTypeTierUpgrade', $$Ascenso de nivel$$),
  ('he', 'adminPromoCodesTypeTierUpgrade', $$שדרוג דרגה$$),

  ('en', 'adminPromoCodesTierUpgradeHelp', $$User will be upgraded to the selected tier.$$),
  ('es', 'adminPromoCodesTierUpgradeHelp', $$El usuario será ascendido al nivel seleccionado.$$),
  ('he', 'adminPromoCodesTierUpgradeHelp', $$המשתמש ישודרג לדרגה שנבחרה.$$),

  ('en', 'adminPromoCodesTierPlus', $$Plus$$),
  ('es', 'adminPromoCodesTierPlus', $$Plus$$),
  ('he', 'adminPromoCodesTierPlus', $$Plus$$),

  ('en', 'adminPromoCodesTierGold', $$Gold$$),
  ('es', 'adminPromoCodesTierGold', $$Gold$$),
  ('he', 'adminPromoCodesTierGold', $$Gold$$),

  ('en', 'adminPromoCodesTierPlatinum', $$Platinum$$),
  ('es', 'adminPromoCodesTierPlatinum', $$Platinum$$),
  ('he', 'adminPromoCodesTierPlatinum', $$Platinum$$),

  ('en', 'adminPromoCodesBadgeTierUpgrade', $$Tier Upgrade$$),
  ('es', 'adminPromoCodesBadgeTierUpgrade', $$Ascenso de nivel$$),
  ('he', 'adminPromoCodesBadgeTierUpgrade', $$שדרוג דרגה$$),

  ('en', 'adminPromoCodesControlsTitle', $$Controls$$),
  ('es', 'adminPromoCodesControlsTitle', $$Controles$$),
  ('he', 'adminPromoCodesControlsTitle', $$בקרות$$),

  ('en', 'adminPromoCodesControlsSubtitle', $$Enable or disable the promo code system.$$),
  ('es', 'adminPromoCodesControlsSubtitle', $$Habilite o deshabilite el sistema de códigos promocionales.$$),
  ('he', 'adminPromoCodesControlsSubtitle', $$הפעל או השבת את מערכת קודי הקופון.$$),

  ('en', 'adminPromoCodesControlsEnabled', $$Promo codes enabled$$),
  ('es', 'adminPromoCodesControlsEnabled', $$Códigos promocionales habilitados$$),
  ('he', 'adminPromoCodesControlsEnabled', $$קודי קופון מופעלים$$),

  ('en', 'adminPromoCodesControlsEnabledSubtitle', $$Global toggle for promo code system.$$),
  ('es', 'adminPromoCodesControlsEnabledSubtitle', $$Interruptor global para el sistema de códigos.$$),
  ('he', 'adminPromoCodesControlsEnabledSubtitle', $$מתג גלובלי למערכת קודי הקופון.$$),

  ('en', 'adminPromoCodesConfigSaveSuccess', $$Configuration saved.$$),
  ('es', 'adminPromoCodesConfigSaveSuccess', $$Configuración guardada.$$),
  ('he', 'adminPromoCodesConfigSaveSuccess', $$התצורה נשמרה.$$),

  ('en', 'adminPromoCodesNoUsageFound', $$No usage data found.$$),
  ('es', 'adminPromoCodesNoUsageFound', $$No se encontraron datos de uso.$$),
  ('he', 'adminPromoCodesNoUsageFound', $$לא נמצאו נתוני שימוש.$$),

  -- General keys
  ('en', 'generalRetry', $$Retry$$),
  ('es', 'generalRetry', $$Reintentar$$),
  ('he', 'generalRetry', $$נסה שוב$$),

  ('en', 'generalEnabled', $$Enabled$$),
  ('es', 'generalEnabled', $$Habilitado$$),
  ('he', 'generalEnabled', $$מופעל$$),

  ('en', 'generalDisabled', $$Disabled$$),
  ('es', 'generalDisabled', $$Deshabilitado$$),
  ('he', 'generalDisabled', $$מושבת$$),

  ('en', 'generalUpdate', $$Update$$),
  ('es', 'generalUpdate', $$Actualizar$$),
  ('he', 'generalUpdate', $$עדכון$$),

  -- Tier names used in promoCodes
  ('en', 'tierPlus', $$Plus$$),
  ('es', 'tierPlus', $$Plus$$),
  ('he', 'tierPlus', $$Plus$$),

  ('en', 'tierGold', $$Gold$$),
  ('es', 'tierGold', $$Gold$$),
  ('he', 'tierGold', $$Gold$$),

  ('en', 'tierPlatinum', $$Platinum$$),
  ('es', 'tierPlatinum', $$Platinum$$),
  ('he', 'tierPlatinum', $$Platinum$$)

ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
