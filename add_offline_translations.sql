-- Add offline functionality translations for English, Spanish, and Hebrew
-- This script adds all user-facing strings from the offline functionality

-- English translations
INSERT INTO translations (locale, key, value) VALUES
-- Offline Indicator
('en', 'offlineIndicatorTitle', 'MatchMe is offline - showing cached data'),
('en', 'offlineSnackbarMessage', 'MatchMe is offline - using cached data'),

-- Offline Feature Dialogs
('en', 'offlineFeatureUnavailable', 'Feature Unavailable'),
('en', 'offlineFeatureRequiresConnection', 'This feature requires an internet connection.'),
('en', 'offlineSendMessageTitle', 'Cannot send message while offline'),
('en', 'offlineSendMessageBody', 'Your message has been saved locally and will send when you''re back online.'),
('en', 'offlineUpdateVisibilityTitle', 'Cannot update visibility while offline'),
('en', 'offlineUpdateVisibilityBody', 'Your visibility change has been saved locally and will update when you''re back online.'),
('en', 'offlineUpdateProfileTitle', 'Cannot update profile while offline'),
('en', 'offlineUpdateProfileBody', 'Your profile changes have been saved locally and will update when you''re back online.'),
('en', 'offlineUpdateGeneralTitle', 'Cannot make changes while offline'),
('en', 'offlineUpdateGeneralBody', 'Your changes have been saved locally and will update when you''re back online.'),
('en', 'offlineEditMessageTitle', 'Cannot edit message while offline'),
('en', 'offlineEditMessageBody', 'Your message edit has been saved locally and will update when you''re back online.'),
('en', 'offlineDeleteMessageTitle', 'Cannot delete message while offline'),
('en', 'offlineDeleteMessageBody', 'Your deletion request has been saved locally and will update when you''re back online.'),
('en', 'offlineReactToMessageTitle', 'Cannot add reaction while offline'),
('en', 'offlineReactToMessageBody', 'Your reaction has been saved locally and will be added when you''re back online.'),
('en', 'offlineDeleteReactionTitle', 'Cannot remove reaction while offline'),
('en', 'offlineDeleteReactionBody', 'Your reaction removal has been saved locally and will update when you''re back online.'),
('en', 'offlineCreateEventTitle', 'Cannot create event while offline'),
('en', 'offlineCreateEventBody', 'Your event has been saved locally and will be created when you''re back online.'),
('en', 'offlineUpdateEventTitle', 'Cannot update event while offline'),
('en', 'offlineUpdateEventBody', 'Your event changes have been saved locally and will update when you''re back online.'),
('en', 'offlineDeleteEventTitle', 'Cannot delete event while offline'),
('en', 'offlineDeleteEventBody', 'Your deletion request has been saved locally and will update when you''re back online.'),
('en', 'offlineJoinEventTitle', 'Cannot join event while offline'),
('en', 'offlineJoinEventBody', 'Your event join request has been saved locally and will be processed when you''re back online.'),
('en', 'offlineLeaveEventTitle', 'Cannot leave event while offline'),
('en', 'offlineLeaveEventBody', 'Your event leave request has been saved locally and will be processed when you''re back online.'),
('en', 'offlineUpdateLocationTitle', 'Cannot update location while offline'),
('en', 'offlineUpdateLocationBody', 'Your location update has been saved locally and will be sent when you''re back online.'),
('en', 'offlineAddInvisibilityRuleTitle', 'Cannot add invisibility rule while offline'),
('en', 'offlineAddInvisibilityRuleBody', 'Your rule has been saved locally and will be added when you''re back online.'),
('en', 'offlineRemoveInvisibilityRuleTitle', 'Cannot remove invisibility rule while offline'),
('en', 'offlineRemoveInvisibilityRuleBody', 'Your rule removal has been saved locally and will be processed when you''re back online.'),
('en', 'offlineToggleSharedEventTitle', 'Cannot change shared event setting while offline'),
('en', 'offlineToggleSharedEventBody', 'Your preference change has been saved locally and will update when you''re back online.'),
('en', 'offlineToggleSharedMovementTitle', 'Cannot change shared movement setting while offline'),
('en', 'offlineToggleSharedMovementBody', 'Your preference change has been saved locally and will update when you''re back online.'),
('en', 'offlineUpdateNotificationsTitle', 'Cannot update notification settings while offline'),
('en', 'offlineUpdateNotificationsBody', 'Your notification preferences have been saved locally and will update when you''re back online.'),
('en', 'offlineBlockUserTitle', 'Cannot block user while offline'),
('en', 'offlineBlockUserBody', 'Your block has been saved locally and will be processed when you''re back online.'),
('en', 'offlineUnblockUserTitle', 'Cannot unblock user while offline'),
('en', 'offlineUnblockUserBody', 'Your unblock request has been saved locally and will be processed when you''re back online.'),
('en', 'offlineReportUserTitle', 'Cannot report user while offline'),
('en', 'offlineReportUserBody', 'Your report has been saved locally and will be submitted when you''re back online.'),

