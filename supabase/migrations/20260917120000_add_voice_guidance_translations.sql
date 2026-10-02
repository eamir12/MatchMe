-- Voice guidance translations (en/es/he)
-- Spoken coaching strings for the profile wizard and profile verification
-- flows (on-device TTS via lib/services/voice_guidance_service.dart).
-- English values intentionally match the built-in fallbacks in
-- locale_provider.dart: the DB copy takes precedence once seeded, so these
-- sentences can be reworded in the database without an app release, while
-- the code fallback keeps pre-migration/offline clients working.
-- Keep sentences short and natural — they are spoken aloud, not just read.
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run.

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'voiceGuidanceMuteTooltip', 'Mute voice guidance'),
  ('en', 'voiceGuidanceUnmuteTooltip', 'Turn voice guidance on'),
  ('en', 'voiceGuidanceSettingsLabel', 'Voice guidance'),
  ('en', 'voiceGuidanceSettingsDescription', 'Spoken step-by-step help while you complete your profile and verify your photos.'),
  ('en', 'voiceGuidanceWizardWelcome', 'Welcome! I will guide you through setting up your profile… On each page, tap Next when you are done.'),
  ('en', 'voiceGuidanceStepIntents', 'First, choose why you are here. Select at least one option, then tap Next.'),
  ('en', 'voiceGuidanceStepSubIntents', 'Now choose what fits your goal within {intent}. Pick at least one, then tap Next.'),
  ('en', 'voiceGuidanceStepAboutYou', 'This page is about you. Enter your name, gender and date of birth. You must be at least eighteen years old.'),
  ('en', 'voiceGuidanceStepDetails', 'Tell people about yourself. Write a short bio, pick the languages you know, and enter your height.'),
  ('en', 'voiceGuidanceStepPhotos', 'Time to add your photos… Tap Add photo to take a selfie, or choose one from your gallery. Your first photo is your main photo.'),
  ('en', 'voiceGuidanceStepInterests', 'Choose your interests. Pick at least one to continue, then tap Next.'),
  ('en', 'voiceGuidanceStepLifestyle', 'Choose your lifestyle options, then tap Next.'),
  ('en', 'voiceGuidanceStepFamily', 'Share your family plans, then tap Next.'),
  ('en', 'voiceGuidanceStepReligion', 'Choose your religious background, then tap Next.'),
  ('en', 'voiceGuidanceStepMatchPrefs', 'Set what you are looking for in a match, then tap Next.'),
  ('en', 'voiceGuidanceStepSocial', 'Last step. Add social links if you like, then tap Save to finish.'),
  ('en', 'voiceGuidancePhotoAdded', 'Photo added.'),
  ('en', 'voiceGuidancePhotoPrimaryAdded', 'Great… Your main photo was added. It is the first thing people see about you.'),
  ('en', 'voiceGuidancePhotoRemoved', 'Photo removed.'),
  ('en', 'voiceGuidancePhotosMaxReached', 'You already have the maximum of five photos.'),
  ('en', 'voiceGuidancePhotoRequiredHint', 'You need at least one photo to continue… Tap Add photo to take a selfie, or choose one from your gallery.'),
  ('en', 'voiceGuidancePrimaryPhotoOk', 'Your main photo looks great.'),
  ('en', 'voiceGuidanceVerificationIntro', 'Welcome to photo verification… Your face must be clearly visible, in good lighting, with no filters or edits… I will guide you.'),
  ('en', 'voiceGuidanceVerificationGesture', '{gesture}. {description}'),
  ('en', 'voiceGuidanceVerificationCaptured', 'Photo captured… If it looks good, tap Submit for review.'),
  ('en', 'voiceGuidanceVerificationSubmitting', 'Uploading your photo for review.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'voiceGuidanceMuteTooltip', 'Silenciar la guía por voz'),
  ('es', 'voiceGuidanceUnmuteTooltip', 'Activar la guía por voz'),
  ('es', 'voiceGuidanceSettingsLabel', 'Guía por voz'),
  ('es', 'voiceGuidanceSettingsDescription', 'Ayuda hablada paso a paso mientras completas tu perfil y verificas tus fotos.'),
  ('es', 'voiceGuidanceWizardWelcome', '¡Bienvenido! Te guiaré para configurar tu perfil… En cada página, toca Siguiente cuando termines.'),
  ('es', 'voiceGuidanceStepIntents', 'Primero, elige por qué estás aquí. Selecciona al menos una opción y toca Siguiente.'),
  ('es', 'voiceGuidanceStepSubIntents', 'Ahora elige qué encaja con tu objetivo dentro de {intent}. Elige al menos uno y toca Siguiente.'),
  ('es', 'voiceGuidanceStepAboutYou', 'Esta página trata sobre ti. Escribe tu nombre, género y fecha de nacimiento. Debes tener al menos dieciocho años.'),
  ('es', 'voiceGuidanceStepDetails', 'Cuéntales a los demás sobre ti. Escribe una biografía corta, indica los idiomas que conoces y tu estatura.'),
  ('es', 'voiceGuidanceStepPhotos', 'Es hora de agregar tus fotos… Toca Agregar foto para tomar una selfie, o elegir una de tu galería. Tu primera foto es tu foto principal.'),
  ('es', 'voiceGuidanceStepInterests', 'Elige tus intereses. Selecciona al menos uno para continuar y toca Siguiente.'),
  ('es', 'voiceGuidanceStepLifestyle', 'Elige tus opciones de estilo de vida y toca Siguiente.'),
  ('es', 'voiceGuidanceStepFamily', 'Comparte tus planes de familia y toca Siguiente.'),
  ('es', 'voiceGuidanceStepReligion', 'Elige tus antecedentes religiosos y toca Siguiente.'),
  ('es', 'voiceGuidanceStepMatchPrefs', 'Define qué buscas en una pareja y toca Siguiente.'),
  ('es', 'voiceGuidanceStepSocial', 'Último paso. Agrega enlaces sociales si quieres y toca Guardar para terminar.'),
  ('es', 'voiceGuidancePhotoAdded', 'Foto agregada.'),
  ('es', 'voiceGuidancePhotoPrimaryAdded', 'Genial… Se agregó tu foto principal. Es lo primero que la gente ve de ti.'),
  ('es', 'voiceGuidancePhotoRemoved', 'Foto eliminada.'),
  ('es', 'voiceGuidancePhotosMaxReached', 'Ya tienes el máximo de cinco fotos.'),
  ('es', 'voiceGuidancePhotoRequiredHint', 'Necesitas al menos una foto para continuar… Toca Agregar foto para tomar una selfie, o elegir una de tu galería.'),
  ('es', 'voiceGuidancePrimaryPhotoOk', 'Tu foto principal se ve muy bien.'),
  ('es', 'voiceGuidanceVerificationIntro', 'Bienvenido a la verificación de fotos… Tu rostro debe verse con claridad, con buena iluminación y sin filtros ni ediciones… Te guiaré.'),
  ('es', 'voiceGuidanceVerificationGesture', '{gesture}. {description}'),
  ('es', 'voiceGuidanceVerificationCaptured', 'Foto capturada… Si se ve bien, toca Enviar para revisión.'),
  ('es', 'voiceGuidanceVerificationSubmitting', 'Subiendo tu foto para revisión.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations (RTL support)
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'voiceGuidanceMuteTooltip', 'השתקת ההדרכה הקולית'),
  ('he', 'voiceGuidanceUnmuteTooltip', 'הפעלת ההדרכה הקולית'),
  ('he', 'voiceGuidanceSettingsLabel', 'הדרכה קולית'),
  ('he', 'voiceGuidanceSettingsDescription', 'עזרה מדוברת שלב אחר שלב בזמן שאתם משלימים את הפרופיל ומאמתים את התמונות שלכם.'),
  ('he', 'voiceGuidanceWizardWelcome', 'ברוכים הבאים! אני אלווה אתכם בהקמת הפרופיל… בכל עמוד, הקישו הבא כשסיימתם.'),
  ('he', 'voiceGuidanceStepIntents', 'קודם, בחרו מדוע אתם כאן. בחרו לפחות אפשרות אחת והקישו הבא.'),
  ('he', 'voiceGuidanceStepSubIntents', 'עכשיו בחרו מה מתאים למטרה שלכם בתוך {intent}. בחרו לפחות אחד והקישו הבא.'),
  ('he', 'voiceGuidanceStepAboutYou', 'העמוד הזה הוא עליכם. הזינו שם, מין ותאריך לידה. עליכם להיות בני שמונה־עשרה לפחות.'),
  ('he', 'voiceGuidanceStepDetails', 'ספרו על עצמכם. כתבו ביו קצר, בחרו את השפות שאתם יודעים והזינו את גובהכם.'),
  ('he', 'voiceGuidanceStepPhotos', 'הגיע הזמן להוסיף תמונות… הקישו הוספת תמונה כדי לצלם סלפי, או לבחור מהגלריה. התמונה הראשונה היא התמונה הראשית שלכם.'),
  ('he', 'voiceGuidanceStepInterests', 'בחרו את תחומי העניין שלכם. בחרו לפחות אחד כדי להמשיך והקישו הבא.'),
  ('he', 'voiceGuidanceStepLifestyle', 'בחרו את העדפות אורח החיים שלכם והקישו הבא.'),
  ('he', 'voiceGuidanceStepFamily', 'שתפו את התוכניות שלכם לגבי משפחה והקישו הבא.'),
  ('he', 'voiceGuidanceStepReligion', 'בחרו את הרקע הדתי שלכם והקישו הבא.'),
  ('he', 'voiceGuidanceStepMatchPrefs', 'הגדירו מה אתם מחפשים בבן או בת זוג והקישו הבא.'),
  ('he', 'voiceGuidanceStepSocial', 'השלב האחרון. הוסיפו קישורי רשתות חברתיות אם תרצו והקישו שמירה כדי לסיים.'),
  ('he', 'voiceGuidancePhotoAdded', 'התמונה נוספה.'),
  ('he', 'voiceGuidancePhotoPrimaryAdded', 'מעולה… התמונה הראשית שלכם נוספה. זה הדבר הראשון שאנשים רואים בכם.'),
  ('he', 'voiceGuidancePhotoRemoved', 'התמונה הוסרה.'),
  ('he', 'voiceGuidancePhotosMaxReached', 'כבר יש לכם את מקסימום חמש התמונות.'),
  ('he', 'voiceGuidancePhotoRequiredHint', 'צריכה להיות לכם לפחות תמונה אחת כדי להמשיך… הקישו הוספת תמונה כדי לצלם סלפי, או לבחור מהגלריה.'),
  ('he', 'voiceGuidancePrimaryPhotoOk', 'התמונה הראשית שלכם נראית מצוין.'),
  ('he', 'voiceGuidanceVerificationIntro', 'ברוכים הבאים לאימות התמונות… הפנים שלכם צריכות להיות ברורות, בתאורה טובה, ללא פילטרים או עריכות… אני אלווה אתכם.'),
  ('he', 'voiceGuidanceVerificationGesture', '{gesture}. {description}'),
  ('he', 'voiceGuidanceVerificationCaptured', 'התמונה צולמה… אם היא נראית טוב, הקישו שליחה לבדיקה.'),
  ('he', 'voiceGuidanceVerificationSubmitting', 'מעלה את התמונה שלכם לבדיקה.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
