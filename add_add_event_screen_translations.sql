-- ============================================================================
-- MatchMe Translation Backfill Script - Add Event Screen Rework
--
-- PURPOSE: Add the translation keys introduced by the Add Event screen rework
--   and the event-card attendance summary change.
--   - addEventHowTitle, addEventIntroBody (screen intro + picker heading)
--   - eventInputModeLinkTitle/Desc, eventInputModeTicketTitle/Desc,
--     eventInputModeManualTitle/Desc (mode picker cards)
--   - eventLinkFetchButton, eventLinkHelpText (link extraction UI)
--   - eventTicketUploadButton, eventTicketUploadHelpText (ticket upload UI)
--   - eventAttendeeCount (event card attendance summary)
--   Total: 13 keys x 3 locales (en, es, he) = 39 translation entries
--
-- WHY:
--   The English fallbacks live in lib/providers/locale_provider.dart, so the
--   screen is usable before this runs. Without it, non-English locales fall
--   back to English and the keys are reported by the "Missing DB translation
--   keys" bootstrap diagnostic.
--
-- EXECUTION NOTES:
--   - Run against the Supabase project used by the app.
--   - Verify with the English, Spanish (es) and Hebrew (he) locales.
--   - On a fresh sign-in the app logs the count of keys still missing from the
--     DB; none of these keys should appear in that list afterwards.
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: ENGLISH TRANSLATIONS (en)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('en', 'addEventHowTitle', 'How do you want to add it?', NOW(), NOW()),
('en', 'addEventIntroBody', 'Add events you’re going to so you can meet others who’ll be there too. Choose one of the three easy ways below — MatchMe fills in the details for you.', NOW(), NOW()),
('en', 'eventAttendeeCount', '{count} attending', NOW(), NOW()),
('en', 'eventInputModeLinkDesc', 'Have a website or online invitation', NOW(), NOW()),
('en', 'eventInputModeLinkTitle', 'Paste a link', NOW(), NOW()),
('en', 'eventInputModeManualDesc', 'Type the event information yourself', NOW(), NOW()),
('en', 'eventInputModeManualTitle', 'Enter details manually', NOW(), NOW()),
('en', 'eventInputModeTicketDesc', 'Use a photo or PDF of your ticket', NOW(), NOW()),
('en', 'eventInputModeTicketTitle', 'Upload a ticket', NOW(), NOW()),
('en', 'eventLinkFetchButton', 'Get event details', NOW(), NOW()),
('en', 'eventLinkHelpText', 'MatchMe reads the page and fills in the details for you. You can review and edit everything before saving.', NOW(), NOW()),
('en', 'eventTicketUploadButton', 'Upload your ticket', NOW(), NOW()),
('en', 'eventTicketUploadHelpText', 'Tap to choose a photo or PDF. MatchMe reads the details for you.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 2: SPANISH TRANSLATIONS (es)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('es', 'addEventHowTitle', '¿Cómo quieres añadir tu evento?', NOW(), NOW()),
('es', 'addEventIntroBody', 'Añade los eventos a los que irás para conocer a otras personas que también estarán allí. Elige una de las tres formas fáciles de abajo: MatchMe completa los datos por ti.', NOW(), NOW()),
('es', 'eventAttendeeCount', '{count} asistirán', NOW(), NOW()),
('es', 'eventInputModeLinkDesc', 'Tienes un sitio web o una invitación en línea', NOW(), NOW()),
('es', 'eventInputModeLinkTitle', 'Pegar un enlace', NOW(), NOW()),
('es', 'eventInputModeManualDesc', 'Escribe la información del evento', NOW(), NOW()),
('es', 'eventInputModeManualTitle', 'Introducir los datos manualmente', NOW(), NOW()),
('es', 'eventInputModeTicketDesc', 'Usa una foto o un PDF de tu entrada', NOW(), NOW()),
('es', 'eventInputModeTicketTitle', 'Subir una entrada', NOW(), NOW()),
('es', 'eventLinkFetchButton', 'Obtener detalles del evento', NOW(), NOW()),
('es', 'eventLinkHelpText', 'MatchMe lee la página y completa los datos por ti. Puedes revisarlo y editarlo todo antes de guardar.', NOW(), NOW()),
('es', 'eventTicketUploadButton', 'Sube tu entrada', NOW(), NOW()),
('es', 'eventTicketUploadHelpText', 'Toca para elegir una foto o un PDF. MatchMe lee los datos por ti.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- SECTION 3: HEBREW TRANSLATIONS (he)
-- ============================================================================

INSERT INTO translations (locale, key, value, created_at, updated_at) VALUES
('he', 'addEventHowTitle', 'איך רוצים להוסיף את האירוע?', NOW(), NOW()),
('he', 'addEventIntroBody', 'הוסיפו אירועים שאתם הולכים אליהם כדי להכיר אנשים נוספים שיהיו שם. בחרו אחת משלוש הדרכים הקלות למטה — MatchMe ממלא עבורכם את הפרטים.', NOW(), NOW()),
('he', 'eventAttendeeCount', '{count} משתתפים', NOW(), NOW()),
('he', 'eventInputModeLinkDesc', 'יש לכם אתר או הזמנה מקוונת', NOW(), NOW()),
('he', 'eventInputModeLinkTitle', 'הדבקת קישור', NOW(), NOW()),
('he', 'eventInputModeManualDesc', 'הקלידו את פרטי האירוע בעצמכם', NOW(), NOW()),
('he', 'eventInputModeManualTitle', 'הזנת הפרטים ידנית', NOW(), NOW()),
('he', 'eventInputModeTicketDesc', 'השתמשו בתמונה או בקובץ PDF של הכרטיס', NOW(), NOW()),
('he', 'eventInputModeTicketTitle', 'העלאת כרטיס', NOW(), NOW()),
('he', 'eventLinkFetchButton', 'קבלת פרטי האירוע', NOW(), NOW()),
('he', 'eventLinkHelpText', 'MatchMe קורא את הדף וממלא עבורכם את הפרטים. אפשר לעיין ולערוך הכול לפני השמירה.', NOW(), NOW()),
('he', 'eventTicketUploadButton', 'העלאת הכרטיס שלכם', NOW(), NOW()),
('he', 'eventTicketUploadHelpText', 'הקישו לבחירת תמונה או PDF. MatchMe קורא את הפרטים עבורכם.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ============================================================================
-- VERIFICATION
-- ============================================================================

-- SELECT locale, key, value
-- FROM translations
-- WHERE key IN (
--   'addEventHowTitle',
--   'addEventIntroBody',
--   'eventAttendeeCount',
--   'eventInputModeLinkDesc',
--   'eventInputModeLinkTitle',
--   'eventInputModeManualDesc',
--   'eventInputModeManualTitle',
--   'eventInputModeTicketDesc',
--   'eventInputModeTicketTitle',
--   'eventLinkFetchButton',
--   'eventLinkHelpText',
--   'eventTicketUploadButton',
--   'eventTicketUploadHelpText'
-- )
-- ORDER BY locale, key;
--
-- Expected result: 39 rows (13 keys x en, es, he)
-- ============================================================================