-- Offline Button Labels and Messages
('en', 'offlineCannotCompleteRequest', 'Cannot Complete Request'),
('en', 'offlineFeatureRequiresConnectionDetailed', '{feature} requires an internet connection. MatchMe is currently offline.'),
('en', 'offlineOkButton', 'OK'),
('en', 'offlineSendAnywayButton', 'Send Anyway'),

-- Pending Mutations
('en', 'offlineSyncingChanges', 'Syncing {count} change{plural}'),
('en', 'offlineSyncingChangesPlural', 's'),
('en', 'offlineViewDetails', 'Details'),
('en', 'offlinePendingChanges', 'Pending Changes'),
('en', 'offlinePendingChangesDescription', 'You have {count} pending change{plural} waiting to sync. These will be sent to the server when your connection is restored.\n\nActions in MatchMe will be unavailable until these sync.'),
('en', 'offlinePendingChangesPlural', 's'),
('en', 'offlineViewPendingDetails', 'View Details')

ON CONFLICT (locale, key) DO UPDATE SET
value = EXCLUDED.value;

-- Spanish translations
INSERT INTO translations (locale, key, value) VALUES
-- Offline Indicator
('es', 'offlineIndicatorTitle', 'MatchMe está sin conexión - mostrando datos en caché'),
('es', 'offlineSnackbarMessage', 'MatchMe está sin conexión - usando datos en caché'),

