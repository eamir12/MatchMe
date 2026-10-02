-- Seed Admin app UI translations (en/es/he). Safe to re-run.

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminAppTitle', $$MatchMe Admin$$),
  ('es', 'adminAppTitle', $$MatchMe Admin$$),
  ('he', 'adminAppTitle', $$ניהול MatchMe$$),

  ('en', 'adminLoginTitle', $$Admin Login$$),
  ('es', 'adminLoginTitle', $$Inicio de sesión de administrador$$),
  ('he', 'adminLoginTitle', $$התחברות מנהל$$),

  ('en', 'adminNotAuthorized', $$You do not have access to this app.$$),
  ('es', 'adminNotAuthorized', $$No tienes acceso a esta aplicación.$$),
  ('he', 'adminNotAuthorized', $$אין לך הרשאה לגשת לאפליקציה זו.$$),

  ('en', 'adminAuthCheckFailed', $$Failed to verify admin access.$$),
  ('es', 'adminAuthCheckFailed', $$No se pudo verificar el acceso de administrador.$$),
  ('he', 'adminAuthCheckFailed', $$אימות הרשאת מנהל נכשל.$$),

  ('en', 'authStreamError', $$Auth Stream Error$$),
  ('es', 'authStreamError', $$Error de autenticación$$),
  ('he', 'authStreamError', $$שגיאת אימות$$),

  ('en', 'supabaseConfigMissing', $$Supabase configuration missing$$),
  ('es', 'supabaseConfigMissing', $$Falta la configuración de Supabase$$),
  ('he', 'supabaseConfigMissing', $$חסרה תצורת Supabase$$),

  ('en', 'generalLoading', $$Loading…$$),
  ('es', 'generalLoading', $$Cargando…$$),
  ('he', 'generalLoading', $$טוען…$$),

  ('en', 'authEmail', $$Email$$),
  ('es', 'authEmail', $$Correo electrónico$$),
  ('he', 'authEmail', $$אימייל$$),

  ('en', 'authEmailRequired', $$Email is required$$),
  ('es', 'authEmailRequired', $$El correo es obligatorio$$),
  ('he', 'authEmailRequired', $$אימייל הוא שדה חובה$$),

  ('en', 'authPassword', $$Password$$),
  ('es', 'authPassword', $$Contraseña$$),
  ('he', 'authPassword', $$סיסמה$$),

  ('en', 'authPasswordRequired', $$Password is required$$),
  ('es', 'authPasswordRequired', $$La contraseña es obligatoria$$),
  ('he', 'authPasswordRequired', $$סיסמה היא שדה חובה$$),

  ('en', 'authLogin', $$Log In$$),
  ('es', 'authLogin', $$Iniciar sesión$$),
  ('he', 'authLogin', $$התחברות$$),

  ('en', 'authLoginFailed', $$Login failed. Please try again.$$),
  ('es', 'authLoginFailed', $$No se pudo iniciar sesión. Inténtalo de nuevo.$$),
  ('he', 'authLoginFailed', $$ההתחברות נכשלה. נסו שוב.$$),

  ('en', 'authSignOut', $$Sign Out$$),
  ('es', 'authSignOut', $$Cerrar sesión$$),
  ('he', 'authSignOut', $$התנתקות$$),

  ('en', 'adminChangeLanguage', $$Change language$$),
  ('es', 'adminChangeLanguage', $$Cambiar idioma$$),
  ('he', 'adminChangeLanguage', $$שינוי שפה$$),

  ('en', 'languageShort_en', $$EN$$),
  ('es', 'languageShort_en', $$EN$$),
  ('he', 'languageShort_en', $$EN$$),

  ('en', 'languageShort_es', $$ES$$),
  ('es', 'languageShort_es', $$ES$$),
  ('he', 'languageShort_es', $$ES$$),

  ('en', 'languageShort_he', $$HE$$),
  ('es', 'languageShort_he', $$HE$$),
  ('he', 'languageShort_he', $$HE$$),

  ('en', 'generalSave', $$Save$$),
  ('es', 'generalSave', $$Guardar$$),
  ('he', 'generalSave', $$שמירה$$),

  ('en', 'generalCancel', $$Cancel$$),
  ('es', 'generalCancel', $$Cancelar$$),
  ('he', 'generalCancel', $$ביטול$$),

  ('en', 'generalDelete', $$Delete$$),
  ('es', 'generalDelete', $$Eliminar$$),
  ('he', 'generalDelete', $$מחיקה$$),

  ('en', 'generalEdit', $$Edit$$),
  ('es', 'generalEdit', $$Editar$$),
  ('he', 'generalEdit', $$עריכה$$),

  ('en', 'generalRefresh', $$Refresh$$),
  ('es', 'generalRefresh', $$Actualizar$$),
  ('he', 'generalRefresh', $$רענון$$),

  ('en', 'adminNavDashboard', $$Dashboard$$),
  ('es', 'adminNavDashboard', $$Panel$$),
  ('he', 'adminNavDashboard', $$לוח מחוונים$$),

  ('en', 'adminNavAppConfig', $$App Config$$),
  ('es', 'adminNavAppConfig', $$Configuración de la app$$),
  ('he', 'adminNavAppConfig', $$תצורת אפליקציה$$),

  ('en', 'adminNavTranslations', $$Translations$$),
  ('es', 'adminNavTranslations', $$Traducciones$$),
  ('he', 'adminNavTranslations', $$תרגומים$$),

  ('en', 'adminNavSubscriptions', $$Subscriptions$$),
  ('es', 'adminNavSubscriptions', $$Suscripciones$$),
  ('he', 'adminNavSubscriptions', $$מינויים$$),

  ('en', 'adminNavBroadcasts', $$Broadcasts$$),
  ('es', 'adminNavBroadcasts', $$Difusiones$$),
  ('he', 'adminNavBroadcasts', $$שידורים$$),

  ('en', 'adminNavIntentsInterests', $$Intents & Interests$$),
  ('es', 'adminNavIntentsInterests', $$Intenciones e intereses$$),
  ('he', 'adminNavIntentsInterests', $$כוונות ותחומי עניין$$),

  ('en', 'adminNavVerification', $$User Verification$$),
  ('es', 'adminNavVerification', $$Verificación de usuarios$$),
  ('he', 'adminNavVerification', $$אימות משתמשים$$),

  ('en', 'adminNavProfileEdits', $$Profile Edit Requests$$),
  ('es', 'adminNavProfileEdits', $$Solicitudes de edición de perfil$$),
  ('he', 'adminNavProfileEdits', $$בקשות עריכת פרופיל$$),

  ('en', 'adminDashboardLoadFailed', $$Failed to load dashboard.$$),
  ('es', 'adminDashboardLoadFailed', $$No se pudo cargar el panel.$$),
  ('he', 'adminDashboardLoadFailed', $$טעינת לוח המחוונים נכשלה.$$),

  ('en', 'adminDashboardWindow24h', $$Last 24 hours$$),
  ('es', 'adminDashboardWindow24h', $$Últimas 24 horas$$),
  ('he', 'adminDashboardWindow24h', $$24 שעות אחרונות$$),

  ('en', 'adminDashboardWindow7d', $$Last 7 days$$),
  ('es', 'adminDashboardWindow7d', $$Últimos 7 días$$),
  ('he', 'adminDashboardWindow7d', $$7 ימים אחרונים$$),

  ('en', 'adminDashboardLastUpdated', $$Last updated: {time}$$),
  ('es', 'adminDashboardLastUpdated', $$Última actualización: {time}$$),
  ('he', 'adminDashboardLastUpdated', $$עודכן לאחרונה: {time}$$),

  ('en', 'adminDashboardEngagement', $$Engagement$$),
  ('es', 'adminDashboardEngagement', $$Participación$$),
  ('he', 'adminDashboardEngagement', $$מעורבות$$),

  ('en', 'adminDashboardOperations', $$Operations$$),
  ('es', 'adminDashboardOperations', $$Operaciones$$),
  ('he', 'adminDashboardOperations', $$תפעול$$),

  ('en', 'adminDashboardRevenue', $$Revenue$$),
  ('es', 'adminDashboardRevenue', $$Ingresos$$),
  ('he', 'adminDashboardRevenue', $$הכנסות$$),

  ('en', 'adminDashboardSafety', $$Safety$$),
  ('es', 'adminDashboardSafety', $$Seguridad$$),
  ('he', 'adminDashboardSafety', $$בטיחות$$),

  ('en', 'adminDashboardAI', $$AI$$),
  ('es', 'adminDashboardAI', $$IA$$),
  ('he', 'adminDashboardAI', $$בינה מלאכותית$$),

  ('en', 'adminDashboardAIUsageTitle', $$AI usage$$),
  ('es', 'adminDashboardAIUsageTitle', $$Uso de IA$$),
  ('he', 'adminDashboardAIUsageTitle', $$שימוש בבינה מלאכותית$$),

  ('en', 'adminDashboardAIUsageEmpty', $$No AI calls in this window.$$),
  ('es', 'adminDashboardAIUsageEmpty', $$No hay llamadas a IA en esta ventana.$$),
  ('he', 'adminDashboardAIUsageEmpty', $$אין קריאות לבינה מלאכותית בחלון זה.$$),

  ('en', 'adminDashboardAIProvider', $$Provider$$),
  ('es', 'adminDashboardAIProvider', $$Proveedor$$),
  ('he', 'adminDashboardAIProvider', $$ספק$$),

  ('en', 'adminDashboardAIModel', $$Model$$),
  ('es', 'adminDashboardAIModel', $$Modelo$$),
  ('he', 'adminDashboardAIModel', $$דגם$$),

  ('en', 'adminDashboardAITask', $$Task$$),
  ('es', 'adminDashboardAITask', $$Tarea$$),
  ('he', 'adminDashboardAITask', $$משימה$$),

  ('en', 'adminDashboardAICalls', $$Calls$$),
  ('es', 'adminDashboardAICalls', $$Llamadas$$),
  ('he', 'adminDashboardAICalls', $$קריאות$$),

  ('en', 'adminDashboardAIFailures', $$Failures$$),
  ('es', 'adminDashboardAIFailures', $$Fallos$$),
  ('he', 'adminDashboardAIFailures', $$כישלונות$$),

  ('en', 'adminDashboardAIRecentErrorsTitle', $$AI errors (recent)$$),
  ('es', 'adminDashboardAIRecentErrorsTitle', $$Errores de IA (recientes)$$),
  ('he', 'adminDashboardAIRecentErrorsTitle', $$שגיאות בינה מלאכותית (אחרונות)$$),

  ('en', 'adminDashboardEdgeFunctions', $$Edge Functions$$),
  ('es', 'adminDashboardEdgeFunctions', $$Funciones Edge$$),
  ('he', 'adminDashboardEdgeFunctions', $$פונקציות Edge$$),

  ('en', 'adminDashboardEdgeFunctionsUsageTitle', $$Edge Function usage$$),
  ('es', 'adminDashboardEdgeFunctionsUsageTitle', $$Uso de funciones Edge$$),
  ('he', 'adminDashboardEdgeFunctionsUsageTitle', $$שימוש בפונקציות Edge$$),

  ('en', 'adminDashboardEdgeFunctionsUsageEmpty', $$No Edge Function calls in this window.$$),
  ('es', 'adminDashboardEdgeFunctionsUsageEmpty', $$No hay llamadas a funciones Edge en esta ventana.$$),
  ('he', 'adminDashboardEdgeFunctionsUsageEmpty', $$אין קריאות לפונקציות Edge בחלון זה.$$),

  ('en', 'adminDashboardEdgeFunctionName', $$Function$$),
  ('es', 'adminDashboardEdgeFunctionName', $$Función$$),
  ('he', 'adminDashboardEdgeFunctionName', $$פונקציה$$),

  ('en', 'adminDashboardEdgeFunctionCalls', $$Calls$$),
  ('es', 'adminDashboardEdgeFunctionCalls', $$Llamadas$$),
  ('he', 'adminDashboardEdgeFunctionCalls', $$קריאות$$),

  ('en', 'adminDashboardEdgeFunctionFailures', $$Failures$$),
  ('es', 'adminDashboardEdgeFunctionFailures', $$Fallos$$),
  ('he', 'adminDashboardEdgeFunctionFailures', $$כישלונות$$),

  ('en', 'adminDashboardEdgeFunctionLastErrorAt', $$Last error$$),
  ('es', 'adminDashboardEdgeFunctionLastErrorAt', $$Último error$$),
  ('he', 'adminDashboardEdgeFunctionLastErrorAt', $$שגיאה אחרונה$$),

  ('en', 'adminDashboardEdgeFunctionsRecentErrorsTitle', $$Edge Function errors (recent)$$),
  ('es', 'adminDashboardEdgeFunctionsRecentErrorsTitle', $$Errores de funciones Edge (recientes)$$),
  ('he', 'adminDashboardEdgeFunctionsRecentErrorsTitle', $$שגיאות פונקציות Edge (אחרונות)$$),

  ('en', 'adminDashboardNoRecentErrors', $$No errors in this window.$$),
  ('es', 'adminDashboardNoRecentErrors', $$No hay errores en esta ventana.$$),
  ('he', 'adminDashboardNoRecentErrors', $$אין שגיאות בחלון זה.$$),

  ('en', 'adminDrilldownLoadFailed', $$Failed to load details.$$),
  ('es', 'adminDrilldownLoadFailed', $$No se pudieron cargar los detalles.$$),
  ('he', 'adminDrilldownLoadFailed', $$טעינת הפרטים נכשלה.$$),

  ('en', 'adminDrilldownEmpty', $$No results.$$),
  ('es', 'adminDrilldownEmpty', $$Sin resultados.$$),
  ('he', 'adminDrilldownEmpty', $$אין תוצאות.$$),

  ('en', 'adminDrilldownUser', $$User$$),
  ('es', 'adminDrilldownUser', $$Usuario$$),
  ('he', 'adminDrilldownUser', $$משתמש$$),

  ('en', 'adminDrilldownUserA', $$User A$$),
  ('es', 'adminDrilldownUserA', $$Usuario A$$),
  ('he', 'adminDrilldownUserA', $$משתמש א׳$$),

  ('en', 'adminDrilldownUserB', $$User B$$),
  ('es', 'adminDrilldownUserB', $$Usuario B$$),
  ('he', 'adminDrilldownUserB', $$משתמש ב׳$$),

  ('en', 'adminDrilldownUserId', $$User ID$$),
  ('es', 'adminDrilldownUserId', $$ID de usuario$$),
  ('he', 'adminDrilldownUserId', $$מזהה משתמש$$),

  ('en', 'adminDrilldownCreatedAt', $$Created$$),
  ('es', 'adminDrilldownCreatedAt', $$Creado$$),
  ('he', 'adminDrilldownCreatedAt', $$נוצר$$),

  ('en', 'adminDrilldownLastActivity', $$Last activity$$),
  ('es', 'adminDrilldownLastActivity', $$Última actividad$$),
  ('he', 'adminDrilldownLastActivity', $$פעילות אחרונה$$),

  ('en', 'adminDrilldownMessages', $$Messages$$),
  ('es', 'adminDrilldownMessages', $$Mensajes$$),
  ('he', 'adminDrilldownMessages', $$הודעות$$),

  ('en', 'adminDrilldownMatchedAt', $$Matched$$),
  ('es', 'adminDrilldownMatchedAt', $$Emparejado$$),
  ('he', 'adminDrilldownMatchedAt', $$הותאם$$),

  ('en', 'adminDrilldownMatchType', $$Basis$$),
  ('es', 'adminDrilldownMatchType', $$Base$$),
  ('he', 'adminDrilldownMatchType', $$בסיס$$),

  ('en', 'adminDrilldownBasis', $$Basis$$),
  ('es', 'adminDrilldownBasis', $$Base$$),
  ('he', 'adminDrilldownBasis', $$בסיס$$),

  ('en', 'adminDrilldownBasisProximity', $$Proximity$$),
  ('es', 'adminDrilldownBasisProximity', $$Proximidad$$),
  ('he', 'adminDrilldownBasisProximity', $$קרבה$$),

  ('en', 'adminDrilldownBasisEvent', $$Event$$),
  ('es', 'adminDrilldownBasisEvent', $$Evento$$),
  ('he', 'adminDrilldownBasisEvent', $$אירוע$$),

  ('en', 'adminDrilldownBasisSharedIntent', $$Shared intent$$),
  ('es', 'adminDrilldownBasisSharedIntent', $$Intención compartida$$),
  ('he', 'adminDrilldownBasisSharedIntent', $$כוונה משותפת$$),

  ('en', 'adminDrilldownBasisSharedInterest', $$Shared interest$$),
  ('es', 'adminDrilldownBasisSharedInterest', $$Interés compartido$$),
  ('he', 'adminDrilldownBasisSharedInterest', $$עניין משותף$$),

  ('en', 'adminDrilldownUnknown', $$Unknown$$),
  ('es', 'adminDrilldownUnknown', $$Desconocido$$),
  ('he', 'adminDrilldownUnknown', $$לא ידוע$$),

  ('en', 'adminDrilldownSharedIntent', $$Shared intent$$),
  ('es', 'adminDrilldownSharedIntent', $$Intención compartida$$),
  ('he', 'adminDrilldownSharedIntent', $$כוונה משותפת$$),

  ('en', 'adminDrilldownSharedInterest', $$Shared interest$$),
  ('es', 'adminDrilldownSharedInterest', $$Interés compartido$$),
  ('he', 'adminDrilldownSharedInterest', $$עניין משותף$$),

  ('en', 'adminDrilldownEvent', $$Event$$),
  ('es', 'adminDrilldownEvent', $$Evento$$),
  ('he', 'adminDrilldownEvent', $$אירוע$$),

  ('en', 'adminDrilldownSubmittedAt', $$Submitted$$),
  ('es', 'adminDrilldownSubmittedAt', $$Enviado$$),
  ('he', 'adminDrilldownSubmittedAt', $$נשלח$$),

  ('en', 'adminDrilldownStatus', $$Status$$),
  ('es', 'adminDrilldownStatus', $$Estado$$),
  ('he', 'adminDrilldownStatus', $$סטטוס$$),

  ('en', 'adminDrilldownTitle', $$Title$$),
  ('es', 'adminDrilldownTitle', $$Título$$),
  ('he', 'adminDrilldownTitle', $$כותרת$$),

  ('en', 'adminDrilldownScheduledAt', $$Scheduled$$),
  ('es', 'adminDrilldownScheduledAt', $$Programado$$),
  ('he', 'adminDrilldownScheduledAt', $$מתוזמן$$),

  ('en', 'adminDrilldownAttempts', $$Attempts$$),
  ('es', 'adminDrilldownAttempts', $$Intentos$$),
  ('he', 'adminDrilldownAttempts', $$ניסיונות$$),

  ('en', 'adminDrilldownFailureReason', $$Failure reason$$),
  ('es', 'adminDrilldownFailureReason', $$Motivo del fallo$$),
  ('he', 'adminDrilldownFailureReason', $$סיבת כישלון$$),

  ('en', 'adminDrilldownSubscriptionTier', $$Tier$$),
  ('es', 'adminDrilldownSubscriptionTier', $$Nivel$$),
  ('he', 'adminDrilldownSubscriptionTier', $$רמה$$),

  ('en', 'adminDrilldownExpiresAt', $$Expires$$),
  ('es', 'adminDrilldownExpiresAt', $$Expira$$),
  ('he', 'adminDrilldownExpiresAt', $$פג תוקף$$),

  ('en', 'adminDrilldownInvokedAt', $$Invoked$$),
  ('es', 'adminDrilldownInvokedAt', $$Invocado$$),
  ('he', 'adminDrilldownInvokedAt', $$הופעל$$),

  ('en', 'adminDrilldownFunction', $$Function$$),
  ('es', 'adminDrilldownFunction', $$Función$$),
  ('he', 'adminDrilldownFunction', $$פונקציה$$),

  ('en', 'adminDrilldownSuccess', $$Success$$),
  ('es', 'adminDrilldownSuccess', $$Éxito$$),
  ('he', 'adminDrilldownSuccess', $$הצלחה$$),

  ('en', 'adminDrilldownDurationMs', $$Duration (milliseconds)$$),
  ('es', 'adminDrilldownDurationMs', $$Duración (milisegundos)$$),
  ('he', 'adminDrilldownDurationMs', $$משך (מילישניות)$$),

  ('en', 'adminDrilldownHttpStatus', $$HTTP$$),
  ('es', 'adminDrilldownHttpStatus', $$HTTP$$),
  ('he', 'adminDrilldownHttpStatus', $$HTTP$$),

  ('en', 'adminDrilldownErrorType', $$Error type$$),
  ('es', 'adminDrilldownErrorType', $$Tipo de error$$),
  ('he', 'adminDrilldownErrorType', $$סוג שגיאה$$),

  ('en', 'adminDrilldownErrorMessage', $$Error message$$),
  ('es', 'adminDrilldownErrorMessage', $$Mensaje de error$$),
  ('he', 'adminDrilldownErrorMessage', $$הודעת שגיאה$$),

  ('en', 'adminDrilldownAIUsed', $$AI used$$),
  ('es', 'adminDrilldownAIUsed', $$IA usada$$),
  ('he', 'adminDrilldownAIUsed', $$שימוש ב-AI$$),

  ('en', 'adminDrilldownProvider', $$Provider$$),
  ('es', 'adminDrilldownProvider', $$Proveedor$$),
  ('he', 'adminDrilldownProvider', $$ספק$$),

  ('en', 'adminDrilldownModel', $$Model$$),
  ('es', 'adminDrilldownModel', $$Modelo$$),
  ('he', 'adminDrilldownModel', $$מודל$$),

  ('en', 'adminDrilldownTask', $$Task$$),
  ('es', 'adminDrilldownTask', $$Tarea$$),
  ('he', 'adminDrilldownTask', $$משימה$$),

  ('en', 'adminDashboardSeriesCaption', $$Trends ({window})$$),
  ('es', 'adminDashboardSeriesCaption', $$Tendencias ({window})$$),
  ('he', 'adminDashboardSeriesCaption', $$מגמות ({window})$$),

  ('en', 'adminDashboardSeriesBucketsHourly', $$24 bars (hourly)$$),
  ('es', 'adminDashboardSeriesBucketsHourly', $$24 barras (por hora)$$),
  ('he', 'adminDashboardSeriesBucketsHourly', $$24 עמודות (לפי שעה)$$),

  ('en', 'adminDashboardSeriesBucketsDaily', $$7 bars (daily)$$),
  ('es', 'adminDashboardSeriesBucketsDaily', $$7 barras (por día)$$),
  ('he', 'adminDashboardSeriesBucketsDaily', $$7 עמודות (לפי יום)$$),

  ('en', 'adminDashboardBucketHour', $$hour$$),
  ('es', 'adminDashboardBucketHour', $$hora$$),
  ('he', 'adminDashboardBucketHour', $$שעה$$),

  ('en', 'adminDashboardBucketDay', $$day$$),
  ('es', 'adminDashboardBucketDay', $$día$$),
  ('he', 'adminDashboardBucketDay', $$יום$$),

  ('en', 'adminDashboardSeriesExplanation', $$Each bar is the total for one {bucket}. Rightmost is newest.$$),
  ('es', 'adminDashboardSeriesExplanation', $$Cada barra es el total de un(a) {bucket}. La barra más a la derecha es la más reciente.$$),
  ('he', 'adminDashboardSeriesExplanation', $$כל עמודה היא סך הכול עבור {bucket} אחד. העמודה הימנית היא העדכנית ביותר.$$),

  ('en', 'adminDashboardSeriesOldest', $$Older$$),
  ('es', 'adminDashboardSeriesOldest', $$Anterior$$),
  ('he', 'adminDashboardSeriesOldest', $$ישן יותר$$),

  ('en', 'adminDashboardSeriesNewest', $$Newer$$),
  ('es', 'adminDashboardSeriesNewest', $$Más reciente$$),
  ('he', 'adminDashboardSeriesNewest', $$עדכני יותר$$),

  ('en', 'adminDashboardSeriesTooltip', $${label}: {value} ({range})$$),
  ('es', 'adminDashboardSeriesTooltip', $${label}: {value} ({range})$$),
  ('he', 'adminDashboardSeriesTooltip', $${label}: {value} ({range})$$),

  ('en', 'adminDashboardSeriesScrollHint', $$Tip: swipe horizontally on charts to see all bars.$$),
  ('es', 'adminDashboardSeriesScrollHint', $$Consejo: desliza horizontalmente en los gráficos para ver todas las barras.$$),
  ('he', 'adminDashboardSeriesScrollHint', $$טיפ: החליקו אופקית על הגרפים כדי לראות את כל העמודות.$$),

  ('en', 'adminDashboardOnlineUsers', $$Online users$$),
  ('es', 'adminDashboardOnlineUsers', $$Usuarios en línea$$),
  ('he', 'adminDashboardOnlineUsers', $$משתמשים מחוברים$$),

  ('en', 'adminDashboardVisibleUsers', $$Visible users$$),
  ('es', 'adminDashboardVisibleUsers', $$Usuarios visibles$$),
  ('he', 'adminDashboardVisibleUsers', $$משתמשים גלויים$$),

  ('en', 'adminDashboardNearbyUsers', $$Nearby users (10 kilometers)$$),
  ('es', 'adminDashboardNearbyUsers', $$Usuarios cercanos (10 kilómetros)$$),
  ('he', 'adminDashboardNearbyUsers', $$משתמשים בקרבת מקום (10 קילומטרים)$$),

  ('en', 'adminDashboardMatchesCreated', $$Matches created$$),
  ('es', 'adminDashboardMatchesCreated', $$Coincidencias creadas$$),
  ('he', 'adminDashboardMatchesCreated', $$התאמות שנוצרו$$),

  ('en', 'adminDashboardMessagesSent', $$Messages sent$$),
  ('es', 'adminDashboardMessagesSent', $$Mensajes enviados$$),
  ('he', 'adminDashboardMessagesSent', $$הודעות שנשלחו$$),

  ('en', 'adminDashboardNewUsers', $$New users$$),
  ('es', 'adminDashboardNewUsers', $$Nuevos usuarios$$),
  ('he', 'adminDashboardNewUsers', $$משתמשים חדשים$$),

  ('en', 'adminDashboardActiveMatches', $$Active matches$$),
  ('es', 'adminDashboardActiveMatches', $$Coincidencias activas$$),
  ('he', 'adminDashboardActiveMatches', $$התאמות פעילות$$),

  ('en', 'adminDashboardVerificationPending', $$Verification pending$$),
  ('es', 'adminDashboardVerificationPending', $$Verificación pendiente$$),
  ('he', 'adminDashboardVerificationPending', $$אימות בהמתנה$$),

  ('en', 'adminDashboardVerificationAnalyzing', $$Verification analyzing$$),
  ('es', 'adminDashboardVerificationAnalyzing', $$Verificación en análisis$$),
  ('he', 'adminDashboardVerificationAnalyzing', $$אימות בניתוח$$),

  ('en', 'adminDashboardProfileEditsPending', $$Profile edits pending$$),
  ('es', 'adminDashboardProfileEditsPending', $$Ediciones de perfil pendientes$$),
  ('he', 'adminDashboardProfileEditsPending', $$עריכות פרופיל בהמתנה$$),

  ('en', 'adminDashboardBroadcastsDraft', $$Broadcasts (draft)$$),
  ('es', 'adminDashboardBroadcastsDraft', $$Difusiones (borrador)$$),
  ('he', 'adminDashboardBroadcastsDraft', $$שידורים (טיוטה)$$),

  ('en', 'adminDashboardBroadcastsScheduled', $$Broadcasts (scheduled)$$),
  ('es', 'adminDashboardBroadcastsScheduled', $$Difusiones (programadas)$$),
  ('he', 'adminDashboardBroadcastsScheduled', $$שידורים (מתוזמנים)$$),

  ('en', 'adminDashboardNotificationsPending', $$Notifications (pending)$$),
  ('es', 'adminDashboardNotificationsPending', $$Notificaciones (pendientes)$$),
  ('he', 'adminDashboardNotificationsPending', $$התראות (בהמתנה)$$),

  ('en', 'adminDashboardNotificationsFailed', $$Notifications (failed)$$),
  ('es', 'adminDashboardNotificationsFailed', $$Notificaciones (fallidas)$$),
  ('he', 'adminDashboardNotificationsFailed', $$התראות (נכשלו)$$),

  ('en', 'adminDashboardPaidActiveUsers', $$Paid active users$$),
  ('es', 'adminDashboardPaidActiveUsers', $$Usuarios de pago activos$$),
  ('he', 'adminDashboardPaidActiveUsers', $$משתמשים בתשלום פעילים$$),

  ('en', 'adminDashboardPaidExpiring7d', $$Paid expiring (7 days)$$),
  ('es', 'adminDashboardPaidExpiring7d', $$Pagos que vencen (7 días)$$),
  ('he', 'adminDashboardPaidExpiring7d', $$מנויים בתשלום שפגים (7 ימים)$$),

  ('en', 'adminDashboardPaidByTier', $$Paid by tier$$),
  ('es', 'adminDashboardPaidByTier', $$De pago por nivel$$),
  ('he', 'adminDashboardPaidByTier', $$בתשלום לפי דרגה$$),
  ('en', 'adminDashboardEarnings', $$Earnings$$),
  ('es', 'adminDashboardEarnings', $$Ganancias$$),
  ('he', 'adminDashboardEarnings', $$רווחים$$),

  ('en', 'adminDashboardNoSafetyData', $$Safety signals are not available yet.$$),
  ('es', 'adminDashboardNoSafetyData', $$Las señales de seguridad aún no están disponibles.$$),
  ('he', 'adminDashboardNoSafetyData', $$אותות בטיחות עדיין לא זמינים.$$),

  ('en', 'adminDashboardSafetyAvailable', $$Safety signals are available.$$),
  ('es', 'adminDashboardSafetyAvailable', $$Las señales de seguridad están disponibles.$$),
  ('he', 'adminDashboardSafetyAvailable', $$אותות בטיחות זמינים.$$),

  ('en', 'adminPlaceholderAppConfig', $$Manage app_config values.$$),
  ('es', 'adminPlaceholderAppConfig', $$Gestiona los valores de app_config.$$),
  ('he', 'adminPlaceholderAppConfig', $$ניהול ערכי app_config.$$),

  ('en', 'adminPlaceholderTranslations', $$Manage translations (en / es / he).$$),
  ('es', 'adminPlaceholderTranslations', $$Gestiona traducciones (en / es / he).$$),
  ('he', 'adminPlaceholderTranslations', $$ניהול תרגומים (en / es / he).$$),

  ('en', 'adminPlaceholderSubscriptions', $$Manage subscription tiers and plans.$$),
  ('es', 'adminPlaceholderSubscriptions', $$Gestiona niveles y planes de suscripción.$$),
  ('he', 'adminPlaceholderSubscriptions', $$ניהול דרגות ותכניות מנוי.$$),

  ('en', 'adminPlaceholderBroadcasts', $$Create and schedule admin broadcasts.$$),
  ('es', 'adminPlaceholderBroadcasts', $$Crea y programa difusiones de administrador.$$),
  ('he', 'adminPlaceholderBroadcasts', $$יצירה ותזמון שידורי מנהל.$$),

  ('en', 'adminPlaceholderIntentsInterests', $$Manage intents, subintents, interests, and subinterests.$$),
  ('es', 'adminPlaceholderIntentsInterests', $$Gestiona intenciones, subintenciones, intereses y subintereses.$$),
  ('he', 'adminPlaceholderIntentsInterests', $$ניהול כוונות, תת־כוונות, תחומי עניין ותת־תחומי עניין.$$),

  ('en', 'adminPlaceholderVerification', $$Review and update user verification status.$$),
  ('es', 'adminPlaceholderVerification', $$Revisa y actualiza el estado de verificación del usuario.$$),
  ('he', 'adminPlaceholderVerification', $$סקירה ועדכון סטטוס אימות משתמש.$$),

  ('en', 'adminPlaceholderProfileEdits', $$Approve or deny user profile edit requests.$$),
  ('es', 'adminPlaceholderProfileEdits', $$Aprueba o rechaza solicitudes de edición de perfil.$$),
  ('he', 'adminPlaceholderProfileEdits', $$אישור או דחיית בקשות עריכת פרופיל.$$),

  ('en', 'adminAppConfigLoadFailed', $$Failed to load app config.$$),
  ('es', 'adminAppConfigLoadFailed', $$No se pudo cargar la configuración.$$),
  ('he', 'adminAppConfigLoadFailed', $$טעינת התצורה נכשלה.$$),

  ('en', 'adminAppConfigSaveFailed', $$Failed to save. Please try again.$$),
  ('es', 'adminAppConfigSaveFailed', $$No se pudo guardar. Inténtalo de nuevo.$$),
  ('he', 'adminAppConfigSaveFailed', $$השמירה נכשלה. נסו שוב.$$),

  ('en', 'adminAppConfigDeleteFailed', $$Failed to delete. Please try again.$$),
  ('es', 'adminAppConfigDeleteFailed', $$No se pudo eliminar. Inténtalo de nuevo.$$),
  ('he', 'adminAppConfigDeleteFailed', $$המחיקה נכשלה. נסו שוב.$$),

  ('en', 'adminAppConfigAdd', $$Add Config$$),
  ('es', 'adminAppConfigAdd', $$Agregar configuración$$),
  ('he', 'adminAppConfigAdd', $$הוספת תצורה$$),

  ('en', 'adminAppConfigEdit', $$Edit Config$$),
  ('es', 'adminAppConfigEdit', $$Editar configuración$$),
  ('he', 'adminAppConfigEdit', $$עריכת תצורה$$),

  ('en', 'adminAppConfigDeleteTitle', $$Delete config?$$),
  ('es', 'adminAppConfigDeleteTitle', $$¿Eliminar configuración?$$),
  ('he', 'adminAppConfigDeleteTitle', $$למחוק תצורה?$$),

  ('en', 'adminAppConfigDeleteBody', $$Delete config "{key}"?$$),
  ('es', 'adminAppConfigDeleteBody', $$¿Eliminar la configuración "{key}"?$$),
  ('he', 'adminAppConfigDeleteBody', $$למחוק את התצורה "{key}"?$$),

  ('en', 'adminAppConfigKey', $$Config key$$),
  ('es', 'adminAppConfigKey', $$Clave de configuración$$),
  ('he', 'adminAppConfigKey', $$מפתח תצורה$$),

  ('en', 'adminAppConfigKeyRequired', $$Config key is required$$),
  ('es', 'adminAppConfigKeyRequired', $$La clave es obligatoria$$),
  ('he', 'adminAppConfigKeyRequired', $$מפתח תצורה הוא שדה חובה$$),

  ('en', 'adminAppConfigValue', $$Config value (JSON)$$),
  ('es', 'adminAppConfigValue', $$Valor (JSON)$$),
  ('he', 'adminAppConfigValue', $$ערך תצורה (JSON)$$),

  ('en', 'adminAppConfigValueRequired', $$Config value is required$$),
  ('es', 'adminAppConfigValueRequired', $$El valor es obligatorio$$),
  ('he', 'adminAppConfigValueRequired', $$ערך תצורה הוא שדה חובה$$),

  ('en', 'adminAppConfigType', $$Type$$),
  ('es', 'adminAppConfigType', $$Tipo$$),
  ('he', 'adminAppConfigType', $$סוג$$),

  ('en', 'adminAppConfigTypeRequired', $$Type is required$$),
  ('es', 'adminAppConfigTypeRequired', $$El tipo es obligatorio$$),
  ('he', 'adminAppConfigTypeRequired', $$סוג הוא שדה חובה$$),

  ('en', 'adminAppConfigCategory', $$Category$$),
  ('es', 'adminAppConfigCategory', $$Categoría$$),
  ('he', 'adminAppConfigCategory', $$קטגוריה$$),

  ('en', 'adminAppConfigCategoryRequired', $$Category is required$$),
  ('es', 'adminAppConfigCategoryRequired', $$La categoría es obligatoria$$),
  ('he', 'adminAppConfigCategoryRequired', $$קטגוריה היא שדה חובה$$),

  ('en', 'adminAppConfigDescription', $$Description$$),
  ('es', 'adminAppConfigDescription', $$Descripción$$),
  ('he', 'adminAppConfigDescription', $$תיאור$$),

  ('en', 'adminAppConfigDescriptionRequired', $$Description is required$$),
  ('es', 'adminAppConfigDescriptionRequired', $$La descripción es obligatoria$$),
  ('he', 'adminAppConfigDescriptionRequired', $$תיאור הוא שדה חובה$$),

  ('en', 'adminAppConfigIsUserConfigurable', $$User configurable$$),
  ('es', 'adminAppConfigIsUserConfigurable', $$Configurable por el usuario$$),
  ('he', 'adminAppConfigIsUserConfigurable', $$ניתן להגדרה ע"י משתמש$$),

  ('en', 'adminAppConfigMinValue', $$Minimum$$),
  ('es', 'adminAppConfigMinValue', $$Mínimo$$),
  ('he', 'adminAppConfigMinValue', $$מינימום$$),

  ('en', 'adminAppConfigMaxValue', $$Maximum$$),
  ('es', 'adminAppConfigMaxValue', $$Máximo$$),
  ('he', 'adminAppConfigMaxValue', $$מקסימום$$),

  ('en', 'adminAppConfigAllowedValues', $$Allowed values (JSON)$$),
  ('es', 'adminAppConfigAllowedValues', $$Valores permitidos (JSON)$$),
  ('he', 'adminAppConfigAllowedValues', $$ערכים מותרים (JSON)$$),

  ('en', 'adminAppConfigAllowedValuesShort', $$Allowed$$),
  ('es', 'adminAppConfigAllowedValuesShort', $$Permitidos$$),
  ('he', 'adminAppConfigAllowedValuesShort', $$מותרים$$),

  ('en', 'adminAppConfigSearchHint', $$Search by key, category, type, or description$$),
  ('es', 'adminAppConfigSearchHint', $$Buscar por clave, categoría, tipo o descripción$$),
  ('he', 'adminAppConfigSearchHint', $$חיפוש לפי מפתח, קטגוריה, סוג או תיאור$$),

  ('en', 'adminAppConfigClearFilters', $$Clear filters$$),
  ('es', 'adminAppConfigClearFilters', $$Borrar filtros$$),
  ('he', 'adminAppConfigClearFilters', $$ניקוי מסננים$$),

  ('en', 'adminAppConfigAllCategories', $$All categories$$),
  ('es', 'adminAppConfigAllCategories', $$Todas las categorías$$),
  ('he', 'adminAppConfigAllCategories', $$כל הקטגוריות$$),

  ('en', 'adminAppConfigAllUserConfigurable', $$All$$),
  ('es', 'adminAppConfigAllUserConfigurable', $$Todos$$),
  ('he', 'adminAppConfigAllUserConfigurable', $$הכול$$),

  ('en', 'adminAppConfigCount', $${count} configs$$),
  ('es', 'adminAppConfigCount', $${count} configuraciones$$),
  ('he', 'adminAppConfigCount', $${count} תצורות$$),

  ('en', 'adminSaved', $$Saved.$$),
  ('es', 'adminSaved', $$Guardado.$$),
  ('he', 'adminSaved', $$נשמר.$$),

  ('en', 'adminDeleted', $$Deleted.$$),
  ('es', 'adminDeleted', $$Eliminado.$$),
  ('he', 'adminDeleted', $$נמחק.$$),

  ('en', 'adminTranslationsLoadFailed', $$Failed to load translations.$$),
  ('es', 'adminTranslationsLoadFailed', $$No se pudieron cargar las traducciones.$$),
  ('he', 'adminTranslationsLoadFailed', $$טעינת התרגומים נכשלה.$$),

  ('en', 'adminTranslationsSaveFailed', $$Failed to save. Please try again.$$),
  ('es', 'adminTranslationsSaveFailed', $$No se pudo guardar. Inténtalo de nuevo.$$),
  ('he', 'adminTranslationsSaveFailed', $$השמירה נכשלה. נסו שוב.$$),

  ('en', 'adminTranslationsDeleteFailed', $$Failed to delete. Please try again.$$),
  ('es', 'adminTranslationsDeleteFailed', $$No se pudo eliminar. Inténtalo de nuevo.$$),
  ('he', 'adminTranslationsDeleteFailed', $$המחיקה נכשלה. נסו שוב.$$),

  ('en', 'adminTranslationsAddKey', $$Add Key$$),
  ('es', 'adminTranslationsAddKey', $$Agregar clave$$),
  ('he', 'adminTranslationsAddKey', $$הוספת מפתח$$),

  ('en', 'adminTranslationsEditKey', $$Edit Key$$),
  ('es', 'adminTranslationsEditKey', $$Editar clave$$),
  ('he', 'adminTranslationsEditKey', $$עריכת מפתח$$),

  ('en', 'adminTranslationsDeleteTitle', $$Delete translation key?$$),
  ('es', 'adminTranslationsDeleteTitle', $$¿Eliminar clave de traducción?$$),
  ('he', 'adminTranslationsDeleteTitle', $$למחוק מפתח תרגום?$$),

  ('en', 'adminTranslationsDeleteBody', $$Delete "{key}" for all languages?$$),
  ('es', 'adminTranslationsDeleteBody', $$¿Eliminar "{key}" en todos los idiomas?$$),
  ('he', 'adminTranslationsDeleteBody', $$למחוק את "{key}" בכל השפות?$$),

  ('en', 'adminTranslationsKey', $$Key$$),
  ('es', 'adminTranslationsKey', $$Clave$$),
  ('he', 'adminTranslationsKey', $$מפתח$$),

  ('en', 'adminTranslationsKeyRequired', $$Key is required$$),
  ('es', 'adminTranslationsKeyRequired', $$La clave es obligatoria$$),
  ('he', 'adminTranslationsKeyRequired', $$מפתח הוא שדה חובה$$),

  ('en', 'adminTranslationsSearchHint', $$Search by key or value$$),
  ('es', 'adminTranslationsSearchHint', $$Buscar por clave o valor$$),
  ('he', 'adminTranslationsSearchHint', $$חיפוש לפי מפתח או ערך$$),

  ('en', 'adminTranslationsCount', $${count} keys$$),
  ('es', 'adminTranslationsCount', $${count} claves$$),
  ('he', 'adminTranslationsCount', $${count} מפתחות$$),

  ('en', 'adminTranslationsMissingAny', $$Missing any locale$$),
  ('es', 'adminTranslationsMissingAny', $$Falta algún idioma$$),
  ('he', 'adminTranslationsMissingAny', $$חסרה שפה כלשהי$$),

  ('en', 'adminTranslationsMissingLocale', $$Missing locale$$),
  ('es', 'adminTranslationsMissingLocale', $$Idioma faltante$$),
  ('he', 'adminTranslationsMissingLocale', $$שפה חסרה$$),

  ('en', 'adminTranslationsAll', $$All$$),
  ('es', 'adminTranslationsAll', $$Todos$$),
  ('he', 'adminTranslationsAll', $$הכול$$),

  ('en', 'adminTranslationsBulkImport', $$Bulk import$$),
  ('es', 'adminTranslationsBulkImport', $$Importación masiva$$),
  ('he', 'adminTranslationsBulkImport', $$ייבוא מרוכז$$),

  ('en', 'adminTranslationsBulkImportTitle', $$Bulk import translations$$),
  ('es', 'adminTranslationsBulkImportTitle', $$Importación masiva de traducciones$$),
  ('he', 'adminTranslationsBulkImportTitle', $$ייבוא מרוכז של תרגומים$$),

  ('en', 'adminTranslationsBulkImportFormat', $$Paste one line per key: key<TAB>en<TAB>es<TAB>he (or key|en|es|he).$$),
  ('es', 'adminTranslationsBulkImportFormat', $$Pega una línea por clave: key<TAB>en<TAB>es<TAB>he (o key|en|es|he).$$),
  ('he', 'adminTranslationsBulkImportFormat', $$הדביקו שורה לכל מפתח: key<TAB>en<TAB>es<TAB>he (או key|en|es|he).$$),

  ('en', 'adminTranslationsBulkImportDelimiter', $$Delimiter$$),
  ('es', 'adminTranslationsBulkImportDelimiter', $$Delimitador$$),
  ('he', 'adminTranslationsBulkImportDelimiter', $$מפריד$$),

  ('en', 'adminTranslationsBulkImportDelimiterAuto', $$Auto$$),
  ('es', 'adminTranslationsBulkImportDelimiterAuto', $$Automático$$),
  ('he', 'adminTranslationsBulkImportDelimiterAuto', $$אוטומטי$$),

  ('en', 'adminTranslationsBulkImportDelimiterTab', $$Tab$$),
  ('es', 'adminTranslationsBulkImportDelimiterTab', $$Tabulación$$),
  ('he', 'adminTranslationsBulkImportDelimiterTab', $$טאב$$),

  ('en', 'adminTranslationsBulkImportDelimiterPipe', $$Pipe (|)$$),
  ('es', 'adminTranslationsBulkImportDelimiterPipe', $$Barra (|)$$),
  ('he', 'adminTranslationsBulkImportDelimiterPipe', $$קו אנכי (|)$$),

  ('en', 'adminTranslationsBulkImportAllowEmpty', $$Allow empty values (overwrites)$$),
  ('es', 'adminTranslationsBulkImportAllowEmpty', $$Permitir valores vacíos (sobrescribe)$$),
  ('he', 'adminTranslationsBulkImportAllowEmpty', $$לאפשר ערכים ריקים (דורס)$$),

  ('en', 'adminTranslationsBulkImportHint', $$example.key\tEnglish text\tTexto en español\tטקסט בעברית$$),
  ('es', 'adminTranslationsBulkImportHint', $$ejemplo.clave\tTexto en inglés\tTexto en español\tטקסט בעברית$$),
  ('he', 'adminTranslationsBulkImportHint', $$example.key\tEnglish text\tTexto en español\tטקסט בעברית$$),

  ('en', 'adminTranslationsBulkImportParsedCount', $${count} rows ready$$),
  ('es', 'adminTranslationsBulkImportParsedCount', $${count} filas listas$$),
  ('he', 'adminTranslationsBulkImportParsedCount', $${count} שורות מוכנות$$),

  ('en', 'adminTranslationsBulkImportNothingParsed', $$Nothing to import.$$),
  ('es', 'adminTranslationsBulkImportNothingParsed', $$Nada para importar.$$),
  ('he', 'adminTranslationsBulkImportNothingParsed', $$אין מה לייבא.$$),

  ('en', 'adminTranslationsBulkImportImport', $$Import$$),
  ('es', 'adminTranslationsBulkImportImport', $$Importar$$),
  ('he', 'adminTranslationsBulkImportImport', $$ייבוא$$),

  ('en', 'adminSubscriptionsLoadFailed', $$Failed to load subscriptions.$$),
  ('es', 'adminSubscriptionsLoadFailed', $$No se pudieron cargar las suscripciones.$$),
  ('he', 'adminSubscriptionsLoadFailed', $$טעינת המינויים נכשלה.$$),

  ('en', 'adminSubscriptionsSaveFailed', $$Failed to save. Please try again.$$),
  ('es', 'adminSubscriptionsSaveFailed', $$No se pudo guardar. Inténtalo de nuevo.$$),
  ('he', 'adminSubscriptionsSaveFailed', $$השמירה נכשלה. נסו שוב.$$),

  ('en', 'adminSubscriptionsDeleteFailed', $$Failed to delete. Please try again.$$),
  ('es', 'adminSubscriptionsDeleteFailed', $$No se pudo eliminar. Inténtalo de nuevo.$$),
  ('he', 'adminSubscriptionsDeleteFailed', $$המחיקה נכשלה. נסו שוב.$$),

  ('en', 'adminSubscriptionsAddTier', $$Add Tier$$),
  ('es', 'adminSubscriptionsAddTier', $$Agregar nivel$$),
  ('he', 'adminSubscriptionsAddTier', $$הוספת דרגה$$),

  ('en', 'adminSubscriptionsEditTier', $$Edit Tier$$),
  ('es', 'adminSubscriptionsEditTier', $$Editar nivel$$),
  ('he', 'adminSubscriptionsEditTier', $$עריכת דרגה$$),

  ('en', 'adminSubscriptionsDeleteTierTitle', $$Delete tier?$$),
  ('es', 'adminSubscriptionsDeleteTierTitle', $$¿Eliminar nivel?$$),
  ('he', 'adminSubscriptionsDeleteTierTitle', $$למחוק דרגה?$$),

  ('en', 'adminSubscriptionsDeleteTierBody', $$Delete tier "{id}" and all its plans?$$),
  ('es', 'adminSubscriptionsDeleteTierBody', $$¿Eliminar el nivel "{id}" y todos sus planes?$$),
  ('he', 'adminSubscriptionsDeleteTierBody', $$למחוק את הדרגה "{id}" ואת כל התכניות שלה?$$),

  ('en', 'adminSubscriptionsAddPlan', $$Add Plan$$),
  ('es', 'adminSubscriptionsAddPlan', $$Agregar plan$$),
  ('he', 'adminSubscriptionsAddPlan', $$הוספת תכנית$$),

  ('en', 'adminSubscriptionsEditPlan', $$Edit Plan$$),
  ('es', 'adminSubscriptionsEditPlan', $$Editar plan$$),
  ('he', 'adminSubscriptionsEditPlan', $$עריכת תכנית$$),

  ('en', 'adminSubscriptionsDeletePlanTitle', $$Delete plan?$$),
  ('es', 'adminSubscriptionsDeletePlanTitle', $$¿Eliminar plan?$$),
  ('he', 'adminSubscriptionsDeletePlanTitle', $$למחוק תכנית?$$),

  ('en', 'adminSubscriptionsDeletePlanBody', $$Delete plan "{id}"?$$),
  ('es', 'adminSubscriptionsDeletePlanBody', $$¿Eliminar el plan "{id}"?$$),
  ('he', 'adminSubscriptionsDeletePlanBody', $$למחוק את התכנית "{id}"?$$),

  ('en', 'adminSubscriptionsTierId', $$Tier ID$$),
  ('es', 'adminSubscriptionsTierId', $$ID del nivel$$),
  ('he', 'adminSubscriptionsTierId', $$מזהה דרגה$$),

  ('en', 'adminSubscriptionsTierIdRequired', $$Tier ID is required$$),
  ('es', 'adminSubscriptionsTierIdRequired', $$El ID del nivel es obligatorio$$),
  ('he', 'adminSubscriptionsTierIdRequired', $$מזהה דרגה הוא שדה חובה$$),

  ('en', 'adminSubscriptionsPlanId', $$Plan ID$$),
  ('es', 'adminSubscriptionsPlanId', $$ID del plan$$),
  ('he', 'adminSubscriptionsPlanId', $$מזהה תכנית$$),

  ('en', 'adminSubscriptionsPlanIdRequired', $$Plan ID is required$$),
  ('es', 'adminSubscriptionsPlanIdRequired', $$El ID del plan es obligatorio$$),
  ('he', 'adminSubscriptionsPlanIdRequired', $$מזהה תכנית הוא שדה חובה$$),

  ('en', 'adminSubscriptionsDuration', $$Duration$$),
  ('es', 'adminSubscriptionsDuration', $$Duración$$),
  ('he', 'adminSubscriptionsDuration', $$משך$$),

  ('en', 'adminSubscriptionsPriceDisplay', $$Price display$$),
  ('es', 'adminSubscriptionsPriceDisplay', $$Texto de precio$$),
  ('he', 'adminSubscriptionsPriceDisplay', $$תצוגת מחיר$$),

  ('en', 'adminSubscriptionsPriceDisplayRequired', $$Price display is required$$),
  ('es', 'adminSubscriptionsPriceDisplayRequired', $$El texto de precio es obligatorio$$),
  ('he', 'adminSubscriptionsPriceDisplayRequired', $$תצוגת מחיר היא שדה חובה$$),

  ('en', 'adminSubscriptionsSavingsText', $$Savings text$$),
  ('es', 'adminSubscriptionsSavingsText', $$Texto de ahorro$$),
  ('he', 'adminSubscriptionsSavingsText', $$טקסט חיסכון$$),

  ('en', 'adminSubscriptionsRevenueCatId', $$RevenueCat package identifier$$),
  ('es', 'adminSubscriptionsRevenueCatId', $$Identificador de paquete RevenueCat$$),
  ('he', 'adminSubscriptionsRevenueCatId', $$מזהה חבילת RevenueCat$$),

  ('en', 'adminSubscriptionsRevenueCatIdRequired', $$RevenueCat identifier is required$$),
  ('es', 'adminSubscriptionsRevenueCatIdRequired', $$El identificador de RevenueCat es obligatorio$$),
  ('he', 'adminSubscriptionsRevenueCatIdRequired', $$מזהה RevenueCat הוא שדה חובה$$),

  ('en', 'adminSubscriptionsSortOrder', $$Sort order$$),
  ('es', 'adminSubscriptionsSortOrder', $$Orden$$),
  ('he', 'adminSubscriptionsSortOrder', $$סדר$$),

  ('en', 'adminSubscriptionsIsActive', $$Active$$),
  ('es', 'adminSubscriptionsIsActive', $$Activo$$),
  ('he', 'adminSubscriptionsIsActive', $$פעיל$$),

  ('en', 'adminSubscriptionsYes', $$Yes$$),
  ('es', 'adminSubscriptionsYes', $$Sí$$),
  ('he', 'adminSubscriptionsYes', $$כן$$),

  ('en', 'adminSubscriptionsNo', $$No$$),
  ('es', 'adminSubscriptionsNo', $$No$$),
  ('he', 'adminSubscriptionsNo', $$לא$$),

  ('en', 'adminSubscriptionsTitleKey', $$Title key$$),
  ('es', 'adminSubscriptionsTitleKey', $$Clave del título$$),
  ('he', 'adminSubscriptionsTitleKey', $$מפתח כותרת$$),

  ('en', 'adminSubscriptionsTitleKeyRequired', $$Title key is required$$),
  ('es', 'adminSubscriptionsTitleKeyRequired', $$La clave del título es obligatoria$$),
  ('he', 'adminSubscriptionsTitleKeyRequired', $$מפתח כותרת הוא שדה חובה$$),

  ('en', 'adminSubscriptionsSubtitleKey', $$Subtitle key$$),
  ('es', 'adminSubscriptionsSubtitleKey', $$Clave del subtítulo$$),
  ('he', 'adminSubscriptionsSubtitleKey', $$מפתח תת־כותרת$$),

  ('en', 'adminSubscriptionsFeaturesKey', $$Features key$$),
  ('es', 'adminSubscriptionsFeaturesKey', $$Clave de características$$),
  ('he', 'adminSubscriptionsFeaturesKey', $$מפתח תכונות$$),

  ('en', 'adminSubscriptionsFeaturesKeyRequired', $$Features key is required$$),
  ('es', 'adminSubscriptionsFeaturesKeyRequired', $$La clave de características es obligatoria$$),
  ('he', 'adminSubscriptionsFeaturesKeyRequired', $$מפתח תכונות הוא שדה חובה$$),

  ('en', 'adminSubscriptionsBadgeKey', $$Badge key$$),
  ('es', 'adminSubscriptionsBadgeKey', $$Clave de insignia$$),
  ('he', 'adminSubscriptionsBadgeKey', $$מפתח תג$$),

  ('en', 'adminSubscriptionsPreview', $$Preview$$),
  ('es', 'adminSubscriptionsPreview', $$Vista previa$$),
  ('he', 'adminSubscriptionsPreview', $$תצוגה מקדימה$$),

  ('en', 'adminSubscriptionsPlansHeader', $$Plans$$),
  ('es', 'adminSubscriptionsPlansHeader', $$Planes$$),
  ('he', 'adminSubscriptionsPlansHeader', $$תכניות$$),

  ('en', 'adminSubscriptionsNoPlans', $$No plans yet.$$),
  ('es', 'adminSubscriptionsNoPlans', $$Aún no hay planes.$$),
  ('he', 'adminSubscriptionsNoPlans', $$אין תכניות עדיין.$$),

  ('en', 'adminSubscriptionsActions', $$Actions$$),
  ('es', 'adminSubscriptionsActions', $$Acciones$$),
  ('he', 'adminSubscriptionsActions', $$פעולות$$),

  ('en', 'paywallPeriodDaily', $$Daily$$),
  ('es', 'paywallPeriodDaily', $$Diario$$),
  ('he', 'paywallPeriodDaily', $$יומי$$),

  ('en', 'paywallPeriodWeekly', $$Weekly$$),
  ('es', 'paywallPeriodWeekly', $$Semanal$$),
  ('he', 'paywallPeriodWeekly', $$שבועי$$),

  ('en', 'paywallPeriodMonthly', $$Monthly$$),
  ('es', 'paywallPeriodMonthly', $$Mensual$$),
  ('he', 'paywallPeriodMonthly', $$חודשי$$),

  ('en', 'paywallPeriodAnnual', $$Annual$$),
  ('es', 'paywallPeriodAnnual', $$Anual$$),
  ('he', 'paywallPeriodAnnual', $$שנתי$$),

  ('en', 'adminApprove', $$Approve$$),
  ('es', 'adminApprove', $$Aprobar$$),
  ('he', 'adminApprove', $$אישור$$),

  ('en', 'adminAttachment', $$Attachment$$),
  ('es', 'adminAttachment', $$Adjunto$$),
  ('he', 'adminAttachment', $$קובץ מצורף$$),

  ('en', 'adminAttachmentLoadFailed', $$Failed to load attachment.$$),
  ('es', 'adminAttachmentLoadFailed', $$No se pudo cargar el adjunto.$$),
  ('he', 'adminAttachmentLoadFailed', $$טעינת הקובץ המצורף נכשלה.$$),

  ('en', 'adminAuditTrail', $$Audit trail$$),
  ('es', 'adminAuditTrail', $$Registro de auditoría$$),
  ('he', 'adminAuditTrail', $$יומן ביקורת$$),

  ('en', 'adminBroadcastsActionUrl', $$Action URL$$),
  ('es', 'adminBroadcastsActionUrl', $$URL de acción$$),
  ('he', 'adminBroadcastsActionUrl', $$כתובת URL לפעולה$$),

  ('en', 'adminBroadcastsActionUrlInvalid', $$Please enter a valid http(s) URL$$),
  ('es', 'adminBroadcastsActionUrlInvalid', $$Introduce una URL http(s) válida$$),
  ('he', 'adminBroadcastsActionUrlInvalid', $$נא להזין כתובת URL חוקית מסוג http(s)$$),

  ('en', 'adminBroadcastsActionUrlText', $$Action button text$$),
  ('es', 'adminBroadcastsActionUrlText', $$Texto del botón de acción$$),
  ('he', 'adminBroadcastsActionUrlText', $$טקסט כפתור פעולה$$),

  ('en', 'adminBroadcastsActualSent', $$Queued$$),
  ('es', 'adminBroadcastsActualSent', $$En cola$$),
  ('he', 'adminBroadcastsActualSent', $$בתור$$),

  ('en', 'adminBroadcastsAdd', $$Add Broadcast$$),
  ('es', 'adminBroadcastsAdd', $$Agregar difusión$$),
  ('he', 'adminBroadcastsAdd', $$הוספת שידור$$),

  ('en', 'adminBroadcastsAdvancedJsonTitle', $$Advanced (JSON)$$),
  ('es', 'adminBroadcastsAdvancedJsonTitle', $$Avanzado (JSON)$$),
  ('he', 'adminBroadcastsAdvancedJsonTitle', $$מתקדם (JSON)$$),

  ('en', 'adminBroadcastsApplyJson', $$Apply JSON$$),
  ('es', 'adminBroadcastsApplyJson', $$Aplicar JSON$$),
  ('he', 'adminBroadcastsApplyJson', $$החל JSON$$),

  ('en', 'adminBroadcastsClearDateTime', $$Clear$$),
  ('es', 'adminBroadcastsClearDateTime', $$Borrar$$),
  ('he', 'adminBroadcastsClearDateTime', $$ניקוי$$),

  ('en', 'adminBroadcastsCountTargets', $$Count target users$$),
  ('es', 'adminBroadcastsCountTargets', $$Contar usuarios objetivo$$),
  ('he', 'adminBroadcastsCountTargets', $$ספירת משתמשי יעד$$),

  ('en', 'adminBroadcastsDeleteBody', $$Delete "{title}"?$$),
  ('es', 'adminBroadcastsDeleteBody', $$¿Eliminar "{title}"?$$),
  ('he', 'adminBroadcastsDeleteBody', $$למחוק את "{title}"?$$),

  ('en', 'adminBroadcastsDeleteFailed', $$Failed to delete. Please try again.$$),
  ('es', 'adminBroadcastsDeleteFailed', $$No se pudo eliminar. Inténtalo de nuevo.$$),
  ('he', 'adminBroadcastsDeleteFailed', $$המחיקה נכשלה. נסו שוב.$$),

  ('en', 'adminBroadcastsDeleteTitle', $$Delete broadcast?$$),
  ('es', 'adminBroadcastsDeleteTitle', $$¿Eliminar difusión?$$),
  ('he', 'adminBroadcastsDeleteTitle', $$למחוק שידור?$$),

  ('en', 'adminBroadcastsDetails', $$Details$$),
  ('es', 'adminBroadcastsDetails', $$Detalles$$),
  ('he', 'adminBroadcastsDetails', $$פרטים$$),

  ('en', 'adminBroadcastsDetailsTitle', $$Broadcast details$$),
  ('es', 'adminBroadcastsDetailsTitle', $$Detalles de la difusión$$),
  ('he', 'adminBroadcastsDetailsTitle', $$פרטי שידור$$),

  ('en', 'adminBroadcastsEdit', $$Edit Broadcast$$),
  ('es', 'adminBroadcastsEdit', $$Editar difusión$$),
  ('he', 'adminBroadcastsEdit', $$עריכת שידור$$),

  ('en', 'adminBroadcastsEmpty', $$No broadcasts found.$$),
  ('es', 'adminBroadcastsEmpty', $$No se encontraron difusiones.$$),
  ('he', 'adminBroadcastsEmpty', $$לא נמצאו שידורים.$$),

  ('en', 'adminBroadcastsFilterAgeRange', $$Age range$$),
  ('es', 'adminBroadcastsFilterAgeRange', $$Rango de edad$$),
  ('he', 'adminBroadcastsFilterAgeRange', $$טווח גילאים$$),

  ('en', 'adminBroadcastsFilterAllUsers', $$All users$$),
  ('es', 'adminBroadcastsFilterAllUsers', $$Todos los usuarios$$),
  ('he', 'adminBroadcastsFilterAllUsers', $$כל המשתמשים$$),

  ('en', 'adminBroadcastsFilterCriteria', $$Filter criteria (JSON)$$),
  ('es', 'adminBroadcastsFilterCriteria', $$Criterios de filtro (JSON)$$),
  ('he', 'adminBroadcastsFilterCriteria', $$קריטריוני סינון (JSON)$$),

  ('en', 'adminBroadcastsFilterGender', $$Gender$$),
  ('es', 'adminBroadcastsFilterGender', $$Género$$),
  ('he', 'adminBroadcastsFilterGender', $$מגדר$$),

  ('en', 'adminBroadcastsFilterLastActiveDays', $$Last active$$),
  ('es', 'adminBroadcastsFilterLastActiveDays', $$Última actividad$$),
  ('he', 'adminBroadcastsFilterLastActiveDays', $$פעילות אחרונה$$),

  ('en', 'adminBroadcastsFilterPlatform', $$Platform$$),
  ('es', 'adminBroadcastsFilterPlatform', $$Plataforma$$),
  ('he', 'adminBroadcastsFilterPlatform', $$פלטפורמה$$),

  ('en', 'adminBroadcastsFilterStatus', $$Status$$),
  ('es', 'adminBroadcastsFilterStatus', $$Estado$$),
  ('he', 'adminBroadcastsFilterStatus', $$סטטוס$$),

  ('en', 'adminBroadcastsFilterSubscriptionTiers', $$Subscription tiers$$),
  ('es', 'adminBroadcastsFilterSubscriptionTiers', $$Niveles de suscripción$$),
  ('he', 'adminBroadcastsFilterSubscriptionTiers', $$דרגות מנוי$$),

  ('en', 'adminBroadcastsFilterUiLanguage', $$UI language$$),
  ('es', 'adminBroadcastsFilterUiLanguage', $$Idioma de la interfaz$$),
  ('he', 'adminBroadcastsFilterUiLanguage', $$שפת ממשק$$),

  ('en', 'adminBroadcastsFilterUiLanguages', $$UI languages$$),
  ('es', 'adminBroadcastsFilterUiLanguages', $$Idiomas de la interfaz$$),
  ('he', 'adminBroadcastsFilterUiLanguages', $$שפות ממשק$$),

  ('en', 'adminBroadcastsFilterVerificationStatus', $$Verification status$$),
  ('es', 'adminBroadcastsFilterVerificationStatus', $$Estado de verificación$$),
  ('he', 'adminBroadcastsFilterVerificationStatus', $$סטטוס אימות$$),

  ('en', 'adminBroadcastsFilterVisibleOnly', $$Visible only$$),
  ('es', 'adminBroadcastsFilterVisibleOnly', $$Solo visibles$$),
  ('he', 'adminBroadcastsFilterVisibleOnly', $$נראים בלבד$$),

  ('en', 'adminBroadcastsInvalidJson', $$Invalid JSON.$$),
  ('es', 'adminBroadcastsInvalidJson', $$JSON no válido.$$),
  ('he', 'adminBroadcastsInvalidJson', $$JSON לא תקין.$$),

  ('en', 'adminBroadcastsLanguage', $$Language$$),
  ('es', 'adminBroadcastsLanguage', $$Idioma$$),
  ('he', 'adminBroadcastsLanguage', $$שפה$$),

  ('en', 'adminBroadcastsLanguageLabel', $$Language$$),
  ('es', 'adminBroadcastsLanguageLabel', $$Idioma$$),
  ('he', 'adminBroadcastsLanguageLabel', $$שפה$$),

  ('en', 'adminBroadcastsLastActiveLabel', $$Last active within$$),
  ('es', 'adminBroadcastsLastActiveLabel', $$Última actividad dentro de$$),
  ('he', 'adminBroadcastsLastActiveLabel', $$פעיל לאחרונה בתוך$$),

  ('en', 'adminBroadcastsLastActiveValue', $${days} days$$),
  ('es', 'adminBroadcastsLastActiveValue', $${days} días$$),
  ('he', 'adminBroadcastsLastActiveValue', $${days} ימים$$),

  ('en', 'adminBroadcastsLoadFailed', $$Failed to load broadcasts.$$),
  ('es', 'adminBroadcastsLoadFailed', $$No se pudieron cargar las difusiones.$$),
  ('he', 'adminBroadcastsLoadFailed', $$טעינת השידורים נכשלה.$$),

  ('en', 'adminBroadcastsMessage', $$Message$$),
  ('es', 'adminBroadcastsMessage', $$Mensaje$$),
  ('he', 'adminBroadcastsMessage', $$הודעה$$),

  ('en', 'adminBroadcastsMessageRequired', $$Message is required$$),
  ('es', 'adminBroadcastsMessageRequired', $$El mensaje es obligatorio$$),
  ('he', 'adminBroadcastsMessageRequired', $$הודעה היא שדה חובה$$),

  ('en', 'adminBroadcastsMode', $$Mode$$),
  ('es', 'adminBroadcastsMode', $$Modo$$),
  ('he', 'adminBroadcastsMode', $$מצב$$),

  ('en', 'adminBroadcastsModePerLanguage', $$Per-language$$),
  ('es', 'adminBroadcastsModePerLanguage', $$Por idioma$$),
  ('he', 'adminBroadcastsModePerLanguage', $$לפי שפה$$),

  ('en', 'adminBroadcastsModeSingle', $$Single message$$),
  ('es', 'adminBroadcastsModeSingle', $$Mensaje único$$),
  ('he', 'adminBroadcastsModeSingle', $$הודעה אחת$$),

  ('en', 'adminBroadcastsPickDateTime', $$Pick$$),
  ('es', 'adminBroadcastsPickDateTime', $$Elegir$$),
  ('he', 'adminBroadcastsPickDateTime', $$בחירה$$),

  ('en', 'adminBroadcastsPreview', $$Preview$$),
  ('es', 'adminBroadcastsPreview', $$Vista previa$$),
  ('he', 'adminBroadcastsPreview', $$תצוגה מקדימה$$),

  ('en', 'adminBroadcastsSaveFailed', $$Failed to save. Please try again.$$),
  ('es', 'adminBroadcastsSaveFailed', $$No se pudo guardar. Inténtalo de nuevo.$$),
  ('he', 'adminBroadcastsSaveFailed', $$השמירה נכשלה. נסו שוב.$$),

  ('en', 'adminBroadcastsScheduledAt', $$Scheduled$$),
  ('es', 'adminBroadcastsScheduledAt', $$Programado$$),
  ('he', 'adminBroadcastsScheduledAt', $$מתוזמן$$),

  ('en', 'adminBroadcastsScheduleNone', $$Not scheduled$$),
  ('es', 'adminBroadcastsScheduleNone', $$No programado$$),
  ('he', 'adminBroadcastsScheduleNone', $$לא מתוזמן$$),

  ('en', 'adminBroadcastsScheduleNow', $$Schedule now$$),
  ('es', 'adminBroadcastsScheduleNow', $$Programar ahora$$),
  ('he', 'adminBroadcastsScheduleNow', $$לתזמן עכשיו$$),

  ('en', 'adminBroadcastsSearchHint', $$Search by title, message, status, or id$$),
  ('es', 'adminBroadcastsSearchHint', $$Buscar por título, mensaje, estado o id$$),
  ('he', 'adminBroadcastsSearchHint', $$חיפוש לפי כותרת, הודעה, סטטוס או מזהה$$),

  ('en', 'adminBroadcastsSentAt', $$Sent$$),
  ('es', 'adminBroadcastsSentAt', $$Enviado$$),
  ('he', 'adminBroadcastsSentAt', $$נשלח$$),

  ('en', 'adminBroadcastsStatsDelivered', $$Delivered$$),
  ('es', 'adminBroadcastsStatsDelivered', $$Entregado$$),
  ('he', 'adminBroadcastsStatsDelivered', $$נמסר$$),

  ('en', 'adminBroadcastsStatsFailed', $$Failed$$),
  ('es', 'adminBroadcastsStatsFailed', $$Fallido$$),
  ('he', 'adminBroadcastsStatsFailed', $$נכשל$$),

  ('en', 'adminBroadcastsStatsRate', $$Rate$$),
  ('es', 'adminBroadcastsStatsRate', $$Tasa$$),
  ('he', 'adminBroadcastsStatsRate', $$שיעור$$),

  ('en', 'adminBroadcastsStatsSent', $$Sent$$),
  ('es', 'adminBroadcastsStatsSent', $$Enviado$$),
  ('he', 'adminBroadcastsStatsSent', $$נשלח$$),

  ('en', 'adminBroadcastsStatsTitle', $$Delivery stats$$),
  ('es', 'adminBroadcastsStatsTitle', $$Estadísticas de entrega$$),
  ('he', 'adminBroadcastsStatsTitle', $$סטטיסטיקות מסירה$$),

  ('en', 'adminBroadcastsStatsTotal', $$Total$$),
  ('es', 'adminBroadcastsStatsTotal', $$Total$$),
  ('he', 'adminBroadcastsStatsTotal', $$סה״כ$$),

  ('en', 'adminBroadcastsStatus', $$Status$$),
  ('es', 'adminBroadcastsStatus', $$Estado$$),
  ('he', 'adminBroadcastsStatus', $$סטטוס$$),

  ('en', 'adminBroadcastsStatusAll', $$All$$),
  ('es', 'adminBroadcastsStatusAll', $$Todos$$),
  ('he', 'adminBroadcastsStatusAll', $$הכול$$),

  ('en', 'adminBroadcastsStatusDraft', $$Draft$$),
  ('es', 'adminBroadcastsStatusDraft', $$Borrador$$),
  ('he', 'adminBroadcastsStatusDraft', $$טיוטה$$),

  ('en', 'adminBroadcastsStatusFailed', $$Failed$$),
  ('es', 'adminBroadcastsStatusFailed', $$Fallido$$),
  ('he', 'adminBroadcastsStatusFailed', $$נכשל$$),

  ('en', 'adminBroadcastsStatusInvisible', $$Invisible$$),
  ('es', 'adminBroadcastsStatusInvisible', $$Invisible$$),
  ('he', 'adminBroadcastsStatusInvisible', $$בלתי נראה$$),

  ('en', 'adminBroadcastsStatusOffline', $$Offline$$),
  ('es', 'adminBroadcastsStatusOffline', $$Desconectado$$),
  ('he', 'adminBroadcastsStatusOffline', $$לא מקוון$$),

  ('en', 'adminBroadcastsStatusScheduled', $$Scheduled$$),
  ('es', 'adminBroadcastsStatusScheduled', $$Programado$$),
  ('he', 'adminBroadcastsStatusScheduled', $$מתוזמן$$),

  ('en', 'adminBroadcastsStatusSending', $$Sending$$),
  ('es', 'adminBroadcastsStatusSending', $$Enviando$$),
  ('he', 'adminBroadcastsStatusSending', $$שולח$$),

  ('en', 'adminBroadcastsStatusSent', $$Sent$$),
  ('es', 'adminBroadcastsStatusSent', $$Enviado$$),
  ('he', 'adminBroadcastsStatusSent', $$נשלח$$),

  ('en', 'adminBroadcastsStatusVisible', $$Visible$$),
  ('es', 'adminBroadcastsStatusVisible', $$Visible$$),
  ('he', 'adminBroadcastsStatusVisible', $$נראה$$),

  ('en', 'adminBroadcastsTargetCount', $$Target$$),
  ('es', 'adminBroadcastsTargetCount', $$Objetivo$$),
  ('he', 'adminBroadcastsTargetCount', $$יעד$$),

  ('en', 'adminBroadcastsTargetCountValue', $$Target users: {count}$$),
  ('es', 'adminBroadcastsTargetCountValue', $$Usuarios objetivo: {count}$$),
  ('he', 'adminBroadcastsTargetCountValue', $$משתמשי יעד: {count}$$),

  ('en', 'adminBroadcastsTargetingEmpty', $$No targeting filters selected.$$),
  ('es', 'adminBroadcastsTargetingEmpty', $$No se seleccionaron filtros de segmentación.$$),
  ('he', 'adminBroadcastsTargetingEmpty', $$לא נבחרו מסנני מיקוד.$$),

  ('en', 'adminBroadcastsTargetingFiltersTitle', $$Targeting filters$$),
  ('es', 'adminBroadcastsTargetingFiltersTitle', $$Filtros de segmentación$$),
  ('he', 'adminBroadcastsTargetingFiltersTitle', $$מסנני מיקוד$$),

  ('en', 'adminBroadcastsTargetingTitle', $$Targeting$$),
  ('es', 'adminBroadcastsTargetingTitle', $$Segmentación$$),
  ('he', 'adminBroadcastsTargetingTitle', $$מיקוד$$),

  ('en', 'adminBroadcastsTargetUnknown', $$Target user count unavailable.$$),
  ('es', 'adminBroadcastsTargetUnknown', $$No se puede obtener el recuento de usuarios objetivo.$$),
  ('he', 'adminBroadcastsTargetUnknown', $$מספר משתמשי היעד אינו זמין.$$),

  ('en', 'adminBroadcastsTargetUsersEmpty', $$No users found.$$),
  ('es', 'adminBroadcastsTargetUsersEmpty', $$No se encontraron usuarios.$$),
  ('he', 'adminBroadcastsTargetUsersEmpty', $$לא נמצאו משתמשים.$$),

  ('en', 'adminBroadcastsTargetUsersLoadFailed', $$Failed to load users.$$),
  ('es', 'adminBroadcastsTargetUsersLoadFailed', $$No se pudieron cargar los usuarios.$$),
  ('he', 'adminBroadcastsTargetUsersLoadFailed', $$טעינת המשתמשים נכשלה.$$),

  ('en', 'adminBroadcastsTargetUsersTitle', $$Target users$$),
  ('es', 'adminBroadcastsTargetUsersTitle', $$Usuarios objetivo$$),
  ('he', 'adminBroadcastsTargetUsersTitle', $$משתמשי יעד$$),

  ('en', 'adminBroadcastsTimeAll', $$All$$),
  ('es', 'adminBroadcastsTimeAll', $$Todo$$),
  ('he', 'adminBroadcastsTimeAll', $$הכול$$),

  ('en', 'adminBroadcastsTimeFilter', $$Time$$),
  ('es', 'adminBroadcastsTimeFilter', $$Tiempo$$),
  ('he', 'adminBroadcastsTimeFilter', $$זמן$$),

  ('en', 'adminBroadcastsTimePast', $$Past$$),
  ('es', 'adminBroadcastsTimePast', $$Pasado$$),
  ('he', 'adminBroadcastsTimePast', $$עבר$$),

  ('en', 'adminBroadcastsTimeUpcoming', $$Upcoming$$),
  ('es', 'adminBroadcastsTimeUpcoming', $$Próximo$$),
  ('he', 'adminBroadcastsTimeUpcoming', $$עתידי$$),

  ('en', 'adminBroadcastsTitle', $$Title$$),
  ('es', 'adminBroadcastsTitle', $$Título$$),
  ('he', 'adminBroadcastsTitle', $$כותרת$$),

  ('en', 'adminBroadcastsTitleRequired', $$Title is required$$),
  ('es', 'adminBroadcastsTitleRequired', $$El título es obligatorio$$),
  ('he', 'adminBroadcastsTitleRequired', $$כותרת היא שדה חובה$$),

  ('en', 'adminBroadcastsType', $$Type$$),
  ('es', 'adminBroadcastsType', $$Tipo$$),
  ('he', 'adminBroadcastsType', $$סוג$$),

  ('en', 'adminBroadcastsTypeInfo', $$Information$$),
  ('es', 'adminBroadcastsTypeInfo', $$Información$$),
  ('he', 'adminBroadcastsTypeInfo', $$מידע$$),

  ('en', 'adminBroadcastsTypePromotion', $$Promotion$$),
  ('es', 'adminBroadcastsTypePromotion', $$Promoción$$),
  ('he', 'adminBroadcastsTypePromotion', $$קידום$$),

  ('en', 'adminBroadcastsTypeUpdate', $$Update$$),
  ('es', 'adminBroadcastsTypeUpdate', $$Actualización$$),
  ('he', 'adminBroadcastsTypeUpdate', $$עדכון$$),

  ('en', 'adminBroadcastsTypeWarning', $$Warning$$),
  ('es', 'adminBroadcastsTypeWarning', $$Advertencia$$),
  ('he', 'adminBroadcastsTypeWarning', $$אזהרה$$),

  ('en', 'adminBroadcastsViewUsers', $$View users$$),
  ('es', 'adminBroadcastsViewUsers', $$Ver usuarios$$),
  ('he', 'adminBroadcastsViewUsers', $$הצגת משתמשים$$),

  ('en', 'adminLastUpdated', $$Last updated$$),
  ('es', 'adminLastUpdated', $$Última actualización$$),
  ('he', 'adminLastUpdated', $$עודכן לאחרונה$$),

  ('en', 'adminNo', $$No$$),
  ('es', 'adminNo', $$No$$),
  ('he', 'adminNo', $$לא$$),

  ('en', 'adminPlatformAndroid', $$Android$$),
  ('es', 'adminPlatformAndroid', $$Android$$),
  ('he', 'adminPlatformAndroid', $$Android$$),

  ('en', 'adminPlatformIos', $$iOS$$),
  ('es', 'adminPlatformIos', $$iOS$$),
  ('he', 'adminPlatformIos', $$iOS$$),

  ('en', 'adminPlatformWeb', $$Web$$),
  ('es', 'adminPlatformWeb', $$Web$$),
  ('he', 'adminPlatformWeb', $$Web$$),

  ('en', 'adminProfileEditsApproveTitle', $$Approve request$$),
  ('es', 'adminProfileEditsApproveTitle', $$Aprobar solicitud$$),
  ('he', 'adminProfileEditsApproveTitle', $$אישור בקשה$$),

  ('en', 'adminProfileEditsAttachments', $$Attachments$$),
  ('es', 'adminProfileEditsAttachments', $$Adjuntos$$),
  ('he', 'adminProfileEditsAttachments', $$קבצים מצורפים$$),

  ('en', 'adminProfileEditsAttachmentsShort', $$Files$$),
  ('es', 'adminProfileEditsAttachmentsShort', $$Archivos$$),
  ('he', 'adminProfileEditsAttachmentsShort', $$קבצים$$),

  ('en', 'adminProfileEditsCount', $${count} requests$$),
  ('es', 'adminProfileEditsCount', $${count} solicitudes$$),
  ('he', 'adminProfileEditsCount', $${count} בקשות$$),

  ('en', 'adminProfileEditsCreated', $$Created$$),
  ('es', 'adminProfileEditsCreated', $$Creado$$),
  ('he', 'adminProfileEditsCreated', $$נוצר$$),

  ('en', 'adminProfileEditsDetails', $$Details$$),
  ('es', 'adminProfileEditsDetails', $$Detalles$$),
  ('he', 'adminProfileEditsDetails', $$פרטים$$),

  ('en', 'adminProfileEditsDetailsTitle', $$Request details$$),
  ('es', 'adminProfileEditsDetailsTitle', $$Detalles de la solicitud$$),
  ('he', 'adminProfileEditsDetailsTitle', $$פרטי הבקשה$$),

  ('en', 'adminProfileEditsEmpty', $$No requests found.$$),
  ('es', 'adminProfileEditsEmpty', $$No se encontraron solicitudes.$$),
  ('he', 'adminProfileEditsEmpty', $$לא נמצאו בקשות.$$),

  ('en', 'adminProfileEditsFields', $$Fields$$),
  ('es', 'adminProfileEditsFields', $$Campos$$),
  ('he', 'adminProfileEditsFields', $$שדות$$),

  ('en', 'adminProfileEditsLoadFailed', $$Failed to load profile edit requests.$$),
  ('es', 'adminProfileEditsLoadFailed', $$No se pudieron cargar las solicitudes de edición de perfil.$$),
  ('he', 'adminProfileEditsLoadFailed', $$טעינת בקשות עריכת הפרופיל נכשלה.$$),

  ('en', 'adminProfileEditsMessage', $$Message$$),
  ('es', 'adminProfileEditsMessage', $$Mensaje$$),
  ('he', 'adminProfileEditsMessage', $$הודעה$$),

  ('en', 'adminProfileEditsNoAttachments', $$No attachments.$$),
  ('es', 'adminProfileEditsNoAttachments', $$Sin adjuntos.$$),
  ('he', 'adminProfileEditsNoAttachments', $$אין קבצים מצורפים.$$),

  ('en', 'adminProfileEditsRejectTitle', $$Reject request$$),
  ('es', 'adminProfileEditsRejectTitle', $$Rechazar solicitud$$),
  ('he', 'adminProfileEditsRejectTitle', $$דחיית בקשה$$),

  ('en', 'adminProfileEditsReviewedAt', $$Reviewed at$$),
  ('es', 'adminProfileEditsReviewedAt', $$Revisado el$$),
  ('he', 'adminProfileEditsReviewedAt', $$נסקר ב־$$),

  ('en', 'adminProfileEditsReviewedBy', $$Reviewed by$$),
  ('es', 'adminProfileEditsReviewedBy', $$Revisado por$$),
  ('he', 'adminProfileEditsReviewedBy', $$נסקר על ידי$$),

  ('en', 'adminProfileEditsSearchHint', $$Search by user, field, or message$$),
  ('es', 'adminProfileEditsSearchHint', $$Buscar por usuario, campo o mensaje$$),
  ('he', 'adminProfileEditsSearchHint', $$חיפוש לפי משתמש, שדה או הודעה$$),

  ('en', 'adminProfileEditsStatus', $$Status$$),
  ('es', 'adminProfileEditsStatus', $$Estado$$),
  ('he', 'adminProfileEditsStatus', $$סטטוס$$),

  ('en', 'adminProfileEditsStatusFilter', $$Status$$),
  ('es', 'adminProfileEditsStatusFilter', $$Estado$$),
  ('he', 'adminProfileEditsStatusFilter', $$סטטוס$$),

  ('en', 'adminProfileEditsUpdateFailed', $$Failed to update request. Please try again.$$),
  ('es', 'adminProfileEditsUpdateFailed', $$No se pudo actualizar la solicitud. Inténtalo de nuevo.$$),
  ('he', 'adminProfileEditsUpdateFailed', $$עדכון הבקשה נכשל. נסו שוב.$$),

  ('en', 'adminProfileEditsUser', $$User$$),
  ('es', 'adminProfileEditsUser', $$Usuario$$),
  ('he', 'adminProfileEditsUser', $$משתמש$$),

  ('en', 'adminReject', $$Reject$$),
  ('es', 'adminReject', $$Rechazar$$),
  ('he', 'adminReject', $$דחייה$$),

  ('en', 'adminRequestId', $$Request ID$$),
  ('es', 'adminRequestId', $$ID de solicitud$$),
  ('he', 'adminRequestId', $$מזהה בקשה$$),

  ('en', 'adminReviewerNote', $$Reviewer note$$),
  ('es', 'adminReviewerNote', $$Nota del revisor$$),
  ('he', 'adminReviewerNote', $$הערת סוקר$$),

  ('en', 'adminStatusAll', $$All$$),
  ('es', 'adminStatusAll', $$Todos$$),
  ('he', 'adminStatusAll', $$הכול$$),

  ('en', 'adminStatusAnalyzing', $$Analyzing$$),
  ('es', 'adminStatusAnalyzing', $$Analizando$$),
  ('he', 'adminStatusAnalyzing', $$בניתוח$$),

  ('en', 'adminStatusApproved', $$Approved$$),
  ('es', 'adminStatusApproved', $$Aprobado$$),
  ('he', 'adminStatusApproved', $$אושר$$),

  ('en', 'adminStatusPending', $$Pending$$),
  ('es', 'adminStatusPending', $$Pendiente$$),
  ('he', 'adminStatusPending', $$ממתין$$),

  ('en', 'adminStatusRejected', $$Rejected$$),
  ('es', 'adminStatusRejected', $$Rechazado$$),
  ('he', 'adminStatusRejected', $$נדחה$$),

  ('en', 'adminStatusUnverified', $$Unverified$$),
  ('es', 'adminStatusUnverified', $$No verificado$$),
  ('he', 'adminStatusUnverified', $$לא מאומת$$),

  ('en', 'adminSubscriptionTierFree', $$Free$$),
  ('es', 'adminSubscriptionTierFree', $$Gratis$$),
  ('he', 'adminSubscriptionTierFree', $$חינם$$),

  ('en', 'adminUnknown', $$Unknown$$),
  ('es', 'adminUnknown', $$Desconocido$$),
  ('he', 'adminUnknown', $$לא ידוע$$),

  ('en', 'adminUserId', $$User ID$$),
  ('es', 'adminUserId', $$ID de usuario$$),
  ('he', 'adminUserId', $$מזהה משתמש$$),

  ('en', 'adminVerificationAiAnalysis', $$AI analysis$$),
  ('es', 'adminVerificationAiAnalysis', $$Análisis de IA$$),
  ('he', 'adminVerificationAiAnalysis', $$ניתוח בינה מלאכותית$$),

  ('en', 'adminVerificationAiConfidence', $$Confidence$$),
  ('es', 'adminVerificationAiConfidence', $$Confianza$$),
  ('he', 'adminVerificationAiConfidence', $$רמת ביטחון$$),

  ('en', 'adminVerificationAiDecision', $$Decision$$),
  ('es', 'adminVerificationAiDecision', $$Decisión$$),
  ('he', 'adminVerificationAiDecision', $$החלטה$$),

  ('en', 'adminVerificationAiDetailsRoot', $$Analysis$$),
  ('es', 'adminVerificationAiDetailsRoot', $$Análisis$$),
  ('he', 'adminVerificationAiDetailsRoot', $$ניתוח$$),

  ('en', 'adminVerificationAiDetailsTitle', $$Details$$),
  ('es', 'adminVerificationAiDetailsTitle', $$Detalles$$),
  ('he', 'adminVerificationAiDetailsTitle', $$פרטים$$),

  ('en', 'adminVerificationAiFieldAuthentic', $$Authentic$$),
  ('es', 'adminVerificationAiFieldAuthentic', $$Auténtico$$),
  ('he', 'adminVerificationAiFieldAuthentic', $$אותנטי$$),

  ('en', 'adminVerificationAiFieldAuthenticityAudit', $$Authenticity audit$$),
  ('es', 'adminVerificationAiFieldAuthenticityAudit', $$Auditoría de autenticidad$$),
  ('he', 'adminVerificationAiFieldAuthenticityAudit', $$בדיקת אותנטיות$$),

  ('en', 'adminVerificationAiFieldComparedAt', $$Compared at$$),
  ('es', 'adminVerificationAiFieldComparedAt', $$Comparado el$$),
  ('he', 'adminVerificationAiFieldComparedAt', $$הושווה ב־$$),

  ('en', 'adminVerificationAiFieldConfidence', $$Confidence$$),
  ('es', 'adminVerificationAiFieldConfidence', $$Confianza$$),
  ('he', 'adminVerificationAiFieldConfidence', $$רמת ביטחון$$),

  ('en', 'adminVerificationAiFieldGesture', $$Gesture$$),
  ('es', 'adminVerificationAiFieldGesture', $$Gesto$$),
  ('he', 'adminVerificationAiFieldGesture', $$מחווה$$),

  ('en', 'adminVerificationAiFieldGestureRequirement', $$Gesture requirement$$),
  ('es', 'adminVerificationAiFieldGestureRequirement', $$Requisito de gesto$$),
  ('he', 'adminVerificationAiFieldGestureRequirement', $$דרישת מחווה$$),

  ('en', 'adminVerificationAiFieldMatch', $$Face match$$),
  ('es', 'adminVerificationAiFieldMatch', $$Coincidencia facial$$),
  ('he', 'adminVerificationAiFieldMatch', $$התאמת פנים$$),

  ('en', 'adminVerificationAiFieldNote', $$Note$$),
  ('es', 'adminVerificationAiFieldNote', $$Nota$$),
  ('he', 'adminVerificationAiFieldNote', $$הערה$$),

  ('en', 'adminVerificationAiFieldReasoning', $$Reasoning$$),
  ('es', 'adminVerificationAiFieldReasoning', $$Razonamiento$$),
  ('he', 'adminVerificationAiFieldReasoning', $$נימוקים$$),

  ('en', 'adminVerificationAiFieldService', $$Service$$),
  ('es', 'adminVerificationAiFieldService', $$Servicio$$),
  ('he', 'adminVerificationAiFieldService', $$שירות$$),

  ('en', 'adminVerificationAiFieldSimilarity', $$Similarity$$),
  ('es', 'adminVerificationAiFieldSimilarity', $$Similitud$$),
  ('he', 'adminVerificationAiFieldSimilarity', $$דמיון$$),

  ('en', 'adminVerificationAiFlags', $$Flags$$),
  ('es', 'adminVerificationAiFlags', $$Indicadores$$),
  ('he', 'adminVerificationAiFlags', $$דגלים$$),

  ('en', 'adminVerificationAiMatch', $$Match$$),
  ('es', 'adminVerificationAiMatch', $$Coincidencia$$),
  ('he', 'adminVerificationAiMatch', $$התאמה$$),

  ('en', 'adminVerificationAiRawJson', $$Raw JSON$$),
  ('es', 'adminVerificationAiRawJson', $$JSON sin procesar$$),
  ('he', 'adminVerificationAiRawJson', $$JSON גולמי$$),

  ('en', 'adminVerificationAiReasons', $$Reasons$$),
  ('es', 'adminVerificationAiReasons', $$Motivos$$),
  ('he', 'adminVerificationAiReasons', $$סיבות$$),

  ('en', 'adminVerificationAiSummaryTitle', $$Summary$$),
  ('es', 'adminVerificationAiSummaryTitle', $$Resumen$$),
  ('he', 'adminVerificationAiSummaryTitle', $$סיכום$$),

  ('en', 'adminVerificationAiSummaryUnavailable', $$No summary fields available.$$),
  ('es', 'adminVerificationAiSummaryUnavailable', $$No hay campos de resumen disponibles.$$),
  ('he', 'adminVerificationAiSummaryUnavailable', $$אין שדות סיכום זמינים.$$),

  ('en', 'adminVerificationAutoRejected', $$Auto-rejected$$),
  ('es', 'adminVerificationAutoRejected', $$Rechazado automáticamente$$),
  ('he', 'adminVerificationAutoRejected', $$נדחה אוטומטית$$),

  ('en', 'adminVerificationCount', $${count} users$$),
  ('es', 'adminVerificationCount', $${count} usuarios$$),
  ('he', 'adminVerificationCount', $${count} משתמשים$$),

  ('en', 'adminVerificationEmpty', $$No users found.$$),
  ('es', 'adminVerificationEmpty', $$No se encontraron usuarios.$$),
  ('he', 'adminVerificationEmpty', $$לא נמצאו משתמשים.$$),

  ('en', 'adminVerificationLoadFailed', $$Failed to load verification users.$$),
  ('es', 'adminVerificationLoadFailed', $$No se pudieron cargar los usuarios de verificación.$$),
  ('he', 'adminVerificationLoadFailed', $$טעינת משתמשי האימות נכשלה.$$),

  ('en', 'adminVerificationNoAnalysis', $$No AI analysis available.$$),
  ('es', 'adminVerificationNoAnalysis', $$No hay análisis de IA disponible.$$),
  ('he', 'adminVerificationNoAnalysis', $$אין ניתוח בינה מלאכותית זמין.$$),

  ('en', 'adminVerificationNoPhoto', $$No verification photo.$$),
  ('es', 'adminVerificationNoPhoto', $$No hay foto de verificación.$$),
  ('he', 'adminVerificationNoPhoto', $$אין תמונת אימות.$$),

  ('en', 'adminVerificationNoProfilePhoto', $$No profile photo.$$),
  ('es', 'adminVerificationNoProfilePhoto', $$No hay foto de perfil.$$),
  ('he', 'adminVerificationNoProfilePhoto', $$אין תמונת פרופיל.$$),

  ('en', 'adminVerificationPhotoLoadFailed', $$Failed to load photo.$$),
  ('es', 'adminVerificationPhotoLoadFailed', $$No se pudo cargar la foto.$$),
  ('he', 'adminVerificationPhotoLoadFailed', $$טעינת התמונה נכשלה.$$),

  ('en', 'adminVerificationPhotoTitle', $$Verification photo$$),
  ('es', 'adminVerificationPhotoTitle', $$Foto de verificación$$),
  ('he', 'adminVerificationPhotoTitle', $$תמונת אימות$$),

  ('en', 'adminVerificationProfilePhoto', $$Profile photo$$),
  ('es', 'adminVerificationProfilePhoto', $$Foto de perfil$$),
  ('he', 'adminVerificationProfilePhoto', $$תמונת פרופיל$$),

  ('en', 'adminVerificationReviewed', $$Reviewed$$),
  ('es', 'adminVerificationReviewed', $$Revisado$$),
  ('he', 'adminVerificationReviewed', $$נסקר$$),

  ('en', 'adminVerificationReviewTitle', $$Verification review$$),
  ('es', 'adminVerificationReviewTitle', $$Revisión de verificación$$),
  ('he', 'adminVerificationReviewTitle', $$סקירת אימות$$),

  ('en', 'adminVerificationScore', $$Score$$),
  ('es', 'adminVerificationScore', $$Puntuación$$),
  ('he', 'adminVerificationScore', $$ציון$$),

  ('en', 'adminVerificationSearchHint', $$Search by user id, name, or status$$),
  ('es', 'adminVerificationSearchHint', $$Buscar por id de usuario, nombre o estado$$),
  ('he', 'adminVerificationSearchHint', $$חיפוש לפי מזהה משתמש, שם או סטטוס$$),

  ('en', 'adminVerificationStatus', $$Status$$),
  ('es', 'adminVerificationStatus', $$Estado$$),
  ('he', 'adminVerificationStatus', $$סטטוס$$),

  ('en', 'adminVerificationStatusFilter', $$Status$$),
  ('es', 'adminVerificationStatusFilter', $$Estado$$),
  ('he', 'adminVerificationStatusFilter', $$סטטוס$$),

  ('en', 'adminVerificationSubmitted', $$Submitted$$),
  ('es', 'adminVerificationSubmitted', $$Enviado$$),
  ('he', 'adminVerificationSubmitted', $$הוגש$$),

  ('en', 'adminVerificationUpdateFailed', $$Failed to update verification. Please try again.$$),
  ('es', 'adminVerificationUpdateFailed', $$No se pudo actualizar la verificación. Inténtalo de nuevo.$$),
  ('he', 'adminVerificationUpdateFailed', $$עדכון האימות נכשל. נסו שוב.$$),

  ('en', 'adminVerificationViewPhoto', $$View photo$$),
  ('es', 'adminVerificationViewPhoto', $$Ver foto$$),
  ('he', 'adminVerificationViewPhoto', $$הצגת תמונה$$),

  ('en', 'adminYes', $$Yes$$),
  ('es', 'adminYes', $$Sí$$),
  ('he', 'adminYes', $$כן$$),

  ('en', 'generalAny', $$Any$$),
  ('es', 'generalAny', $$Cualquiera$$),
  ('he', 'generalAny', $$כלשהו$$),

  ('en', 'generalApply', $$Apply$$),
  ('es', 'generalApply', $$Aplicar$$),
  ('he', 'generalApply', $$החל$$),

  ('en', 'generalClear', $$Clear$$),
  ('es', 'generalClear', $$Borrar$$),
  ('he', 'generalClear', $$ניקוי$$),

  ('en', 'generalClose', $$Close$$),
  ('es', 'generalClose', $$Cerrar$$),
  ('he', 'generalClose', $$סגירה$$),

  ('en', 'generalFilters', $$Filters$$),
  ('es', 'generalFilters', $$Filtros$$),
  ('he', 'generalFilters', $$מסננים$$),

  ('en', 'generalLoadMore', $$Load more$$),
  ('es', 'generalLoadMore', $$Cargar más$$),
  ('he', 'generalLoadMore', $$טען עוד$$),

  ('en', 'generalAdd', $$Add$$),
  ('es', 'generalAdd', $$Agregar$$),
  ('he', 'generalAdd', $$הוסף$$),

  ('en', 'adminIntentsInterestsTabIntents', $$Intents$$),
  ('es', 'adminIntentsInterestsTabIntents', $$Intenciones$$),
  ('he', 'adminIntentsInterestsTabIntents', $$כוונות$$),

  ('en', 'adminIntentsInterestsTabInterests', $$Interests$$),
  ('es', 'adminIntentsInterestsTabInterests', $$Intereses$$),
  ('he', 'adminIntentsInterestsTabInterests', $$תחומי עניין$$),

  ('en', 'adminIntentsInterestsFilterAll', $$All$$),
  ('es', 'adminIntentsInterestsFilterAll', $$Todos$$),
  ('he', 'adminIntentsInterestsFilterAll', $$הכול$$),

  ('en', 'adminIntentsInterestsFilterSocial', $$Social$$),
  ('es', 'adminIntentsInterestsFilterSocial', $$Social$$),
  ('he', 'adminIntentsInterestsFilterSocial', $$חברתי$$),

  ('en', 'adminIntentsInterestsFilterBusiness', $$Business$$),
  ('es', 'adminIntentsInterestsFilterBusiness', $$Negocios$$),
  ('he', 'adminIntentsInterestsFilterBusiness', $$עסקי$$),

  ('en', 'adminIntentsInterestsSearchHint', $$Search by key, translation key, or preview$$),
  ('es', 'adminIntentsInterestsSearchHint', $$Buscar por clave, clave de traducción o vista previa$$),
  ('he', 'adminIntentsInterestsSearchHint', $$חיפוש לפי מפתח, מפתח תרגום או תצוגה מקדימה$$),

  ('en', 'adminIntentsInterestsEmpty', $$No items found.$$),
  ('es', 'adminIntentsInterestsEmpty', $$No se encontraron elementos.$$),
  ('he', 'adminIntentsInterestsEmpty', $$לא נמצאו פריטים.$$),

  ('en', 'adminIntentsInterestsLoadFailed', $$Failed to load. Please try again.$$),
  ('es', 'adminIntentsInterestsLoadFailed', $$No se pudo cargar. Inténtalo de nuevo.$$),
  ('he', 'adminIntentsInterestsLoadFailed', $$הטעינה נכשלה. נסו שוב.$$),

  ('en', 'adminIntentsInterestsRpcMissing', $$This admin action is not deployed yet. Apply the latest Supabase migrations.$$),
  ('es', 'adminIntentsInterestsRpcMissing', $$Esta acción de administración aún no está implementada. Aplica las últimas migraciones de Supabase.$$),
  ('he', 'adminIntentsInterestsRpcMissing', $$פעולת הניהול הזו עדיין לא הוטמעה. יש להחיל את המיגרציות האחרונות של Supabase.$$),

  ('en', 'adminIntentsInterestsSaveFailed', $$Failed to save. Please try again.$$),
  ('es', 'adminIntentsInterestsSaveFailed', $$No se pudo guardar. Inténtalo de nuevo.$$),
  ('he', 'adminIntentsInterestsSaveFailed', $$השמירה נכשלה. נסו שוב.$$),

  ('en', 'adminIntentsInterestsDeleteFailed', $$Failed to delete. Please try again.$$),
  ('es', 'adminIntentsInterestsDeleteFailed', $$No se pudo eliminar. Inténtalo de nuevo.$$),
  ('he', 'adminIntentsInterestsDeleteFailed', $$המחיקה נכשלה. נסו שוב.$$),

  ('en', 'adminIntentsInterestsEditText', $$Edit text$$),
  ('es', 'adminIntentsInterestsEditText', $$Editar texto$$),
  ('he', 'adminIntentsInterestsEditText', $$עריכת טקסט$$),

  ('en', 'adminIntentsInterestsEditTextTitle', $$Edit text: {key}$$),
  ('es', 'adminIntentsInterestsEditTextTitle', $$Editar texto: {key}$$),
  ('he', 'adminIntentsInterestsEditTextTitle', $$עריכת טקסט: {key}$$),

  ('en', 'adminIntentsInterestsLocaleEn', $$English$$),
  ('es', 'adminIntentsInterestsLocaleEn', $$Inglés$$),
  ('he', 'adminIntentsInterestsLocaleEn', $$אנגלית$$),

  ('en', 'adminIntentsInterestsLocaleEs', $$Spanish$$),
  ('es', 'adminIntentsInterestsLocaleEs', $$Español$$),
  ('he', 'adminIntentsInterestsLocaleEs', $$ספרדית$$),

  ('en', 'adminIntentsInterestsLocaleHe', $$Hebrew$$),
  ('es', 'adminIntentsInterestsLocaleHe', $$Hebreo$$),
  ('he', 'adminIntentsInterestsLocaleHe', $$עברית$$),

  ('en', 'adminIntentsInterestsAddIntent', $$Add Intent$$),
  ('es', 'adminIntentsInterestsAddIntent', $$Agregar intención$$),
  ('he', 'adminIntentsInterestsAddIntent', $$הוסף כוונה$$),

  ('en', 'adminIntentsInterestsEditIntent', $$Edit Intent$$),
  ('es', 'adminIntentsInterestsEditIntent', $$Editar intención$$),
  ('he', 'adminIntentsInterestsEditIntent', $$עריכת כוונה$$),

  ('en', 'adminIntentsInterestsDeleteIntentTitle', $$Delete intent?$$),
  ('es', 'adminIntentsInterestsDeleteIntentTitle', $$¿Eliminar intención?$$),
  ('he', 'adminIntentsInterestsDeleteIntentTitle', $$למחוק כוונה?$$),

  ('en', 'adminIntentsInterestsDeleteIntentBody', $$Delete intent "{key}"?$$),
  ('es', 'adminIntentsInterestsDeleteIntentBody', $$¿Eliminar intención "{key}"?$$),
  ('he', 'adminIntentsInterestsDeleteIntentBody', $$למחוק כוונה "{key}"?$$),

  ('en', 'adminIntentsInterestsAddInterest', $$Add Interest$$),
  ('es', 'adminIntentsInterestsAddInterest', $$Agregar interés$$),
  ('he', 'adminIntentsInterestsAddInterest', $$הוסף תחום עניין$$),

  ('en', 'adminIntentsInterestsEditInterest', $$Edit Interest$$),
  ('es', 'adminIntentsInterestsEditInterest', $$Editar interés$$),
  ('he', 'adminIntentsInterestsEditInterest', $$עריכת תחום עניין$$),

  ('en', 'adminIntentsInterestsDeleteInterestTitle', $$Delete interest?$$),
  ('es', 'adminIntentsInterestsDeleteInterestTitle', $$¿Eliminar interés?$$),
  ('he', 'adminIntentsInterestsDeleteInterestTitle', $$למחוק תחום עניין?$$),

  ('en', 'adminIntentsInterestsDeleteInterestBody', $$Delete interest "{key}"?$$),
  ('es', 'adminIntentsInterestsDeleteInterestBody', $$¿Eliminar interés "{key}"?$$),
  ('he', 'adminIntentsInterestsDeleteInterestBody', $$למחוק תחום עניין "{key}"?$$),

  ('en', 'adminIntentsInterestsAddChild', $$Add child$$),
  ('es', 'adminIntentsInterestsAddChild', $$Agregar subelemento$$),
  ('he', 'adminIntentsInterestsAddChild', $$הוסף תת־פריט$$),

  ('en', 'adminIntentsInterestsKey', $$Key$$),
  ('es', 'adminIntentsInterestsKey', $$Clave$$),
  ('he', 'adminIntentsInterestsKey', $$מפתח$$),

  ('en', 'adminIntentsInterestsKeyRequired', $$Key is required$$),
  ('es', 'adminIntentsInterestsKeyRequired', $$La clave es obligatoria$$),
  ('he', 'adminIntentsInterestsKeyRequired', $$מפתח הוא שדה חובה$$),

  ('en', 'adminIntentsInterestsTranslationKey', $$Translation key$$),
  ('es', 'adminIntentsInterestsTranslationKey', $$Clave de traducción$$),
  ('he', 'adminIntentsInterestsTranslationKey', $$מפתח תרגום$$),

  ('en', 'adminIntentsInterestsTranslationKeyRequired', $$Translation key is required$$),
  ('es', 'adminIntentsInterestsTranslationKeyRequired', $$La clave de traducción es obligatoria$$),
  ('he', 'adminIntentsInterestsTranslationKeyRequired', $$מפתח תרגום הוא שדה חובה$$),

  ('en', 'adminIntentsInterestsSortOrder', $$Sort order$$),
  ('es', 'adminIntentsInterestsSortOrder', $$Orden de clasificación$$),
  ('he', 'adminIntentsInterestsSortOrder', $$סדר מיון$$),

  ('en', 'adminIntentsInterestsParent', $$Parent$$),
  ('es', 'adminIntentsInterestsParent', $$Padre$$),
  ('he', 'adminIntentsInterestsParent', $$הורה$$),

  ('en', 'adminIntentsInterestsNoParent', $$No parent$$),
  ('es', 'adminIntentsInterestsNoParent', $$Sin padre$$),
  ('he', 'adminIntentsInterestsNoParent', $$ללא הורה$$),

  ('en', 'adminIntentsInterestsIsSocial', $$Social$$),
  ('es', 'adminIntentsInterestsIsSocial', $$Social$$),
  ('he', 'adminIntentsInterestsIsSocial', $$חברתי$$),

  ('en', 'adminIntentsInterestsIsBusiness', $$Business$$),
  ('es', 'adminIntentsInterestsIsBusiness', $$De negocios$$),
  ('he', 'adminIntentsInterestsIsBusiness', $$עסקי$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
