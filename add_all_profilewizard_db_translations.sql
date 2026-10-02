-- Add all profile wizard and settings translations to DB
-- This ensures all user-facing text comes from Supabase translations table
-- Languages: en (English), es (Spanish), he (Hebrew)

INSERT INTO translations (locale, key, value) VALUES
  -- Interest keys
  ('en', 'interest.traveling', 'Traveling'),
  ('es', 'interest.traveling', 'Viajando'),
  ('he', 'interest.traveling', 'טיולים'),

  -- Profile edit field labels and hints
  ('en', 'profileEditHeight', 'Height'),
  ('es', 'profileEditHeight', 'Altura'),
  ('he', 'profileEditHeight', 'גובה'),

  ('en', 'profileEditHeightHint', 'Height in centimeters (for example, 170)'),
  ('es', 'profileEditHeightHint', 'Altura en centímetros (por ejemplo, 170)'),
  ('he', 'profileEditHeightHint', 'גובה בסנטימטרים (למשל 170)'),

  ('en', 'profileEditOccupation', 'Occupation'),
  ('es', 'profileEditOccupation', 'Ocupación'),
  ('he', 'profileEditOccupation', 'תעסוקה'),

  ('en', 'profileEditOccupationHint', 'What do you do?'),
  ('es', 'profileEditOccupationHint', '¿A qué te dedicas?'),
  ('he', 'profileEditOccupationHint', 'מה אתה עושה?'),

  ('en', 'profileEditEducation', 'Education'),
  ('es', 'profileEditEducation', 'Educación'),
  ('he', 'profileEditEducation', 'השכלה'),

  ('en', 'profileEditEducationHint', 'Highest education level'),
  ('es', 'profileEditEducationHint', 'Nivel educativo más alto'),
  ('he', 'profileEditEducationHint', 'הרמה הלימודית הגבוהה ביותר'),

  -- Profile wizard section titles
  ('en', 'profileWizardLifestyleTitle', 'Your Lifestyle'),
  ('es', 'profileWizardLifestyleTitle', 'Tu Estilo de Vida'),
  ('he', 'profileWizardLifestyleTitle', 'סטיל החיים שלך'),

  ('en', 'profileWizardLifestyleSubtitle', 'Help others get to know you better.'),
  ('es', 'profileWizardLifestyleSubtitle', 'Ayuda a otros a conocerte mejor.'),
  ('he', 'profileWizardLifestyleSubtitle', 'אפשר לאחרים להכיר אותך טוב יותר.'),

  ('en', 'profileWizardFamilyTitle', 'Family & Children'),
  ('es', 'profileWizardFamilyTitle', 'Familia e Hijos'),
  ('he', 'profileWizardFamilyTitle', 'משפחה וילדים'),

  ('en', 'profileWizardFamilySubtitle', 'Let others know about your family situation.'),
  ('es', 'profileWizardFamilySubtitle', 'Permite que otros conozcan tu situación familiar.'),
  ('he', 'profileWizardFamilySubtitle', 'אפשר לאחרים לדעת על מצבך המשפחתי.'),

  ('en', 'profileFamilyWantsChildren', 'Would you like to have children?'),
  ('es', 'profileFamilyWantsChildren', '¿Te gustaría tener hijos?'),
  ('he', 'profileFamilyWantsChildren', 'האם תרצה לילדים?'),

  -- Match preferences settings
  ('en', 'settingsMatchPreferences', 'Match Preferences'),
  ('es', 'settingsMatchPreferences', 'Preferencias de Coincidencias'),
  ('he', 'settingsMatchPreferences', 'העדפות התאמה'),

  ('en', 'settingsMatchPreferencesDesc', 'Customize your matching preferences for each relationship goal.'),
  ('es', 'settingsMatchPreferencesDesc', 'Personaliza tus preferencias de coincidencia para cada objetivo de relación.'),
  ('he', 'settingsMatchPreferencesDesc', 'התאם אישית את העדפות ההתאמה שלך לכל יעד זוגי.'),

  ('en', 'settingsMatchPreferencesIntro', 'Customize who you see for each relationship goal beyond gender and age.'),
  ('es', 'settingsMatchPreferencesIntro', 'Personaliza quién ves para cada objetivo de relación más allá del género y la edad.'),
  ('he', 'settingsMatchPreferencesIntro', 'התאם אישית את מי אתה רואהforall יעד זוגי מעבר למגדר וגיל.'),

  -- Lifestyle filters settings
  ('en', 'settingsLifestyleFilters', 'Lifestyle Filters'),
  ('es', 'settingsLifestyleFilters', 'Filtros de Estilo de Vida'),
  ('he', 'settingsLifestyleFilters', 'סינוני סגנון חיים'),

  -- Smoking settings
  ('en', 'settingsSmoking', 'Smoking'),
  ('es', 'settingsSmoking', 'Fumar'),
  ('he', 'settingsSmoking', 'עישון'),

  ('en', 'settingsSmokingAny', 'Any'),
  ('es', 'settingsSmokingAny', 'Cualquiera'),
  ('he', 'settingsSmokingAny', 'הכל'),

  ('en', 'settingsSmokingNever', 'Non-smoker'),
  ('es', 'settingsSmokingNever', 'No fumador'),
  ('he', 'settingsSmokingNever', 'לא מעשן'),

  ('en', 'settingsSmokingOk', 'Smoker OK'),
  ('es', 'settingsSmokingOk', 'Fumador aceptado'),
  ('he', 'settingsSmokingOk', 'מעשן - אין בעיה'),

  -- Drinking settings
  ('en', 'settingsDrinking', 'Drinking'),
  ('es', 'settingsDrinking', 'Bebida'),
  ('he', 'settingsDrinking', 'שתייה'),

  ('en', 'settingsDrinkingAny', 'Any'),
  ('es', 'settingsDrinkingAny', 'Cualquiera'),
  ('he', 'settingsDrinkingAny', 'הכל'),

  ('en', 'settingsDrinkingNever', 'Non-drinker'),
  ('es', 'settingsDrinkingNever', 'No bebedor'),
  ('he', 'settingsDrinkingNever', 'טורח'),

  ('en', 'settingsDrinkingOk', 'Drinker OK'),
  ('es', 'settingsDrinkingOk', 'Bebedor aceptado'),
  ('he', 'settingsDrinkingOk', 'טורח - אין בעיה'),

  -- Exercise settings
  ('en', 'settingsExercise', 'Exercise'),
  ('es', 'settingsExercise', 'Ejercicio'),
  ('he', 'settingsExercise', 'פעילות גופנית'),

  ('en', 'settingsExerciseAny', 'Any'),
  ('es', 'settingsExerciseAny', 'Cualquiera'),
  ('he', 'settingsExerciseAny', 'הכל'),

  ('en', 'settingsExerciseNever', 'Rarely'),
  ('es', 'settingsExerciseNever', 'Raramente'),
  ('he', 'settingsExerciseNever', 'נדיר'),

  ('en', 'settingsExerciseOk', 'Active OK'),
  ('es', 'settingsExerciseOk', 'Activo aceptado'),
  ('he', 'settingsExerciseOk', 'פעיל - אין בעיה'),

  -- Diet settings
  ('en', 'settingsDiet', 'Diet'),
  ('es', 'settingsDiet', 'Dieta'),
  ('he', 'settingsDiet', 'תזונה'),

  ('en', 'settingsDietAny', 'Any'),
  ('es', 'settingsDietAny', 'Cualquiera'),
  ('he', 'settingsDietAny', 'הכל'),

  -- Religion settings
  ('en', 'settingsReligionAny', 'Any / Prefer not to say'),
  ('es', 'settingsReligionAny', 'Cualquiera / Prefiero no decir'),
  ('he', 'settingsReligionAny', 'הכל / מעדיף לא לומר'),

  -- Additional profile wizard keys
  ('en', 'profileWizardSubIntentMin', '{intent} requires at least {min} sub-intents'),
  ('es', 'profileWizardSubIntentMin', '{intent} requiere al menos {min} sub-intentos'),
  ('he', 'profileWizardSubIntentMin', '{intent} דורש לפחות {min} תת-כיוונים'),

  ('en', 'profileWizardInterestMin', '{intent} requires at least {min} interest'),
  ('es', 'profileWizardInterestMin', '{intent} requiere al menos {min} interés'),
  ('he', 'profileWizardInterestMin', '{intent} דורש לפחות {min} עניין'),

  ('en', 'profileCounterSelected', '{count} of {max} selected'),
  ('es', 'profileCounterSelected', '{count} de {max} seleccionados'),
  ('he', 'profileCounterSelected', '{count} מתוך {max} נבחרו'),

  ('en', 'profileSelectSubIntentsMinMax', 'Select {min} to {max} sub-intents'),
  ('es', 'profileSelectSubIntentsMinMax', 'Selecciona de {min} a {max} sub-intentos'),
  ('he', 'profileSelectSubIntentsMinMax', 'בחר מ-{min} עד {max} תת-כיוונים'),

  -- Additional missing keys from profile wizard
  ('en', 'profileEditFirstNameRequired', 'First name is required'),
  ('es', 'profileEditFirstNameRequired', 'El nombre es obligatorio'),
  ('he', 'profileEditFirstNameRequired', 'נדרש שם פרטי'),

  ('en', 'profileEditLastNameRequired', 'Last name is required'),
  ('es', 'profileEditLastNameRequired', 'El apellido es obligatorio'),
  ('he', 'profileEditLastNameRequired', 'נדרש שם משפחה'),

  ('en', 'settingsHeightCm', 'centimeters'),
  ('es', 'settingsHeightCm', 'centímetros'),
  ('he', 'settingsHeightCm', 'סנטימטרים'),

  ('en', 'profileWizardErrorLoadingIntents', 'Error loading intents'),
  ('es', 'profileWizardErrorLoadingIntents', 'Error al cargar intenciones'),
  ('he', 'profileWizardErrorLoadingIntents', 'נכשרה טעינת הכיוונים'),

  ('en', 'profileWizardErrorLoadingInterests', 'Error loading interests'),
  ('es', 'profileWizardErrorLoadingInterests', 'Error al cargar intereses'),
  ('he', 'profileWizardErrorLoadingInterests', 'נכשרה טעינת העניינים'),

  -- Additional lifestyle and preference keys
  ('en', 'profileLifestyleSmoking', 'Smoking'),
  ('es', 'profileLifestyleSmoking', 'Fumar'),
  ('he', 'profileLifestyleSmoking', 'עישון'),

  ('en', 'profileLifestyleDrinking', 'Drinking'),
  ('es', 'profileLifestyleDrinking', 'Bebida'),
  ('he', 'profileLifestyleDrinking', 'שתייה'),

  ('en', 'profileLifestyleExercise', 'Exercise'),
  ('es', 'profileLifestyleExercise', 'Ejercicio'),
  ('he', 'profileLifestyleExercise', 'פעילות גופנית'),

  ('en', 'profileLifestyleDiet', 'Diet'),
  ('es', 'profileLifestyleDiet', 'Dieta'),
  ('he', 'profileLifestyleDiet', 'תזונה'),

  -- Gender preference settings
  ('en', 'settingsPreferredGenders', 'Preferred genders'),
  ('es', 'settingsPreferredGenders', 'Géneros preferidos'),
  ('he', 'settingsPreferredGenders', 'מגדרים מועדפים'),

  ('en', 'settingsPreferredAgeRange', 'Preferred age range'),
  ('es', 'settingsPreferredAgeRange', 'Rango de edad preferido'),
  ('he', 'settingsPreferredAgeRange', 'טווח גיל מועדף'),

  -- Enforcement settings
  ('en', 'settingsGenderRequirementsEnforcement', 'Gender requirements enforcement'),
  ('es', 'settingsGenderRequirementsEnforcement', 'Cumplimiento de requisitos de género'),
  ('he', 'settingsGenderRequirementsEnforcement', 'אכיפת דרישות מגדר'),

  ('en', 'settingsAgeRequirementsEnforcement', 'Age requirements enforcement'),
  ('es', 'settingsAgeRequirementsEnforcement', 'Cumplimiento de requisitos de edad'),
  ('he', 'settingsAgeRequirementsEnforcement', 'אכיפת דרישות גיל'),

  -- Age range settings
  ('en', 'settingsAgeRange', 'Age range'),
  ('es', 'settingsAgeRange', 'Rango de edad'),
  ('he', 'settingsAgeRange', 'טווח גיל'),

  ('en', 'settingsAgeRangeMin', 'Minimum age'),
  ('es', 'settingsAgeRangeMin', 'Edad mínima'),
  ('he', 'settingsAgeRangeMin', 'גיל מינימלי'),

  ('en', 'settingsAgeRangeMax', 'Maximum age'),
  ('es', 'settingsAgeRangeMax', 'Edad máxima'),
  ('he', 'settingsAgeRangeMax', 'גיל מקסימלי'),

  -- Additional profile keys
  ('en', 'profileZodiacSign', 'Zodiac Sign'),
  ('es', 'profileZodiacSign', 'Signo del Zodiaco'),
  ('he', 'profileZodiacSign', 'מזל'),

  ('en', 'profileSocialLinks', 'Social Links'),
  ('es', 'profileSocialLinks', 'Redes Sociales'),
  ('he', 'profileSocialLinks', 'קישורים חברתיים'),

  ('en', 'profileInterestsHelper', 'Select a few interests to help improve your matches.'),
  ('es', 'profileInterestsHelper', 'Selecciona algunos intereses para mejorar tus coincidencias.'),
  ('he', 'profileInterestsHelper', 'בחר כמה עניינים כדי לשפר את ההתאמות שלך.'),

  -- Photo wizard keys
  ('en', 'profileWizardPhotoNoFaceDetected', 'No face was detected in the photo. Please try a clearer photo.'),
  ('es', 'profileWizardPhotoNoFaceDetected', 'No se detectó ninguna cara en la foto. Por favor, intenta con una foto más clara.'),
  ('he', 'profileWizardPhotoNoFaceDetected', 'לא זוהתה הפנים בתמונה. אנא נסה תמונה ברורה יותר.'),

  -- Additional error and status keys
  ('en', 'profileEditBioModerationUnavailable', 'Unable to verify your bio right now. Please try again.'),
  ('es', 'profileEditBioModerationUnavailable', 'No se pudo verificar tu biografía ahora. Por favor, inténtalo de nuevo.'),
  ('he', 'profileEditBioModerationUnavailable', 'נכשרה הבדיקה הביוגרפית כעת. אנא נסה שוב מאוחר יותר.'),

  ('en', 'profileEditBioRejected', 'Your bio was not approved.'),
  ('es', 'profileEditBioRejected', 'Tu biografía no fue aprobada.'),
  ('he', 'profileEditBioRejected', 'הביוגרפיה שלך לא אושרה.'),

  ('en', 'profileEditBioDuplicate', 'This bio is already being used by another profile. Please write your own bio.'),
  ('es', 'profileEditBioDuplicate', 'Esta biografía ya está siendo usada por otro perfil. Por favor, escribe la tuya.'),
  ('he', 'profileEditBioDuplicate', 'ביוגרפיה זו כבר בשימוש על ידי פרופיל אחר. אנא כתוב ביוגרפיה משלך.'),

  -- Height unit toggle
  ('en', 'profileHeightUnitCm', 'centimeters'),
  ('es', 'profileHeightUnitCm', 'centímetros'),
  ('he', 'profileHeightUnitCm', 'סנטימטרים'),

  ('en', 'profileHeightUnitFeet', 'feet'),
  ('es', 'profileHeightUnitFeet', 'pies'),
  ('he', 'profileHeightUnitFeet', 'רגל'),

  ('en', 'profileHeightUnitInches', 'inches'),
  ('es', 'profileHeightUnitInches', 'pulgadas'),
  ('he', 'profileHeightUnitInches', 'אינטש'),

  ('en', 'profileHeightFeet', 'Feet'),
  ('es', 'profileHeightFeet', 'Pies'),
  ('he', 'profileHeightFeet', 'רגל'),

  ('en', 'profileHeightInches', 'Inches'),
  ('es', 'profileHeightInches', 'Pulgadas'),
  ('he', 'profileHeightInches', 'אינטש'),

  ('en', 'profileHeightFeetInches', '{feet} feet {inches} inches'),
  ('es', 'profileHeightFeetInches', '{feet} pies {inches} pulgadas'),
  ('he', 'profileHeightFeetInches', '{feet} רגל {inches} אינטש'),

  ('en', 'profileHeightInCm', '{cm} centimeters'),
  ('es', 'profileHeightInCm', '{cm} centímetros'),
  ('he', 'profileHeightInCm', '{cm} סנטימטרים'),

  -- Diet settings values
  ('en', 'settingsDietVegetarian', 'Vegetarian'),
  ('es', 'settingsDietVegetarian', 'Vegetariano'),
  ('he', 'settingsDietVegetarian', 'צמחוני'),

  ('en', 'settingsDietVegan', 'Vegan'),
  ('es', 'settingsDietVegan', 'Vegano'),
  ('he', 'settingsDietVegan', 'טבעוני'),

  ('en', 'settingsDietHalal', 'Halal'),
  ('es', 'settingsDietHalal', 'Halal'),
  ('he', 'settingsDietHalal', 'חלאל'),

  ('en', 'settingsDietKosher', 'Kosher'),
  ('es', 'settingsDietKosher', 'Kosher'),
  ('he', 'settingsDietKosher', 'כשר'),

  -- Exercise settings values
  ('en', 'settingsExerciseActive', 'Active'),
  ('es', 'settingsExerciseActive', 'Activo'),
  ('he', 'settingsExerciseActive', 'פעיל'),

  ('en', 'settingsExerciseNotActive', 'Not active'),
  ('es', 'settingsExerciseNotActive', 'No activo'),
  ('he', 'settingsExerciseNotActive', 'לא פעיל'),

  -- Family filters settings
  ('en', 'settingsFamilyFilters', 'Family Filters'),
  ('es', 'settingsFamilyFilters', 'Filtros de Familia'),
  ('he', 'settingsFamilyFilters', 'סינוני משפחה'),

  ('en', 'settingsHasChildren', 'Has children'),
  ('es', 'settingsHasChildren', 'Tiene hijos'),
  ('he', 'settingsHasChildren', 'יש ילדים'),

  ('en', 'settingsHasChildrenAny', 'Any'),
  ('es', 'settingsHasChildrenAny', 'Cualquiera'),
  ('he', 'settingsHasChildrenAny', 'הכל'),

  ('en', 'settingsHasChildrenYes', 'Has children'),
  ('es', 'settingsHasChildrenYes', 'Tiene hijos'),
  ('he', 'settingsHasChildrenYes', 'יש ילדים'),

  ('en', 'settingsHasChildrenNo', 'No children'),
  ('es', 'settingsHasChildrenNo', 'Sin hijos'),
  ('he', 'settingsHasChildrenNo', 'אין ילדים'),

  ('en', 'settingsWantsChildren', 'Wants children'),
  ('es', 'settingsWantsChildren', 'Quiere hijos'),
  ('he', 'settingsWantsChildren', 'רוצה ילדים'),

  ('en', 'settingsWantsChildrenAny', 'Any'),
  ('es', 'settingsWantsChildrenAny', 'Cualquiera'),
  ('he', 'settingsWantsChildrenAny', 'הכל'),

  ('en', 'settingsWantsChildrenYes', 'Yes'),
  ('es', 'settingsWantsChildrenYes', 'Sí'),
  ('he', 'settingsWantsChildrenYes', 'כן'),

  ('en', 'settingsWantsChildrenNo', 'No'),
  ('es', 'settingsWantsChildrenNo', 'No'),
  ('he', 'settingsWantsChildrenNo', 'לא'),

  ('en', 'settingsWantsChildrenOpen', 'Open to it'),
  ('es', 'settingsWantsChildrenOpen', 'Abierto a ello'),
  ('he', 'settingsWantsChildrenOpen', 'פתוח לזה'),

  -- Height range settings
  ('en', 'settingsHeightRange', 'Height range'),
  ('es', 'settingsHeightRange', 'Rango de altura'),
  ('he', 'settingsHeightRange', 'טווח גובה'),

  -- Beliefs / religion settings
  ('en', 'settingsBeliefs', 'Beliefs'),
  ('es', 'settingsBeliefs', 'Creencias'),
  ('he', 'settingsBeliefs', 'אמונות'),

  ('en', 'settingsSameReligionOnly', 'Same religion only'),
  ('es', 'settingsSameReligionOnly', 'Solo misma religión'),
  ('he', 'settingsSameReligionOnly', 'רק אותה דת'),

  -- Traveling interest
  ('en', 'traveling', 'Traveling'),
  ('es', 'traveling', 'Viajando'),
  ('he', 'traveling', 'טיולים'),

  -- Religion labels (used in both profile wizard and match preferences)
  ('en', 'religionChristianity', 'Christianity'),
  ('es', 'religionChristianity', 'Cristianismo'),
  ('he', 'religionChristianity', 'נצרות'),

  ('en', 'religionIslam', 'Islam'),
  ('es', 'religionIslam', 'Islam'),
  ('he', 'religionIslam', 'אסלאם'),

  ('en', 'religionHinduism', 'Hinduism'),
  ('es', 'religionHinduism', 'Hinduismo'),
  ('he', 'religionHinduism', 'הינדואיזם'),

  ('en', 'religionBuddhism', 'Buddhism'),
  ('es', 'religionBuddhism', 'Budismo'),
  ('he', 'religionBuddhism', 'בודהיזם'),

  ('en', 'religionJudaism', 'Judaism'),
  ('es', 'religionJudaism', 'Judaísmo'),
  ('he', 'religionJudaism', 'יהדות'),

  ('en', 'religionOther', 'Other'),
  ('es', 'religionOther', 'Otro'),
  ('he', 'religionOther', 'אחר'),

  -- Settings religion section
  ('en', 'settingsReligion', 'Religion'),
  ('es', 'settingsReligion', 'Religión'),
  ('he', 'settingsReligion', 'דת')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
