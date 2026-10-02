-- Add error localization translations for user-friendly error messages
-- This script adds network errors and auth error translations for English, Spanish, and Hebrew
-- All user-facing errors should display these localized messages instead of raw exceptions

-- English translations
INSERT INTO translations (locale, key, value) VALUES
-- Network/Connectivity Errors
('en', 'networkErrorGeneric', 'A network error occurred. Please check your connection and try again.'),
('en', 'networkErrorTimeout', 'The request timed out. Please check your internet connection and try again.'),
('en', 'networkErrorNoInternet', 'No internet connection. Please check your network and try again.'),
('en', 'networkErrorConnectionFailed', 'Could not connect to the server. Please check your internet connection and try again.'),
('en', 'networkErrorSSLCertificate', 'A security error occurred. Please try again or contact support if the problem persists.'),

-- Additional Auth Errors
('en', 'authInvalidCode', 'The verification code you entered is invalid. Please try again.'),
('en', 'authCodeExpired', 'The verification code has expired. Please request a new one.'),
('en', 'authMFANotEnabled', '2-Factor authentication is not configured for your account.'),
('en', 'authMFARequired', 'Enter your verification code from your authenticator app to continue.'),
('en', 'authInvalidTOTP', 'The code you entered is invalid. Please try again.'),
('en', 'authSessionInvalid', 'Your session is invalid. Please sign in again.'),
('en', 'authSessionExpired', 'Your session has expired. Please sign in again.'),
('en', 'authRefreshTokenNotFound', 'Your session could not be renewed. Please sign in again.'),
('en', 'authRefreshTokenInvalid', 'Your session is no longer valid. Please sign in again.'),
('en', 'authRefreshTokenExpired', 'Your session has expired. Please sign in again.'),
('en', 'authUnauthorized', 'You are not authorized to perform this action.'),
('en', 'authOAuthInvalidState', 'An OAuth error occurred. Please try again.'),
('en', 'authOAuthAccessDenied', 'OAuth access was denied. Please try again or choose a different sign-in method.'),
('en', 'authOAuthAccountExists', 'An account with this email already exists. Please sign in or try another method.'),
('en', 'authOAuthFailed', 'Failed to sign in with this provider. Please try again.'),
('en', 'authOAuthCancelled', 'You cancelled the sign-in. Please try again if you''d like to continue.'),
('en', 'authRateLimitExceeded', 'Too many requests. Please wait a moment and try again.'),
('en', 'authServerError', 'A server error occurred. Please try again later.'),
('en', 'authUserNotFound', 'This account does not exist. Please sign up or try again.'),
('en', 'authPasswordWeak', 'Your password is too weak. It must contain uppercase, lowercase, numbers, and special characters.'),
('en', 'authEmailRejected', 'This email cannot be used. Please try a different email address.'),
('en', 'authDisposableEmailBlocked', 'Disposable or temporary email addresses are not allowed. Please use a permanent email.')
ON CONFLICT DO NOTHING;

-- Spanish translations
INSERT INTO translations (locale, key, value) VALUES
-- Network/Connectivity Errors
('es', 'networkErrorGeneric', 'Ocurrió un error de red. Por favor, verifica tu conexión e intenta de nuevo.'),
('es', 'networkErrorTimeout', 'La solicitud agotó el tiempo de espera. Por favor, verifica tu conexión a internet e intenta de nuevo.'),
('es', 'networkErrorNoInternet', 'Sin conexión a internet. Por favor, verifica tu red e intenta de nuevo.'),
('es', 'networkErrorConnectionFailed', 'No se pudo conectar al servidor. Por favor, verifica tu conexión a internet e intenta de nuevo.'),
('es', 'networkErrorSSLCertificate', 'Ocurrió un error de seguridad. Por favor, intenta de nuevo o contacta con soporte si el problema persiste.'),

-- Additional Auth Errors
('es', 'authInvalidCode', 'El código de verificación que ingresaste es inválido. Por favor, intenta de nuevo.'),
('es', 'authCodeExpired', 'El código de verificación ha expirado. Por favor, solicita uno nuevo.'),
('es', 'authMFANotEnabled', 'La autenticación de dos factores no está configurada para tu cuenta.'),
('es', 'authMFARequired', 'Ingresa tu código de verificación de la aplicación de autenticación para continuar.'),
('es', 'authInvalidTOTP', 'El código que ingresaste es inválido. Por favor, intenta de nuevo.'),
('es', 'authSessionInvalid', 'Tu sesión es inválida. Por favor, inicia sesión de nuevo.'),
('es', 'authSessionExpired', 'Tu sesión ha expirado. Por favor, inicia sesión de nuevo.'),
('es', 'authRefreshTokenNotFound', 'Tu sesión no se pudo renovar. Por favor, inicia sesión de nuevo.'),
('es', 'authRefreshTokenInvalid', 'Tu sesión ya no es válida. Por favor, inicia sesión de nuevo.'),
('es', 'authRefreshTokenExpired', 'Tu sesión ha expirado. Por favor, inicia sesión de nuevo.'),
('es', 'authUnauthorized', 'No estás autorizado para realizar esta acción.'),
('es', 'authOAuthInvalidState', 'Ocurrió un error de OAuth. Por favor, intenta de nuevo.'),
('es', 'authOAuthAccessDenied', 'El acceso de OAuth fue denegado. Por favor, intenta de nuevo o elige un método de inicio de sesión diferente.'),
('es', 'authOAuthAccountExists', 'Ya existe una cuenta con este correo electrónico. Por favor, inicia sesión o intenta otro método.'),
('es', 'authOAuthFailed', 'Error al iniciar sesión con este proveedor. Por favor, intenta de nuevo.'),
('es', 'authOAuthCancelled', 'Cancelaste el inicio de sesión. Por favor, intenta de nuevo si deseas continuar.'),
('es', 'authRateLimitExceeded', 'Demasiadas solicitudes. Por favor, espera un momento e intenta de nuevo.'),
('es', 'authServerError', 'Ocurrió un error del servidor. Por favor, intenta de nuevo más tarde.'),
('es', 'authUserNotFound', 'Esta cuenta no existe. Por favor, regístrate o intenta de nuevo.'),
('es', 'authPasswordWeak', 'Tu contraseña es demasiado débil. Debe contener mayúsculas, minúsculas, números y caracteres especiales.'),
('es', 'authEmailRejected', 'Este correo electrónico no se puede usar. Por favor, intenta con una dirección de correo diferente.'),
('es', 'authDisposableEmailBlocked', 'No se permiten direcciones de correo electrónico desechables o temporales. Por favor, usa un correo permanente.')
ON CONFLICT DO NOTHING;

