-- User-facing copy: units, counts and example hints spelled out in full.
--
-- The app must not show abbreviations. The Dart generators were changed first
-- (durations now go through formatDurationParts, distances through
-- formatDistance, counts through LocalizationState.formatCount, so the words
-- come from the plural unit rows instead of a hard-coded "5m"/"3 km"/"12k"),
-- and this migration brings the stored copy in line with them:
--
--   * units written as a letter plus a geresh — שנ׳ דק׳ שע׳ ק״מ מ׳ — become
--     שניות דקות שעות קילומטרים מטרים, and the Latin ones (s, m, h, km, min,
--     23h, 15m, 1h) become their full words in English and Spanish;
--   * "~" and "Approx/aprox." become "about"/"Approximately"/"aproximadamente",
--     "e.g."/"p. ej." become "For example:"/"Por ejemplo:", "min"/"mín" as a
--     stand-alone label becomes "minimum"/"mínimo", "n.º"/"#" disappears from
--     the location counter, and "SAT"/"SUN"/"א׳" become day names (the
--     onboarding demo rows themselves ship in 20262213000000, because the
--     onboarding parity check only reads *onboarding*-named migrations);
--   * the Hebrew דוא״ל / דוא"ל rows are written as דואר אלקטרוני, with the
--     definite article re-agreed (הדוא״ל הזו -> כתובת הדואר האלקטרוני הזו), and
--     סה״כ / סה"כ / ע"י become בסך הכול / על ידי.
--
-- Rows whose placeholder NAME changed cannot be edited in place: an installed
-- build fills the token it knows, so a row renamed to {duration} would render
-- the literal "{duration}" there. Those strings therefore move to new keys
-- (meetupBeaconEndsIn, meetupWalkDuration, meetupDistanceAway, meetupSpotMeAgo)
-- and their old rows are deleted at the bottom, which drops an older build back
-- onto its own bundled copy instead of showing a raw token.
--
-- Left alone, because they are initialisms rather than abbreviated words and
-- need a product ruling: AM/PM, GPS, URL, FCM, MFA, GB, Wi-Fi, HR, A–Z, and the
-- single-letter user labels (משתמש א׳/ב׳). Transliterations that use the geresh
-- as a sound mark — צ׳אט, אינצ׳, באצ׳טה, בז׳, ג׳אז — are not abbreviations and
-- stay.

