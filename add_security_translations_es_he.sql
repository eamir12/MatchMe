-- ============================================================================
-- MatchMe Translation Backfill Script - Security Settings & Authentication
-- ============================================================================
-- 
-- PURPOSE: Add missing Spanish (es) and Hebrew (he) translations for:
--   - Passkey settings (settingsPasskey*) - 25+ keys
--   - MFA/2FA settings (settingsMfa*) - 45+ keys
--   - Security hub (security*) - 25+ keys
--   - Total: 95+ critical security-related translation keys
--
-- EXECUTION NOTES:
--   - These keys are used in security_sign_in_screen.dart
--   - Fallback is English from locale_provider.dart if translations missing
--   - Test with Spanish (es) and Hebrew (he) locales after execution
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: PASSKEY SETTINGS TRANSLATIONS (25 keys)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
-- Spanish - Passkey Settings
('es', 'settingsPasskeyTitle', 'Claves de acceso', NOW(), NOW()),
('es', 'settingsPasskeyDescription', 'Usa autenticación biométrica o de dispositivo para acceso más seguro y rápido', NOW(), NOW()),
('es', 'settingsPasskeyReady', 'Soporte de Clave de Acceso Listo', NOW(), NOW()),
('es', 'settingsPasskeyStatusReady', 'Listo para agregar', NOW(), NOW()),
('es', 'settingsPasskeyStatusUnsupported', 'No compatible con este dispositivo', NOW(), NOW()),
('es', 'settingsPasskeyStatusSetupRequired', 'Se requiere configuración', NOW(), NOW()),
('es', 'settingsPasskeyCurrentSessionPasskey', 'Iniciaste sesión con una clave de acceso en este dispositivo', NOW(), NOW()),
('es', 'settingsPasskeyAddedForFutureSignIn', 'Clave de acceso agregada - puedes usarla para inicios de sesión futuros', NOW(), NOW()),
('es', 'settingsPasskeyStatusAddedThisSession', 'Clave de acceso agregada en esta sesión', NOW(), NOW()),
('es', 'settingsPasskeyAdded', 'Clave de acceso agregada con éxito', NOW(), NOW()),
('es', 'settingsPasskeyAddFailed', 'No se pudo agregar la clave de acceso', NOW(), NOW()),
('es', 'settingsPasskeyAlreadyRegistered', 'Esta clave de acceso ya está registrada en tu dispositivo. Puedes administrar tus claves de acceso en configuración.', NOW(), NOW()),
('es', 'settingsPasskeyRemove', 'Eliminar Clave de Acceso', NOW(), NOW()),
('es', 'settingsPasskeyRemoveDialogTitle', '¿Eliminar Clave de Acceso?', NOW(), NOW()),
('es', 'settingsPasskeyRemoveDialogMessage', 'Esto eliminará todas las claves de acceso registradas. Tendrás que usar tu contraseña u otro método de autenticación.', NOW(), NOW()),
('es', 'settingsPasskeyRemoveDialogWarning', 'Esta acción no se puede deshacer.', NOW(), NOW()),
('es', 'settingsPasskeyRemoveDialogCancel', 'Mantener Clave de Acceso', NOW(), NOW()),
('es', 'settingsPasskeyRemoveDialogConfirm', 'Eliminar Todas las Claves de Acceso', NOW(), NOW()),
('es', 'settingsPasskeyRemoved', 'Todas las claves de acceso eliminadas con éxito', NOW(), NOW()),
('es', 'settingsPasskeyRemoveFailed', 'No se pudo eliminar la clave de acceso', NOW(), NOW()),
('es', 'settingsPasskeyEnrollSuccess', 'Clave de acceso agregada con éxito', NOW(), NOW()),
('es', 'settingsPasskeyEnrollFailed', 'No se pudo agregar la clave de acceso', NOW(), NOW()),
('es', 'settingsPasskeyRemoveSuccess', 'Clave de acceso eliminada con éxito', NOW(), NOW()),
('es', 'settingsPasskeyRemoveConfirm', '¿Eliminar todas las claves de acceso de tu cuenta? Tendrás que usar otro método de inicio de sesión.',NOW(), NOW()),
('es', 'settingsPasskeyAdd', 'Agregar Clave de Acceso', NOW(), NOW()),