-- Offline Feature Dialogs
('es', 'offlineFeatureUnavailable', 'Función no disponible'),
('es', 'offlineFeatureRequiresConnection', 'Esta función requiere una conexión a Internet.'),
('es', 'offlineSendMessageTitle', 'No se puede enviar mensaje sin conexión'),
('es', 'offlineSendMessageBody', 'Tu mensaje se ha guardado localmente y se enviará cuando vuelvas a estar en línea.'),
('es', 'offlineUpdateVisibilityTitle', 'No se puede actualizar la visibilidad sin conexión'),
('es', 'offlineUpdateVisibilityBody', 'Tu cambio de visibilidad se ha guardado localmente y se actualizará cuando vuelvas a estar en línea.'),
('es', 'offlineUpdateProfileTitle', 'No se puede actualizar el perfil sin conexión'),
('es', 'offlineUpdateProfileBody', 'Tus cambios de perfil se han guardado localmente y se actualizarán cuando vuelvas a estar en línea.'),
('es', 'offlineUpdateGeneralTitle', 'No se pueden hacer cambios sin conexión'),
('es', 'offlineUpdateGeneralBody', 'Tus cambios se han guardado localmente y se actualizarán cuando vuelvas a estar en línea.'),
('es', 'offlineEditMessageTitle', 'No se puede editar el mensaje sin conexión'),
('es', 'offlineEditMessageBody', 'Tu edición de mensaje se ha guardado localmente y se actualizará cuando vuelvas a estar en línea.'),
('es', 'offlineDeleteMessageTitle', 'No se puede eliminar el mensaje sin conexión'),
('es', 'offlineDeleteMessageBody', 'Tu solicitud de eliminación se ha guardado localmente y se actualizará cuando vuelvas a estar en línea.'),
('es', 'offlineReactToMessageTitle', 'No se puede agregar reacción sin conexión'),
('es', 'offlineReactToMessageBody', 'Tu reacción se ha guardado localmente y se agregará cuando vuelvas a estar en línea.'),
('es', 'offlineDeleteReactionTitle', 'No se puede eliminar la reacción sin conexión'),
('es', 'offlineDeleteReactionBody', 'Tu eliminación de reacción se ha guardado localmente y se actualizará cuando vuelvas a estar en línea.'),
('es', 'offlineCreateEventTitle', 'No se puede crear el evento sin conexión'),
('es', 'offlineCreateEventBody', 'Tu evento se ha guardado localmente y se creará cuando vuelvas a estar en línea.'),
('es', 'offlineUpdateEventTitle', 'No se puede actualizar el evento sin conexión'),
('es', 'offlineUpdateEventBody', 'Tus cambios de evento se han guardado localmente y se actualizarán cuando vuelvas a estar en línea.'),
('es', 'offlineDeleteEventTitle', 'No se puede eliminar el evento sin conexión'),
('es', 'offlineDeleteEventBody', 'Tu solicitud de eliminación se ha guardado localmente y se actualizará cuando vuelvas a estar en línea.'),
('es', 'offlineJoinEventTitle', 'No se puede unirse al evento sin conexión'),
('es', 'offlineJoinEventBody', 'Tu solicitud para unirte al evento se ha guardado localmente y se procesará cuando vuelvas a estar en línea.'),
('es', 'offlineLeaveEventTitle', 'No se puede abandonar el evento sin conexión'),
('es', 'offlineLeaveEventBody', 'Tu solicitud para abandonar el evento se ha guardado localmente y se procesará cuando vuelvas a estar en línea.'),
('es', 'offlineUpdateLocationTitle', 'No se puede actualizar la ubicación sin conexión'),
('es', 'offlineUpdateLocationBody', 'Tu actualización de ubicación se ha guardado localmente y se enviará cuando vuelvas a estar en línea.'),
('es', 'offlineAddInvisibilityRuleTitle', 'No se puede agregar regla de invisibilidad sin conexión'),
('es', 'offlineAddInvisibilityRuleBody', 'Tu regla se ha guardado localmente y se agregará cuando vuelvas a estar en línea.'),
('es', 'offlineRemoveInvisibilityRuleTitle', 'No se puede eliminar la regla de invisibilidad sin conexión'),
('es', 'offlineRemoveInvisibilityRuleBody', 'Tu eliminación de regla se ha guardado localmente y se procesará cuando vuelvas a estar en línea.'),
('es', 'offlineToggleSharedEventTitle', 'No se puede cambiar la configuración de evento compartido sin conexión'),
('es', 'offlineToggleSharedEventBody', 'Tu cambio de preferencia se ha guardado localmente y se actualizará cuando vuelvas a estar en línea.'),
('es', 'offlineToggleSharedMovementTitle', 'No se puede cambiar la configuración de movimiento compartido sin conexión'),
('es', 'offlineToggleSharedMovementBody', 'Tu cambio de preferencia se ha guardado localmente y se actualizará cuando vuelvas a estar en línea.'),
('es', 'offlineUpdateNotificationsTitle', 'No se puede actualizar la configuración de notificaciones sin conexión'),
('es', 'offlineUpdateNotificationsBody', 'Tus preferencias de notificación se han guardado localmente y se actualizarán cuando vuelvas a estar en línea.'),
('es', 'offlineBlockUserTitle', 'No se puede bloquear al usuario sin conexión'),
('es', 'offlineBlockUserBody', 'Tu bloqueo se ha guardado localmente y se procesará cuando vuelvas a estar en línea.'),
('es', 'offlineUnblockUserTitle', 'No se puede desbloquear al usuario sin conexión'),
('es', 'offlineUnblockUserBody', 'Tu solicitud de desbloqueo se ha guardado localmente y se procesará cuando vuelvas a estar en línea.'),
('es', 'offlineReportUserTitle', 'No se puede reportar al usuario sin conexión'),
('es', 'offlineReportUserBody', 'Tu reporte se ha guardado localmente y se presentará cuando vuelvas a estar en línea.'),

-- Offline Button Labels and Messages
('es', 'offlineCannotCompleteRequest', 'No se puede completar la solicitud'),
('es', 'offlineFeatureRequiresConnectionDetailed', '{feature} requiere una conexión a Internet. MatchMe está actualmente sin conexión.'),
('es', 'offlineOkButton', 'Aceptar'),
('es', 'offlineSendAnywayButton', 'Enviar de todas formas'),

-- Pending Mutations
('es', 'offlineSyncingChanges', 'Sincronizando {count} cambio{plural}'),
('es', 'offlineSyncingChangesPlural', 's'),
('es', 'offlineViewDetails', 'Detalles'),
('es', 'offlinePendingChanges', 'Cambios pendientes'),
('es', 'offlinePendingChangesDescription', 'Tienes {count} cambio{plural} pendiente{plural} de sincronizar. Estos se enviarán al servidor cuando se restaure tu conexión.\n\nLas acciones en MatchMe no estarán disponibles hasta que se sincronicen.'),
('es', 'offlinePendingChangesPlural', 's'),
('es', 'offlineViewPendingDetails', 'Ver detalles')