-- Meet up: durations, distances and the new keys the client now reads.
INSERT INTO public.translations (locale, key, value) VALUES
('en', 'meetupBeaconEndsIn', 'Turns off in {duration}'),
('es', 'meetupBeaconEndsIn', 'Se apaga en {duration}'),
('he', 'meetupBeaconEndsIn', 'יכבה בעוד {duration}'),
('en', 'meetupWalkDuration', '{duration} on foot'),
('es', 'meetupWalkDuration', '{duration} a pie'),
('he', 'meetupWalkDuration', 'הליכה של {duration}'),
('en', 'meetupDistanceAway', '{distance} away'),
('es', 'meetupDistanceAway', 'A {distance}'),
('he', 'meetupDistanceAway', '{distance} מכאן'),
('en', 'meetupSpotMeAgo', '{duration} ago'),
('es', 'meetupSpotMeAgo', 'hace {duration}'),
('he', 'meetupSpotMeAgo', 'לפני {duration}'),
('en', 'meetupCustomPlaceHint', 'For example: Outside the corner bakery'),
('es', 'meetupCustomPlaceHint', 'Por ejemplo: frente a la panadería de la esquina'),
('en', 'meetupEventZoneCustomHint', 'For example: Zone C bar'),
('es', 'meetupEventZoneCustomHint', 'Por ejemplo: bar de la zona C'),
('en', 'meetupSpotMeNoteHint', 'For example: I am by the north entrance'),
('es', 'meetupSpotMeNoteHint', 'Por ejemplo: estoy junto a la entrada norte')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Counts and accuracy: no tilde, no "approx", and the number agrees with the
-- noun in every language.
INSERT INTO public.translations (locale, key, value) VALUES
('en', 'mapApproxUsersHere', 'About {count} users here'),
('es', 'mapApproxUsersHere', 'Aproximadamente {count} usuarios aquí'),
('he', 'mapApproxUsersHere', 'כאן בערך {count} משתמשים'),
('en', 'mapApproxUsersHere_one', 'About {count} user here'),
('es', 'mapApproxUsersHere_one', 'Aproximadamente {count} usuario aquí'),
('he', 'mapApproxUsersHere_one', 'כאן בערך משתמש אחד'),
('he', 'mapApproxUsersHere_two', 'כאן בערך שני משתמשים'),
('en', 'mapShowingApproxUsers', 'Showing about {count} users'),
('es', 'mapShowingApproxUsers', 'Mostrando aproximadamente {count} usuarios'),
('en', 'mapShowingApproxUsers_one', 'Showing about {count} user'),
('es', 'mapShowingApproxUsers_one', 'Mostrando aproximadamente {count} usuario'),
('he', 'mapShowingApproxUsers_one', 'מציג/ה בערך משתמש אחד'),
('he', 'mapShowingApproxUsers_two', 'מציג/ה בערך שני משתמשים'),
('en', 'settingsAccuracyMeters', 'Accuracy: about {meters} meters'),
('es', 'settingsAccuracyMeters', 'Precisión: aproximadamente {meters} metros'),
('he', 'settingsAccuracyMeters', 'דיוק: בערך {meters} מטרים'),
('en', 'settingsAccuracyMeters_one', 'Accuracy: about {meters} meter'),
('es', 'settingsAccuracyMeters_one', 'Precisión: aproximadamente {meters} metro'),
('he', 'settingsAccuracyMeters_one', 'דיוק: בערך {meters} מטר'),
('he', 'settingsAccuracyMeters_two', 'דיוק: בערך שני מטרים')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Distance units: the same words the Nearby Map, the scale bar and the meet-up
-- cards now all take from these rows. The Hebrew dual spells out "שני/שתי"
-- rather than putting the digit next to a singular noun, which is what the
-- shipped *_two rows did.
INSERT INTO public.translations (locale, key, value) VALUES
('en', 'distanceInKilometers', '{count} kilometers'),
('en', 'distanceInKilometers_one', '{count} kilometer'),
('he', 'distanceInKilometers', '{count} קילומטרים'),
('he', 'distanceInKilometers_one', '{count} קילומטר'),
('he', 'distanceInKilometers_two', 'שני קילומטרים'),
('he', 'distanceInMeters_two', 'שני מטרים'),
('he', 'distanceInMiles_two', 'שני מיילים'),
('he', 'distanceInFeet_two', 'שתי רגליים'),
('en', 'matchLocationOccurrence', 'Location {count}'),
('es', 'matchLocationOccurrence', 'Ubicación {count}'),
('he', 'matchLocationOccurrence', 'מיקום {count}'),
('en', 'photoPrescreenDetailMinimum', 'minimum'),
('es', 'photoPrescreenDetailMinimum', 'mínimo')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Pinned location. The onboarding demo rows live in
-- 20262213000000_onboarding_demo_copy_full_words.sql: the onboarding parity
-- check only reads migrations named *onboarding*.
INSERT INTO public.translations (locale, key, value) VALUES
('en', 'pinnedLocationLabelHint', 'Label (optional, for example: Home)'),
('es', 'pinnedLocationLabelHint', 'Etiqueta (opcional, por ejemplo: Casa)'),
-- The Hebrew row was the bare duration, so the Settings pill and the pinned
-- sheet read "3 ימים" — the same wording as a duration picker. The verb the
-- deleted {count} rows carried is restored around the spelled-out duration.
('he', 'pinnedLocationRemaining', 'נותרו {duration}')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew: דוא״ל and דוא"ל spelled out, with the article and the gender of the
-- verb or adjective re-agreed around the longer phrase.
INSERT INTO public.translations (locale, key, value) VALUES
('he', 'authDisposableEmailBlocked', 'אנא השתמשו בכתובת דואר אלקטרוני אישית רגילה. כתובות דואר אלקטרוני זמניות או חד-פעמיות אינן נתמכות.'),
('he', 'authEmailAlreadyRegistered', 'כבר קיים חשבון עם כתובת הדואר האלקטרוני הזו.'),
('he', 'authEmailRejected', 'לא הצלחנו להשתמש בכתובת הדואר האלקטרוני הזו להרשמה. נסו כתובת אחרת.'),
('he', 'authOAuthAccountExists', 'חשבון עם כתובת דואר אלקטרוני זו קיים כבר. אנא היכנס עם שם משתמש וסיסמה.'),
('he', 'authPasskeyUnsupported', 'מפתחות גישה עדיין לא זמינים בפלטפורמה הזאת. השתמש/י בדואר אלקטרוני, בסיסמה או בדרך כניסה אחרת.'),
('he', 'authPasswordLockedUntilEmailApproved', 'הזינו כתובת דואר אלקטרוני מאושרת כדי להמשיך.'),
('he', 'authProviderSuggestionPassword', 'השתמש בדואר אלקטרוני ובסיסמה במקום.'),
('he', 'authResetPasswordOtpTitle', 'בדקו את הדואר האלקטרוני שלכם'),
('he', 'authSignupCodeEnterPrompt', 'הזינו את הקוד בן 6 הספרות מהדואר האלקטרוני שלכם'),
('he', 'authSignupCodeTitle', 'אמתו את הדואר האלקטרוני שלכם'),
('he', 'authSignupCodeVerify', 'אמתו דואר אלקטרוני'),
('he', 'onboardingBeatSettingsAccount', 'תחת חשבון תוכלו להחליף סיסמה או דואר אלקטרוני… או למחוק את החשבון לגמרי. פעולות רגישות קודם מוודאות שזה באמת אתם.'),
('he', 'securityCenterEmailVerificationBody', 'השתמש באימות בדואר אלקטרוני כשיטת אימות חלופית עבור פעולות רגישות'),
('he', 'settingsAuthMethodEmailOtp', 'קוד בדואר אלקטרוני'),
('he', 'settingsChangeEmailCodeResent', 'קוד האימות נשלח שוב לדואר האלקטרוני החדש שלך.'),
('he', 'settingsChangeEmailCodeSent', 'קוד אימות נשלח לכתובת הדואר האלקטרוני החדשה שלך.'),
('he', 'settingsChangeEmailCurrentEmail', 'דואר אלקטרוני נוכחי'),
('he', 'settingsChangeEmailDescription', 'תצטרך לאמת את זהותך עם MFA ולאשר את כתובת הדואר האלקטרוני החדשה שלך.'),
('he', 'settingsChangeEmailEmailInUse', 'כתובת דואר אלקטרוני זו כבר בשימוש'),
('he', 'settingsChangeEmailError', 'שגיאה בשינוי כתובת הדואר האלקטרוני. אנא נסה שוב.'),
('he', 'settingsChangeEmailInvalidEmail', 'אנא הזן כתובת דואר אלקטרוני תקינה.'),
('he', 'settingsChangeEmailMfaRequired', 'נדרשת אימות MFA כדי לשנות דואר אלקטרוני.'),
('he', 'settingsChangeEmailNewEmail', 'כתובת דואר אלקטרוני חדשה'),
('he', 'settingsChangeEmailNewEmailHint', 'הזן את כתובת הדואר האלקטרוני החדשה שלך'),
('he', 'settingsChangeEmailSameEmail', 'הדואר האלקטרוני החדש חייב להיות שונה מהדואר האלקטרוני הנוכחי.'),
('he', 'settingsChangeEmailStep1Description', 'אנחנו צריכים לאמת אותך עם MFA לפני שינוי הדואר האלקטרוני שלך.'),
('he', 'settingsChangeEmailStep2Description', 'שלחנו קוד אימות לכתובת הדואר האלקטרוני החדשה שלך. הזן אותו להלן כדי לאשר.'),
('he', 'settingsChangeEmailStep2Title', 'שלב 2: אשר את הדואר האלקטרוני החדש שלך'),
('he', 'settingsChangeEmailSuccess', 'כתובת הדואר האלקטרוני שונתה בהצלחה!'),
('he', 'settingsChangeEmailTitle', 'שנה כתובת דואר אלקטרוני'),
('he', 'settingsChangeEmailVerify', 'אמת ושנה דואר אלקטרוני'),
('he', 'settingsChangeEmailVerifyCodeDescription', 'שלחנו קוד אימות לכתובת הדואר האלקטרוני החדשה שלך. הזן אותו להלן כדי לאשר את השינוי.'),
('he', 'settingsChangeEmailVerifyCodeTitle', 'אמת את הדואר האלקטרוני החדש שלך'),
('he', 'settingsEmailVerification', 'אימות דואר אלקטרוני'),
('he', 'settingsMfaEmailCode', 'קוד בדואר אלקטרוני'),
('he', 'settingsMfaEmailCodeResend', 'שלח דואר אלקטרוני שוב'),
('he', 'settingsMfaEmailCodeSendBody', 'הזן את הקוד שנשלח לדואר האלקטרוני שלך'),
('he', 'settingsMfaEmailCodeSendFailed', 'לא ניתן היה לשלוח אימות בדואר אלקטרוני'),
('he', 'settingsMfaEmailFallbackAvailable', 'גיבוי בדואר אלקטרוני זמין: {email}'),
('he', 'settingsMfaRecoveryCodesAndEmailDescription', 'קודי שחזור הם קודי גיבוי חד-פעמיים. אם אין לך גישה אליהם, אפשר גם לבקש קוד חד-פעמי בדואר אלקטרוני לכתובת {email}.'),
('he', 'settingsMfaRecoveryCodesAndEmailUsageHint', 'אם מאבדים גישה לאפליקציית האימות, מתחילים פעולה מוגנת ובוחרים "השתמש בקוד שחזור במקום" או "השתמש בקוד שנשלח בדואר אלקטרוני במקום" בחלון האימות.'),
('he', 'settingsMfaUseEmailCode', 'השתמש בקוד שנשלח בדואר אלקטרוני במקום')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Admin dashboard: window sizes were written as (15m), (1h) and with a tilde,
-- and the Hebrew totals used סה״כ / סה"כ / ע"י. The "2000/chunks" row reads as
-- a missing number in English, so it says what it means.
INSERT INTO public.translations (locale, key, value) VALUES
('en', 'adminBroadcastsActionUrlInvalid', 'Please enter a valid http or https URL'),
('en', 'adminBroadcastsAudienceLarge', 'Large audience ({count}) - sends in chunks of 2,000, may take several minutes.'),
('en', 'adminHealthAuthErrors15m', 'Auth errors (15 minutes)'),
('en', 'adminHealthErrorsApp', 'App errors (15 minutes)'),
('en', 'adminHealthErrorsCron', 'Cron jobs (1 hour)'),
('en', 'adminHealthErrorsEdge', 'Edge functions (15 minutes)'),
('en', 'adminHealthHistorySubtitle', 'Snapshots every 5 minutes · last 7 days'),
('en', 'adminHealthQueueFailedHour', 'Failed (1 hour)'),
('en', 'adminHealthSignIns15m', 'Sign-ins (15 minutes)'),
('es', 'adminBroadcastsActionUrlInvalid', 'Introduce una URL http o https válida'),
('es', 'adminHealthAuthErrors15m', 'Errores de autenticación (15 minutos)'),
('es', 'adminHealthErrorsApp', 'Errores de la app (15 minutos)'),
('es', 'adminHealthErrorsEdge', 'Funciones edge (15 minutos)'),
('es', 'adminHealthHistorySubtitle', 'Instantáneas cada 5 minutos · últimos 7 días'),
('es', 'adminHealthSignIns15m', 'Inicios de sesión (15 minutos)'),
('he', 'adminAppConfigIsUserConfigurable', 'ניתן להגדרה על ידי משתמש'),
('he', 'adminBroadcastsLimitsHintTitle', 'מקסימום {chars} תווים / {bytes} בתים (בסך הכול 4096 בתים ב-FCM)'),
('he', 'adminBroadcastsStatsTotal', 'בסך הכול'),
('he', 'adminPromoCodesDrillDownTotalUses', 'בסך הכול'),
('he', 'adminPromoCodesStatsTotalUses', 'בסך הכול'),
('he', 'adminHealthAuthErrors15m', 'שגיאות אימות (15 דקות)'),
('he', 'adminHealthErrorsApp', 'שגיאות האפליקציה (15 דקות)'),
('he', 'adminHealthErrorsEdge', 'פונקציות edge (15 דקות)'),
('he', 'adminHealthHistorySubtitle', 'צילום מצב בערך כל 5 דקות · 7 הימים האחרונים'),
('he', 'adminHealthSignIns15m', 'כניסות (15 דקות)')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- The keys the client no longer reads. Removing them means an older installed
-- build falls back to the copy bundled inside it — the wording it showed
-- before this change — rather than a placeholder it cannot fill. This
-- statement can be skipped without breaking anything: the rows are unreachable
-- from the current client either way.
DELETE FROM public.translations WHERE key IN (
  'meetupBeaconExpires',
  'meetupWalkMinutes',
  'meetupDistanceMeters',
  'meetupDistanceKm',
  'meetupSpotMeMinutesAgo',
  'meetupSpotMeHoursAgo',
  'meetupSpotMeHoursMinutesAgo',
  'pinnedLocationRemainingDays',
  'pinnedLocationRemainingHours',
  'pinnedLocationRemainingMinutes',
  'meetupHubDurationSignal',
  'meetupHubDurationBeacon',
  'meetupHubDurationLive',
  'meetupHubDurationSpot'
);