-- Hebrew - Passkey Settings
('he', 'settingsPasskeyTitle', 'מפתחות גישה', NOW(), NOW()),
('he', 'settingsPasskeyDescription', 'השתמש באימות ביומטרי או התקן לכניסה מהירה ובטוחה יותר', NOW(), NOW()),
('he', 'settingsPasskeyReady', 'תמיכת מפתח גישה מוכנה', NOW(), NOW()),
('he', 'settingsPasskeyStatusReady', 'מוכן להוספה', NOW(), NOW()),
('he', 'settingsPasskeyStatusUnsupported', 'לא נתמך בהתקן זה', NOW(), NOW()),
('he', 'settingsPasskeyStatusSetupRequired', 'נדרשת הגדרה', NOW(), NOW()),
('he', 'settingsPasskeyCurrentSessionPasskey', 'התחברת עם מפתח גישה בהתקן זה', NOW(), NOW()),
('he', 'settingsPasskeyAddedForFutureSignIn', 'מפתח גישה נוסף - אתה יכול להשתמש בו בחיבורים עתידיים', NOW(), NOW()),
('he', 'settingsPasskeyStatusAddedThisSession', 'מפתח גישה נוסף בהפעלה זו', NOW(), NOW()),
('he', 'settingsPasskeyAdded', 'מפתח גישה נוסף בהצלחה', NOW(), NOW()),
('he', 'settingsPasskeyAddFailed', 'הוספת מפתח גישה נכשלה', NOW(), NOW()),
('he', 'settingsPasskeyAlreadyRegistered', 'מפתח גישה זה כבר רשום בהתקן שלך. אתה יכול לנהל את מפתחות הגישה שלך בהגדרות.', NOW(), NOW()),
('he', 'settingsPasskeyRemove', 'הסר מפתח גישה', NOW(), NOW()),
('he', 'settingsPasskeyRemoveDialogTitle', 'להסיר מפתח גישה?', NOW(), NOW()),
('he', 'settingsPasskeyRemoveDialogMessage', 'זה יסיר את כל מפתחות הגישה הרשומים. תצטרך להשתמש בסיסמה או בשיטת אימות אחרת.', NOW(), NOW()),
('he', 'settingsPasskeyRemoveDialogWarning', 'לא ניתן לבטל פעולה זו.', NOW(), NOW()),
('he', 'settingsPasskeyRemoveDialogCancel', 'שמור מפתח גישה', NOW(), NOW()),
('he', 'settingsPasskeyRemoveDialogConfirm', 'הסר את כל מפתחות הגישה', NOW(), NOW()),
('he', 'settingsPasskeyRemoved', 'כל מפתחות הגישה הוסרו בהצלחה', NOW(), NOW()),
('he', 'settingsPasskeyRemoveFailed', 'הסרת מפתח גישה נכשלה', NOW(), NOW()),
('he', 'settingsPasskeyEnrollSuccess', 'מפתח גישה נוסף בהצלחה', NOW(), NOW()),
('he', 'settingsPasskeyEnrollFailed', 'הוספת מפתח גישה נכשלה', NOW(), NOW()),
('he', 'settingsPasskeyRemoveSuccess', 'מפתח גישה הוסר בהצלחה', NOW(), NOW()),
('he', 'settingsPasskeyRemoveConfirm', 'להסיר את כל מפתחות הגישה מחשבונך? תצטרך להשתמש בשיטת כניסה אחרת.', NOW(), NOW()),
('he', 'settingsPasskeyAdd', 'הוסף מפתח גישה', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: MFA/2FA SETTINGS TRANSLATIONS (45 keys)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
-- Spanish - MFA Settings
('es', 'settingsMfaTitle', 'Autenticación de dos factores', NOW(), NOW()),
('es', 'settingsMfaDescription', 'Agrega una capa extra de seguridad a tu cuenta con autenticación de dos factores', NOW(), NOW()),
('es', 'settingsMfaEnabled', 'Habilitado', NOW(), NOW()),
('es', 'settingsMfaDisabled', 'Deshabilitado', NOW(), NOW()),
('es', 'settingsMfaEnable', 'Habilitar MFA', NOW(), NOW()),
('es', 'settingsMfaDisable', 'Deshabilitar MFA', NOW(), NOW()),
('es', 'settingsMfaDisableConfirm', '¿Seguro que quieres deshabilitar la autenticación de dos factores? Esto hará que tu cuenta sea menos segura.', NOW(), NOW()),
('es', 'settingsMfaSetupTitle', 'Configurar Autenticación de Dos Factores', NOW(), NOW()),
('es', 'settingsMfaSetupBody', 'Escanea este código QR con tu aplicación autenticadora para configurar MFA', NOW(), NOW()),
('es', 'settingsMfaQrTitle', 'Escanear con Autenticador', NOW(), NOW()),
('es', 'settingsMfaQrBody', 'Usa una aplicación autenticadora como Google Authenticator, Authy o Microsoft Authenticator', NOW(), NOW()),
('es', 'settingsMfaManualEntryTitle', 'Entrada Manual', NOW(), NOW()),
('es', 'settingsMfaManualEntryBody', 'Si no puedes escanear el código QR, ingresa esta clave manualmente en tu aplicación autenticadora:', NOW(), NOW()),
('es', 'settingsMfaSecret', 'Clave Secreta', NOW(), NOW()),
('es', 'settingsMfaCopySecret', 'Copiar Clave Secreta', NOW(), NOW()),
('es', 'settingsMfaCopied', 'Clave secreta copiada al portapapeles', NOW(), NOW()),
('es', 'settingsMfaCode', 'Código de Autenticación', NOW(), NOW()),
('es', 'settingsMfaEnterCode', 'Ingresa el código de 6 dígitos de tu aplicación autenticadora', NOW(), NOW()),
('es', 'settingsMfaVerify', 'Verificar', NOW(), NOW()),
('es', 'settingsMfaVerifySensitiveAction', 'Verifica Tu Identidad', NOW(), NOW()),
('es', 'settingsMfaVerifySensitiveActionBody', 'Ingresa el código de 6 dígitos de tu aplicación autenticadora para confirmar esta acción', NOW(), NOW()),
('es', 'settingsMfaVerificationSuccess', 'MFA verificado con éxito', NOW(), NOW()),
('es', 'settingsMfaVerificationFailed', 'Falló la verificación de MFA. Por favor intenta de nuevo.', NOW(), NOW()),
('es', 'settingsMfaEnrollmentSuccess', 'Autenticación de dos factores habilitada con éxito', NOW(), NOW()),
('es', 'settingsMfaEnrollmentFailed', 'No se pudo habilitar la autenticación de dos factores', NOW(), NOW()),
('es', 'settingsMfaDisableFailed', 'No se pudo deshabilitar la autenticación de dos factores', NOW(), NOW()),
('es', 'settingsMfaDisableSuccess', 'Autenticación de dos factores deshabilitada', NOW(), NOW()),
('es', 'settingsMfaCurrentSessionVerified', 'Sesión actual verificada', NOW(), NOW()),
('es', 'settingsMfaCurrentSessionNotVerified', 'Sesión actual no verificada', NOW(), NOW()),
('es', 'settingsMfaRecoveryCodeTitle', 'Códigos de Recuperación', NOW(), NOW()),
('es', 'settingsMfaRecoveryCodeBody', 'Guarda estos códigos en un lugar seguro. Úsalos si pierdes acceso a tu aplicación autenticadora.', NOW(), NOW()),
('es', 'settingsMfaRecoveryCodeEnter', 'Ingresa código de recuperación', NOW(), NOW()),
('es', 'settingsMfaRecoveryCodesCopy', 'Copiar Códigos de Recuperación', NOW(), NOW()),
('es', 'settingsMfaRecoveryCodesCopied', 'Códigos de recuperación copiados al portapapeles', NOW(), NOW()),
('es', 'settingsMfaRecoveryCodesGenerate', 'Generar Nuevos Códigos', NOW(), NOW()),
('es', 'settingsMfaRecoveryCodesRegenerate', 'Regenerar Códigos de Recuperación', NOW(), NOW()),
('es', 'settingsMfaRecoveryCodesRegenerateConfirm', 'Regenerar nuevos códigos de recuperación invalidará tus códigos antiguos. ¿Continuar?', NOW(), NOW()),
('es', 'settingsMfaRecoveryCodesDialogTitle', 'Códigos de Recuperación', NOW(), NOW()),
('es', 'settingsMfaRecoveryCodesMissing', 'No hay códigos de recuperación disponibles', NOW(), NOW()),
('es', 'settingsMfaRecoveryCodesGenerateFailed', 'No se pudo generar códigos de recuperación', NOW(), NOW()),
('es', 'settingsMfaEmailCode', 'Código de Correo', NOW(), NOW()),
('es', 'settingsMfaEmailCodeEnter', 'Revisa tu correo para un código de verificación', NOW(), NOW()),
('es', 'settingsMfaEmailCodeResend', 'Reenviar Código', NOW(), NOW()),
('es', 'settingsMfaEmailCodeSend', 'Enviar Código de Correo', NOW(), NOW()),
('es', 'settingsMfaEmailCodeSendFailed', 'No se pudo enviar el código de correo', NOW(), NOW()),
('es', 'settingsMfaOpenAuthenticatorFailed', 'No se pudo abrir la aplicación autenticadora', NOW(), NOW()),
('es', 'settingsMfaSecretMissing', 'No se pudo recuperar el secreto del autenticador', NOW(), NOW()),
('es', 'settingsMfaInitializing', 'Configurando aplicación autenticadora...', NOW(), NOW()),
('es', 'settingsMfaSetupInstruction', 'Escanea el código QR con tu app autenticadora, o ingresa el código manualmente', NOW(), NOW()),
('es', 'settingsMfaCodeInvalid', 'Código inválido. Por favor intenta de nuevo.', NOW(), NOW()),
('es', 'settingsMfaChallengeTitle', 'Verificar con 2FA', NOW(), NOW()),
('es', 'settingsMfaChallengeBody', 'Ingresa tu código de autenticación de 6 dígitos', NOW(), NOW()),
('es', 'settingsMfaChallengeInvalid', 'Código inválido. Por favor intenta de nuevo.', NOW(), NOW()),
('es', 'settingsMfaChallengeFailed', 'Falló la verificación. Por favor intenta de nuevo.', NOW(), NOW()),
('es', 'settingsMfaChallengeNotVerified', 'Falló la verificación', NOW(), NOW()),
('es', 'settingsMfaNotEnabled', 'Autenticación de dos factores no está habilitada', NOW(), NOW()),
('es', 'settingsMfaUpdate', 'Actualizar MFA', NOW(), NOW()),

-- Hebrew - MFA Settings
('he', 'settingsMfaTitle', 'אימות דו-גורמי', NOW(), NOW()),
('he', 'settingsMfaDescription', 'הוסף שכבת אבטחה נוספת לחשבונך עם אימות דו-גורמי', NOW(), NOW()),
('he', 'settingsMfaEnabled', 'מופעל', NOW(), NOW()),
('he', 'settingsMfaDisabled', 'מושבת', NOW(), NOW()),
('he', 'settingsMfaEnable', 'הפעל MFA', NOW(), NOW()),
('he', 'settingsMfaDisable', 'השבת MFA', NOW(), NOW()),
('he', 'settingsMfaDisableConfirm', 'האם אתה בטוח שברצונך להשבית אימות דו-גורמי? זה יהפוך את החשבון שלך לפחות מאובטח.', NOW(), NOW()),
('he', 'settingsMfaSetupTitle', 'הגדר אימות דו-גורמי', NOW(), NOW()),
('he', 'settingsMfaSetupBody', 'סרוק קוד QR זה עם אפליקציית המאמת שלך כדי להגדיר MFA', NOW(), NOW()),
('he', 'settingsMfaQrTitle', 'סרוק עם אימות', NOW(), NOW()),
('he', 'settingsMfaQrBody', 'השתמש באפליקציית אימות כמו Google Authenticator, Authy או Microsoft Authenticator', NOW(), NOW()),
('he', 'settingsMfaManualEntryTitle', 'הזנה ידנית', NOW(), NOW()),
('he', 'settingsMfaManualEntryBody', 'אם אתה לא יכול לסרוק את קוד ה-QR, הזן את המפתח הזה ידנית באפליקציית המאמת שלך:', NOW(), NOW()),
('he', 'settingsMfaSecret', 'מפתח סודי', NOW(), NOW()),
('he', 'settingsMfaCopySecret', 'העתק מפתח סודי', NOW(), NOW()),
('he', 'settingsMfaCopied', 'המפתח הסודי הועתק ללוח', NOW(), NOW()),
('he', 'settingsMfaCode', 'קוד אימות', NOW(), NOW()),
('he', 'settingsMfaEnterCode', 'הזן את קוד 6 הספרות מאפליקציית המאמת שלך', NOW(), NOW()),
('he', 'settingsMfaVerify', 'verify', NOW(), NOW()),
('he', 'settingsMfaVerifySensitiveAction', 'אמת את זהותך', NOW(), NOW()),
('he', 'settingsMfaVerifySensitiveActionBody', 'הזן את קוד 6 הספרות מאפליקציית המאמת שלך כדי לאשר פעולה זו', NOW(), NOW()),
('he', 'settingsMfaVerificationSuccess', 'MFA אומת בהצלחה', NOW(), NOW()),
('he', 'settingsMfaVerificationFailed', 'אימות MFA נכשל. אנא נסה שוב.', NOW(), NOW()),
('he', 'settingsMfaEnrollmentSuccess', 'אימות דו-גורמי הופעל בהצלחה', NOW(), NOW()),
('he', 'settingsMfaEnrollmentFailed', 'הפעלת אימות דו-גורמי נכשלה', NOW(), NOW()),
('he', 'settingsMfaDisableFailed', 'השבתת אימות דו-גורמי נכשלה', NOW(), NOW()),
('he', 'settingsMfaDisableSuccess', 'אימות דו-גורמי מושבת', NOW(), NOW()),
('he', 'settingsMfaCurrentSessionVerified', 'הפעלה הנוכחית אומתה', NOW(), NOW()),
('he', 'settingsMfaCurrentSessionNotVerified', 'הפעלה הנוכחית לא אומתה', NOW(), NOW()),
('he', 'settingsMfaRecoveryCodeTitle', 'קודי התאוששות', NOW(), NOW()),
('he', 'settingsMfaRecoveryCodeBody', 'שמור את הקודים הללו במקום בטוח. השתמש בהם אם אתה מאבד גישה לאפליקציית המאמת שלך.', NOW(), NOW()),
('he', 'settingsMfaRecoveryCodeEnter', 'הזן קוד התאוששות', NOW(), NOW()),
('he', 'settingsMfaRecoveryCodesCopy', 'העתק קודי התאוששות', NOW(), NOW()),
('he', 'settingsMfaRecoveryCodesCopied', 'קודי התאוששות הועתקו ללוח', NOW(), NOW()),
('he', 'settingsMfaRecoveryCodesGenerate', 'צור קודים חדשים', NOW(), NOW()),
('he', 'settingsMfaRecoveryCodesRegenerate', 'צור מחדש קודי התאוששות', NOW(), NOW()),
('he', 'settingsMfaRecoveryCodesRegenerateConfirm', 'יצירת קודי התאוששות חדשים תבטל את הקודים הישנים שלך. להמשיך?', NOW(), NOW()),
('he', 'settingsMfaRecoveryCodesDialogTitle', 'קודי התאוששות', NOW(), NOW()),
('he', 'settingsMfaRecoveryCodesMissing', 'אין קודי התאוששות זמינים', NOW(), NOW()),
('he', 'settingsMfaRecoveryCodesGenerateFailed', 'יצירת קודי התאוששות נכשלה', NOW(), NOW()),
('he', 'settingsMfaEmailCode', 'קוד דוא"ל', NOW(), NOW()),
('he', 'settingsMfaEmailCodeEnter', 'בדוק את הדוא"ל שלך לקוד אימות', NOW(), NOW()),
('he', 'settingsMfaEmailCodeResend', 'שלח שוב קוד', NOW(), NOW()),
('he', 'settingsMfaEmailCodeSend', 'שלח קוד דוא"ל', NOW(), NOW()),
('he', 'settingsMfaEmailCodeSendFailed', 'הצגת קוד דוא"ל נכשלה', NOW(), NOW()),
('he', 'settingsMfaOpenAuthenticatorFailed', 'לא היה ניתן לפתוח אפליקציית מאמת', NOW(), NOW()),
('he', 'settingsMfaSecretMissing', 'לא ניתן היה לאחזר את הסוד של המאמת', NOW(), NOW()),
('he', 'settingsMfaInitializing', 'הגדרת אפליקציית מאמת...', NOW(), NOW()),
('he', 'settingsMfaSetupInstruction', 'סרוק את קוד ה-QR עם אפליקציית המאמת שלך, או הזן את הקוד ידנית', NOW(), NOW()),
('he', 'settingsMfaCodeInvalid', 'קוד לא חוקי. אנא נסה שוב.', NOW(), NOW()),
('he', 'settingsMfaChallengeTitle', 'אמת עם 2FA', NOW(), NOW()),
('he', 'settingsMfaChallengeBody', 'הזן את קוד האימות של 6 הספרות שלך', NOW(), NOW()),
('he', 'settingsMfaChallengeInvalid', 'קוד לא חוקי. אנא נסה שוב.', NOW(), NOW()),
('he', 'settingsMfaChallengeFailed', 'אימות נכשל. אנא נסה שוב.', NOW(), NOW()),
('he', 'settingsMfaChallengeNotVerified', 'אימות נכשל', NOW(), NOW()),
('he', 'settingsMfaNotEnabled', 'אימות דו-גורמי אינו מופעל', NOW(), NOW()),
('he', 'settingsMfaUpdate', 'עדכן MFA', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: SECURITY HUB TRANSLATIONS (25 keys)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
-- Spanish - Security Hub
('es', 'securitySignInHubTitle', 'Seguridad', NOW(), NOW()),
('es', 'securitySignInHubDescription', 'Administra la seguridad de tu cuenta y tus métodos de inicio de sesión', NOW(), NOW()),
('es', 'securityCurrentSessionTitle', 'Tu Sesión Actual', NOW(), NOW()),
('es', 'securityHowYouSignedIn', 'Cómo iniciaste sesión:', NOW(), NOW()),
('es', 'securitySessionStarted', 'Sesión iniciada:', NOW(), NOW()),
('es', 'securityDeviceInfo', 'Información del dispositivo', NOW(), NOW()),
('es', 'securitySignInMethodsTitle', 'Métodos de Inicio de Sesión', NOW(), NOW()),
('es', 'securitySignInMethodsDescription', 'Administra cómo inicias sesión en tu cuenta', NOW(), NOW()),
('es', 'securityMethodConnected', 'Conectado', NOW(), NOW()),
('es', 'securityMethodNotConnected', 'No conectado', NOW(), NOW()),
('es', 'securityMethodLastChanged', 'Última vez modificado:', NOW(), NOW()),
('es', 'securityStatusSummarySecure', 'Tu cuenta es segura', NOW(), NOW()),
('es', 'securityStatusSummaryWarning', 'Tu cuenta podría ser más segura', NOW(), NOW()),
('es', 'securityStatusSummarySetupPasskey', 'Configura una clave de acceso para acceso más seguro y rápido', NOW(), NOW()),
('es', 'securityStatusSummaryEnable2FA', 'Habilita autenticación de dos factores para protección adicional', NOW(), NOW()),
('es', 'securityTwoFactorTitle', 'Autenticación de Dos Factores', NOW(), NOW()),
('es', 'securityTwoFactorDescription', 'Paso de verificación adicional opcional para acciones sensibles', NOW(), NOW()),
('es', 'securityActiveSessions', 'Sesiones Activas', NOW(), NOW()),
('es', 'securityActiveSessionsDescription', 'Ve y administra tus dispositivos con sesión iniciada', NOW(), NOW()),
('es', 'securityCurrentDevice', 'Dispositivo actual', NOW(), NOW()),
('es', 'securityShowAllDevices', 'Mostrar todos los dispositivos', NOW(), NOW()),
('es', 'securityRevokeOtherSessions', 'Cierra sesión en otros dispositivos', NOW(), NOW()),
('es', 'securityRevokeAllSessions', 'Cierra sesión en todas partes', NOW(), NOW()),
('es', 'securityPasswordSection', 'Contraseña', NOW(), NOW()),
('es', 'securityPasswordDescription', 'Restablece tu contraseña para reforzar la seguridad de tu cuenta', NOW(), NOW()),
('es', 'securityPasswordLastChanged', 'Última modificación: {date}', NOW(), NOW()),
('es', 'securityPasswordNeverChanged', 'Nunca modificada', NOW(), NOW()),
('es', 'securityContextHelpWhatIsPasskey', 'Una clave de acceso es una alternativa segura a las contraseñas usando biometría o PIN de tu dispositivo', NOW(), NOW()),
('es', 'securityContextHelpWhy2FA', 'La autenticación de dos factores agrega un paso de verificación adicional para proteger tu cuenta', NOW(), NOW()),
('es', 'securityContextHelpWhyMultiplePasskeys', 'Múltiples claves de acceso te permiten iniciar sesión desde diferentes dispositivos sin almacenar contraseñas', NOW(), NOW()),

-- Hebrew - Security Hub
('he', 'securitySignInHubTitle', 'אבטחה', NOW(), NOW()),
('he', 'securitySignInHubDescription', 'נהל את אבטחת החשבון שלך ושיטות התחברות שלך', NOW(), NOW()),
('he', 'securityCurrentSessionTitle', 'ההפעלה הנוכחית שלך', NOW(), NOW()),
('he', 'securityHowYouSignedIn', 'כך התחברת:', NOW(), NOW()),
('he', 'securitySessionStarted', 'הפעלה התחילה:', NOW(), NOW()),
('he', 'securityDeviceInfo', 'מידע התקן', NOW(), NOW()),
('he', 'securitySignInMethodsTitle', 'שיטות התחברות', NOW(), NOW()),
('he', 'securitySignInMethodsDescription', 'נהל כיצד אתה מתחבר לחשבון שלך', NOW(), NOW()),
('he', 'securityMethodConnected', 'מחובר', NOW(), NOW()),
('he', 'securityMethodNotConnected', 'לא מחובר', NOW(), NOW()),
('he', 'securityMethodLastChanged', 'נשתנה לאחרונה:', NOW(), NOW()),
('he', 'securityStatusSummarySecure', 'החשבון שלך בטוח', NOW(), NOW()),
('he', 'securityStatusSummaryWarning', 'החשבון שלך יכול להיות בטוח יותר', NOW(), NOW()),
('he', 'securityStatusSummarySetupPasskey', 'הגדר מפתח גישה להתחברות מהירה וטוחה יותר', NOW(), NOW()),
('he', 'securityStatusSummaryEnable2FA', 'הפעל אימות דו-גורמי להגנה נוספת', NOW(), NOW()),
('he', 'securityTwoFactorTitle', 'אימות דו-גורמי', NOW(), NOW()),
('he', 'securityTwoFactorDescription', 'שלב אימות נוסף אופציוני עבור פעולות רגישות', NOW(), NOW()),
('he', 'securityActiveSessions', 'הפעלות פעילות', NOW(), NOW()),
('he', 'securityActiveSessionsDescription', 'צפה בהתקנים שלך שיש להם התחברות פעילה ונהל אותם', NOW(), NOW()),
('he', 'securityCurrentDevice', 'התקן נוכחי', NOW(), NOW()),
('he', 'securityShowAllDevices', 'הצג את כל ההתקנים', NOW(), NOW()),
('he', 'securityRevokeOtherSessions', 'התחבר מהתקנים אחרים', NOW(), NOW()),
('he', 'securityRevokeAllSessions', 'התחבר מכל מקום', NOW(), NOW()),
('he', 'securityPasswordSection', 'סיסמה', NOW(), NOW()),
('he', 'securityPasswordDescription', 'אפס את סיסמתך כדי לחזק את האבטחה של החשבון שלך', NOW(), NOW()),
('he', 'securityPasswordLastChanged', 'נשתנה לאחרונה: {date}', NOW(), NOW()),
('he', 'securityPasswordNeverChanged', 'לעולם לא שונתה', NOW(), NOW()),
('he', 'securityContextHelpWhatIsPasskey', 'מפתח גישה הוא חלופה בטוחה לסיסמאות באמצעות ביומטריקה או PIN של ההתקן שלך', NOW(), NOW()),
('he', 'securityContextHelpWhy2FA', 'אימות דו-גורמי מוסיף שלב אימות נוסף להגנה על החשבון שלך', NOW(), NOW()),
('he', 'securityContextHelpWhyMultiplePasskeys', 'מפתחות גישה מרובים מאפשרים לך להתחבר מהתקנים שונים ללא אחסון סיסמאות', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 4: ADDITIONAL SECURITY-RELATED SETTINGS (10 keys)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
-- Spanish - Additional Settings
('es', 'settingsChangePassword', 'Cambiar Contraseña', NOW(), NOW()),
('es', 'settingsPasswordReauthBody', 'Ingresa tu nueva contraseña', NOW(), NOW()),
('es', 'settingsPasswordChanged', 'Contraseña cambiada con éxito', NOW(), NOW()),
('es', 'settingsPasswordChangeFailed', 'No se pudo cambiar la contraseña', NOW(), NOW()),
('es', 'settingsNewPassword', 'Nueva Contraseña', NOW(), NOW()),
('es', 'settingsConfirmNewPassword', 'Confirmar Cambio de Contraseña', NOW(), NOW()),
('es', 'settingsPasswordMismatch', 'Las contraseñas no coinciden', NOW(), NOW()),
('es', 'settingsCurrentPassword', 'Contraseña Actual', NOW(), NOW()),
('es', 'settingsPasswordReauthSentGeneric', 'Se envió un código de verificación a tu correo', NOW(), NOW()),
('es', 'authConfirmPassword', 'Confirmar Contraseña', NOW(), NOW()),

-- Hebrew - Additional Settings
('he', 'settingsChangePassword', 'שנה סיסמה', NOW(), NOW()),
('he', 'settingsPasswordReauthBody', 'הזן את הסיסמה החדשה שלך', NOW(), NOW()),
('he', 'settingsPasswordChanged', 'הסיסמה שונתה בהצלחה', NOW(), NOW()),
('he', 'settingsPasswordChangeFailed', 'שינוי הסיסמה נכשל', NOW(), NOW()),
('he', 'settingsNewPassword', 'סיסמה חדשה', NOW(), NOW()),
('he', 'settingsConfirmNewPassword', 'אשר שינוי סיסמה', NOW(), NOW()),
('he', 'settingsPasswordMismatch', 'הסיסמאות אינן תואמות', NOW(), NOW()),
('he', 'settingsCurrentPassword', 'סיסמה נוכחית', NOW(), NOW()),
('he', 'settingsPasswordReauthSentGeneric', 'קוד אימות נשלח לדוא"ל שלך', NOW(), NOW()),
('he', 'authConfirmPassword', 'אשר סיסמה', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- VERIFICATION QUERY - Run after insertion to verify coverage
-- ============================================================================
-- SELECT locale, COUNT(*) as translation_count FROM translations 
-- WHERE locale IN ('es', 'he') AND (
--   key LIKE 'settings%' OR 
--   key LIKE 'security%' OR 
--   key LIKE 'auth%'
-- ) GROUP BY locale;

-- ============================================================================
-- END OF SCRIPT
-- ============================================================================