ON CONFLICT (locale, key) DO UPDATE SET
value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO translations (locale, key, value) VALUES
-- Offline Indicator
('he', 'offlineIndicatorTitle', 'MatchMe אחוז מהרשת - הצגת נתונים שמורים'),
('he', 'offlineSnackbarMessage', 'MatchMe אחוז מהרשת - שימוש בנתונים שמורים'),

-- Offline Feature Dialogs
('he', 'offlineFeatureUnavailable', 'התכונה לא זמינה'),
('he', 'offlineFeatureRequiresConnection', 'התכונה הזו דורשת חיבור לאינטרנט.'),
('he', 'offlineSendMessageTitle', 'לא ניתן לשלוח הודעה בזמן הפרעה'),
('he', 'offlineSendMessageBody', 'ההודעה שלך נשמרה מקומית וכיוצא בכן תישלח כשתחזור לחיבור.'),
('he', 'offlineUpdateVisibilityTitle', 'לא ניתן לעדכן חשיפה בזמן הפרעה'),
('he', 'offlineUpdateVisibilityBody', 'שינוי החשיפה שלך נשמר מקומית וסוף סוף יתעדכן כשתחזור לחיבור.'),
('he', 'offlineUpdateProfileTitle', 'לא ניתן לעדכן פרופיל בזמן הפרעה'),
('he', 'offlineUpdateProfileBody', 'שינויי הפרופיל שלך נשמרו מקומית וסוף סוף יתעדכנו כשתחזור לחיבור.'),
('he', 'offlineUpdateGeneralTitle', 'לא ניתן לבצע שינויים בזמן הפרעה'),
('he', 'offlineUpdateGeneralBody', 'שינויים שלך נשמרו מקומית וסוף סוף יתעדכנו כשתחזור לחיבור.'),
('he', 'offlineEditMessageTitle', 'לא ניתן לערוך הודעה בזמן הפרעה'),
('he', 'offlineEditMessageBody', 'עריכת ההודעה שלך נשמרה מקומית וסוף סוף תתעדכן כשתחזור לחיבור.'),
('he', 'offlineDeleteMessageTitle', 'לא ניתן למחוק הודעה בזמן הפרעה'),
('he', 'offlineDeleteMessageBody', 'בקשת המחיקה שלך נשמרה מקומית וסוף סוף תתעדכן כשתחזור לחיבור.'),
('he', 'offlineReactToMessageTitle', 'לא ניתן להוסיף תגובה בזמן הפרעה'),
('he', 'offlineReactToMessageBody', 'התגובה שלך נשמרה מקומית וסוף סוף תתווסף כשתחזור לחיבור.'),
('he', 'offlineDeleteReactionTitle', 'לא ניתן להסיר תגובה בזמן הפרעה'),
('he', 'offlineDeleteReactionBody', 'הסרת התגובה שלך נשמרה מקומית וסוף סוף תתעדכן כשתחזור לחיבור.'),
('he', 'offlineCreateEventTitle', 'לא ניתן ליצור אירוע בזמן הפרעה'),
('he', 'offlineCreateEventBody', 'האירוע שלך נשמר מקומית וסוף סוף ייווצר כשתחזור לחיבור.'),
('he', 'offlineUpdateEventTitle', 'לא ניתן לעדכן אירוע בזמן הפרעה'),
('he', 'offlineUpdateEventBody', 'שינויי האירוע שלך נשמרו מקומית וסוף סוף יתעדכנו כשתחזור לחיבור.'),
('he', 'offlineDeleteEventTitle', 'לא ניתן למחוק אירוע בזמן הפרעה'),
('he', 'offlineDeleteEventBody', 'בקשת המחיקה שלך נשמרה מקומית וסוף סוף תתעדכן כשתחזור לחיבור.'),
('he', 'offlineJoinEventTitle', 'לא ניתן להצטרף לאירוע בזמן הפרעה'),
('he', 'offlineJoinEventBody', 'בקשת ההצטרפות שלך לאירוע נשמרה מקומית וסוף סוף תעובד כשתחזור לחיבור.'),
('he', 'offlineLeaveEventTitle', 'לא ניתן לעזוב אירוע בזמן הפרעה'),
('he', 'offlineLeaveEventBody', 'בקשת העזיבה שלך מהאירוע נשמרה מקומית וסוף סוף תעובד כשתחזור לחיבור.'),
('he', 'offlineUpdateLocationTitle', 'לא ניתן לעדכן מיקום בזמן הפרעה'),
('he', 'offlineUpdateLocationBody', 'עדכון המיקום שלך נשמר מקומית וסוף סוף יישלח כשתחזור לחיבור.'),
('he', 'offlineAddInvisibilityRuleTitle', 'לא ניתן להוסיף כלל אי ראות בזמן הפרעה'),
('he', 'offlineAddInvisibilityRuleBody', 'הכלל שלך נשמר מקומית וסוף סוף יתווסף כשתחזור לחיבור.'),
('he', 'offlineRemoveInvisibilityRuleTitle', 'לא ניתן להסיר כלל אי ראות בזמן הפרעה'),
('he', 'offlineRemoveInvisibilityRuleBody', 'הסרת הכלל שלך נשמרה מקומית וסוף סוף תעובד כשתחזור לחיבור.'),
('he', 'offlineToggleSharedEventTitle', 'לא ניתן לשנות הגדרת אירוע משותף בזמן הפרעה'),
('he', 'offlineToggleSharedEventBody', 'שינוי ההעדפה שלך נשמר מקומית וסוף סוף יתעדכן כשתחזור לחיבור.'),
('he', 'offlineToggleSharedMovementTitle', 'לא ניתן לשנות הגדרת תנועה משותפת בזמן הפרעה'),
('he', 'offlineToggleSharedMovementBody', 'שינוי ההעדפה שלך נשמר מקומית וסוף סוף יתעדכן כשתחזור לחיבור.'),
('he', 'offlineUpdateNotificationsTitle', 'לא ניתן לעדכן הגדרות התראות בזמן הפרעה'),
('he', 'offlineUpdateNotificationsBody', 'העדפות ההתראות שלך נשמרו מקומית וסוף סוף יתעדכנו כשתחזור לחיבור.'),
('he', 'offlineBlockUserTitle', 'לא ניתן לחסום משתמש בזמן הפרעה'),
('he', 'offlineBlockUserBody', 'החסימה שלך נשמרה מקומית וסוף סוף תעובד כשתחזור לחיבור.'),
('he', 'offlineUnblockUserTitle', 'לא ניתן לבטל חסימה של משתמש בזמן הפרעה'),
('he', 'offlineUnblockUserBody', 'בקשת ביטול החסימה שלך נשמרה מקומית וסוף סוף תעובד כשתחזור לחיבור.'),
('he', 'offlineReportUserTitle', 'לא ניתן לדווח על משתמש בזמן הפרעה'),
('he', 'offlineReportUserBody', 'הדוח שלך נשמר מקומית וסוף סוף יוגש כשתחזור לחיבור.'),