-- Hebrew translations
INSERT INTO translations (locale, key, value) VALUES
-- Network/Connectivity Errors
('he', 'networkErrorGeneric', 'אירעה שגיאה ברשת. אנא בדוק את החיבור שלך ונסה שוב.'),
('he', 'networkErrorTimeout', 'קצב ההמתנה של הבקשה פג. אנא בדוק את חיבור האינטרנט שלך ונסה שוב.'),
('he', 'networkErrorNoInternet', 'אין חיבור לאינטרנט. אנא בדוק את הרשת שלך ונסה שוב.'),
('he', 'networkErrorConnectionFailed', 'לא ניתן התחבר לשרת. אנא בדוק את חיבור האינטרנט שלך ונסה שוב.'),
('he', 'networkErrorSSLCertificate', 'אירעה שגיאת אבטחה. אנא נסה שוב או צור קשר עם התמיכה אם הבעיה נמשכת.'),

-- Additional Auth Errors
('he', 'authInvalidCode', 'קוד האימות שהזנת אינו תקף. אנא נסה שוב.'),
('he', 'authCodeExpired', 'קוד האימות פג תוקף. אנא בקש קוד חדש.'),
('he', 'authMFANotEnabled', 'אימות דו-שלבי לא מוגדר לחשבון שלך.'),
('he', 'authMFARequired', 'הזן את קוד האימות שלך מאפליקציית האימות כדי להמשיך.'),
('he', 'authInvalidTOTP', 'הקוד שהזנת אינו תקף. אנא נסה שוב.'),
('he', 'authSessionInvalid', 'הפעילות שלך אינה תקפה. אנא היכנס שוב.'),
('he', 'authSessionExpired', 'הפעילות שלך פגה. אנא היכנס שוב.'),
('he', 'authRefreshTokenNotFound', 'לא ניתן לחדש את הפעילות שלך. אנא היכנס שוב.'),
('he', 'authRefreshTokenInvalid', 'הפעילות שלך כבר לא תקפה. אנא היכנס שוב.'),
('he', 'authRefreshTokenExpired', 'הפעילות שלך פגה. אנא היכנס שוב.'),
('he', 'authUnauthorized', 'אינך מורשה לבצע פעולה זו.'),
('he', 'authOAuthInvalidState', 'אירעה שגיאת OAuth. אנא נסה שוב.'),
('he', 'authOAuthAccessDenied', 'הגישה של OAuth נדחתה. אנא נסה שוב או בחר בשיטת כניסה אחרת.'),
('he', 'authOAuthAccountExists', 'חשבון עם כתובת דוא"ל זו קיים כבר. אנא היכנס או נסה שיטה אחרת.'),
('he', 'authOAuthFailed', 'הכניסה עם ספק זה נכשלה. אנא נסה שוב.'),
('he', 'authOAuthCancelled', 'ביטלת את ההכניסה. אנא נסה שוב אם ברצונך להמשיך.'),
('he', 'authRateLimitExceeded', 'יותר מדי בקשות. אנא חכה רגע ונסה שוב.'),
('he', 'authServerError', 'אירעה שגיאה בשרת. אנא נסה שוב מאוחר יותר.'),
('he', 'authUserNotFound', 'חשבון זה לא קיים. אנא הרשמ או נסה שוב.'),
('he', 'authPasswordWeak', 'הסיסמה שלך חלושה מדי. היא חייבת להכיל אותיות גדולות, קטנות, מספרים תווים מיוחדים.'),
('he', 'authEmailRejected', 'לא ניתן להשתמש בכתובת דוא"ל זו. אנא נסה בכתובת דוא"ל שונה.'),
('he', 'authDisposableEmailBlocked', 'כתובות דוא"ל שלעלית או זמניות אינן מותרות. אנא השתמש בחשבון דוא"ל קבוע.')
ON CONFLICT DO NOTHING;
