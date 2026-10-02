BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncGoogleAuthRequired', 'Google Sign-In Required', 'en'),
  ('calendarSyncGoogleAuthRequiredMessage', 'To access your Google calendars, you need to sign in with your Google account.', 'en'),
  ('calendarSyncGoogleSignInCancelled', 'Sign-in was cancelled. Please try again.', 'en'),
  ('calendarSyncGoogleConfigError', 'Google Sign-In is not configured correctly for this app build. Please contact support.', 'en'),
  ('calendarSyncGoogleAuthTimeout', 'Google authentication timed out. Check your internet connection and try again.', 'en'),
  ('calendarSyncOutlookAuthTimeout', 'Outlook authentication timed out. Check your internet connection and try again.', 'en'),
  ('signIn', 'Sign In', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncGoogleAuthRequired', 'Se requiere iniciar sesión con Google', 'es'),
  ('calendarSyncGoogleAuthRequiredMessage', 'Para acceder a tus calendarios de Google, debes iniciar sesión con tu cuenta de Google.', 'es'),
  ('calendarSyncGoogleSignInCancelled', 'Se canceló el inicio de sesión. Inténtalo de nuevo.', 'es'),
  ('calendarSyncGoogleConfigError', 'El inicio de sesión de Google no está configurado correctamente para esta versión de la app. Contacta con soporte.', 'es'),
  ('calendarSyncGoogleAuthTimeout', 'La autenticación de Google ha agotado el tiempo de espera. Verifica tu conexión a Internet e inténtalo de nuevo.', 'es'),
  ('calendarSyncOutlookAuthTimeout', 'La autenticación de Outlook ha agotado el tiempo de espera. Verifica tu conexión a Internet e inténtalo de nuevo.', 'es'),
  ('signIn', 'Iniciar sesión', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

INSERT INTO translations (key, value, locale) VALUES
  ('calendarSyncGoogleAuthRequired', 'נדרשת התחברות ל-Google', 'he'),
  ('calendarSyncGoogleAuthRequiredMessage', 'כדי לגשת ליומני Google שלך, צריך להתחבר עם חשבון Google שלך.', 'he'),
  ('calendarSyncGoogleSignInCancelled', 'ההתחברות בוטלה. נסה/י שוב.', 'he'),
  ('calendarSyncGoogleConfigError', 'התחברות Google לא מוגדרת נכון בגרסה הזו של האפליקציה. יש לפנות לתמיכה.', 'he'),
  ('calendarSyncGoogleAuthTimeout', 'אימות Google פג. אנא בדוק/י את החיבור לאינטרנט ונסה/י שוב.', 'he'),
  ('calendarSyncOutlookAuthTimeout', 'אימות Outlook פג. אנא בדוק/י את החיבור לאינטרנט ונסה/י שוב.', 'he'),
  ('signIn', 'התחברות', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value;

COMMIT;