-- Offline Button Labels and Messages
('he', 'offlineCannotCompleteRequest', 'לא ניתן להשלים את הבקשה'),
('he', 'offlineFeatureRequiresConnectionDetailed', '{feature} דורש חיבור לאינטרנט. MatchMe אחוז מהרשת כעת.'),
('he', 'offlineOkButton', 'אישור'),
('he', 'offlineSendAnywayButton', 'שלח בכל זאת'),

-- Pending Mutations
('he', 'offlineSyncingChanges', 'סינכרון {count} שינוי{plural}'),
('he', 'offlineSyncingChangesPlural', 'ים'),
('he', 'offlineViewDetails', 'פרטים'),
('he', 'offlinePendingChanges', 'שינויים ממתינים'),
('he', 'offlinePendingChangesDescription', 'יש לך {count} שינוי{plural} ממתינ{plural} לסינכרון. אלה יישלחו לשרת כשחיבורך יוחזר.\n\nפעולות ב-MatchMe לא יהיו זמינות עד שאלה יסתנכרנו.'),
('he', 'offlinePendingChangesPlural', 'ים'),
('he', 'offlineViewPendingDetails', 'הצג פרטים'),

-- Offline Language Selection
('en', 'offlineLanguageUnavailableTitle', 'Language Not Downloaded'),
('en', 'offlineLanguageUnavailableMessage', 'To use this language, the app needs to download its translation texts. Please restore your internet connection and try again.'),
('es', 'offlineLanguageUnavailableTitle', 'Idioma No Descargado'),
('es', 'offlineLanguageUnavailableMessage', 'Para usar este idioma, la aplicación necesita descargar sus textos de traducción. Por favor, restaura tu conexión a Internet e intenta de nuevo.'),
('he', 'offlineLanguageUnavailableTitle', 'שפה לא הורדה'),
('he', 'offlineLanguageUnavailableMessage', 'כדי להשתמש בשפה זו, האפליקציה צריכה להוריד את טקסטי התרגום שלה. אנא שחזר את חיבור האינטרנט שלך ונסה שוב.')

ON CONFLICT (locale, key) DO UPDATE SET
value = EXCLUDED.value;
