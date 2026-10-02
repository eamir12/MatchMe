-- Migration: Complete Match Inspector Translations for English, Hebrew, and Spanish
-- Purpose: Localize all user-facing text on the Match Inspector screen
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Screen Header
  ('en', 'matchInspectorTitle', $$Match Inspector$$),
  ('es', 'matchInspectorTitle', $$Inspector de coincidencias$$),
  ('he', 'matchInspectorTitle', $$מפקח התאמות$$),

  ('en', 'matchInspectorSubtitle', $$Compare two users to see why they match or not.$$),
  ('es', 'matchInspectorSubtitle', $$Compara dos usuarios para ver por qué coinciden o no.$$),
  ('he', 'matchInspectorSubtitle', $$השווה בין שני משתמשים כדי לראות מדוע הם מתאימים או לא.$$),

  -- User Pickers
  ('en', 'matchInspectorUserA', $$User A$$),
  ('es', 'matchInspectorUserA', $$Usuario A$$),
  ('he', 'matchInspectorUserA', $$משתמש א'$$),

  ('en', 'matchInspectorUserB', $$User B$$),
  ('es', 'matchInspectorUserB', $$Usuario B$$),
  ('he', 'matchInspectorUserB', $$משתמש ב'$$),

  ('en', 'matchInspectorSearchHint', $$Select a user to inspect...$$),
  ('es', 'matchInspectorSearchHint', $$Selecciona un usuario para inspeccionar...$$),
  ('he', 'matchInspectorSearchHint', $$בחר משתמש לבדיקה...$$),

  ('en', 'matchInspectorSearchFieldHint', $$Search by name, email, or user ID...$$),
  ('es', 'matchInspectorSearchFieldHint', $$Buscar por nombre, correo o ID de usuario...$$),
  ('he', 'matchInspectorSearchFieldHint', $$חפש לפי שם, אימייל או מזהה משתמש...$$),

  ('en', 'matchInspectorSearchNoResults', $$No users found matching your search$$),
  ('es', 'matchInspectorSearchNoResults', $$No se encontraron usuarios que coincidan con la búsqueda$$),
  ('he', 'matchInspectorSearchNoResults', $$לא נמצאו משתמשים תואמים לחיפוש$$),

  ('en', 'matchInspectorSwap', $$Swap users$$),
  ('es', 'matchInspectorSwap', $$Intercambiar usuarios$$),
  ('he', 'matchInspectorSwap', $$החלף משתמשים$$),

  ('en', 'matchInspectorClear', $$Clear$$),
  ('es', 'matchInspectorClear', $$Limpiar$$),
  ('he', 'matchInspectorClear', $$נקה$$),

  ('en', 'matchInspectorSelectHint', $$Select two users to compare$$),
  ('es', 'matchInspectorSelectHint', $$Selecciona dos usuarios para comparar$$),
  ('he', 'matchInspectorSelectHint', $$בחר שני משתמשים להשוואה$$),

  ('en', 'matchInspectorSelectInstructions', $$Select User A and User B above, then tap Compare Profiles to see compatibility.$$),
  ('es', 'matchInspectorSelectInstructions', $$Selecciona el Usuario A y el Usuario B arriba, luego toca Comparar perfiles para ver la compatibilidad.$$),
  ('he', 'matchInspectorSelectInstructions', $$בחר משתמש א' ומשתמש ב' למעלה, ולאחר מכן לחץ על השוואת פרופילים לצפייה בהתאמה.$$),

  -- Buttons & Actions
  ('en', 'matchInspectorCompareButton', $$Compare Profiles$$),
  ('es', 'matchInspectorCompareButton', $$Comparar perfiles$$),
  ('he', 'matchInspectorCompareButton', $$השווה פרופילים$$),

  ('en', 'matchInspectorLoading', $$Analyzing...$$),
  ('es', 'matchInspectorLoading', $$Analizando...$$),
  ('he', 'matchInspectorLoading', $$מנתח...$$),

  ('en', 'matchInspectorSameUser', $$Please select two different users to compare.$$),
  ('es', 'matchInspectorSameUser', $$Por favor selecciona dos usuarios diferentes para comparar.$$),
  ('he', 'matchInspectorSameUser', $$אנא בחר שני משתמשים שונים להשוואה.$$),

  ('en', 'matchInspectorErrorLoadFailed', $$Failed to compare users: {error}$$),
  ('es', 'matchInspectorErrorLoadFailed', $$Error al comparar usuarios: {error}$$),
  ('he', 'matchInspectorErrorLoadFailed', $$נכשל בהשוואת משתמשים: {error}$$),

  -- Verdict & Badges
  ('en', 'matchInspectorResultCompatible', $$Compatible Match$$),
  ('es', 'matchInspectorResultCompatible', $$Coincidencia compatible$$),
  ('he', 'matchInspectorResultCompatible', $$התאמה תואמת$$),

  ('en', 'matchInspectorResultNotCompatible', $$Not Compatible$$),
  ('es', 'matchInspectorResultNotCompatible', $$No compatible$$),
  ('he', 'matchInspectorResultNotCompatible', $$לא תואם$$),

  ('en', 'matchInspectorAlreadyMatched', $$Already Matched$$),
  ('es', 'matchInspectorAlreadyMatched', $$Ya emparejados$$),
  ('he', 'matchInspectorAlreadyMatched', $$כבר הותאמו$$),

  ('en', 'matchInspectorUnmatchedPair', $$Unmatched Pair$$),
  ('es', 'matchInspectorUnmatchedPair', $$Pareja desemparejada$$),
  ('he', 'matchInspectorUnmatchedPair', $$זוג שבוטל התאמתו$$),

  ('en', 'matchInspectorCompatibleIntents', $$Compatible in {intents}$$),
  ('es', 'matchInspectorCompatibleIntents', $$Compatible en {intents}$$),
  ('he', 'matchInspectorCompatibleIntents', $$תואם ב-{intents}$$),

  ('en', 'matchInspectorBlockersTitle', $$Blockers preventing match$$),
  ('es', 'matchInspectorBlockersTitle', $$Factores que impiden la coincidencia$$),
  ('he', 'matchInspectorBlockersTitle', $$חסימות המונעות התאמה$$),

  ('en', 'matchInspectorBlockersNone', $$All criteria passed — these users can match!$$),
  ('es', 'matchInspectorBlockersNone', $$¡Todos los criterios aprobados — estos usuarios pueden coincidir!$$),
  ('he', 'matchInspectorBlockersNone', $$כל הקריטריונים עברו בהצלחה — משתמשים אלה יכולים להתאים!$$),

  ('en', 'matchInspectorNoSharedIntents', $$No shared active intents between these users$$),
  ('es', 'matchInspectorNoSharedIntents', $$No hay intenciones activas compartidas entre estos usuarios$$),
  ('he', 'matchInspectorNoSharedIntents', $$אין כוונות פעילות משותפות בין משתמשים אלה$$),

  -- Environmental HUD
  ('en', 'matchInspectorEnvironmentalHeader', $$Environment & System Status$$),
  ('es', 'matchInspectorEnvironmentalHeader', $$Estado del entorno y sistema$$),
  ('he', 'matchInspectorEnvironmentalHeader', $$סביבה וסטטוס מערכת$$),

  ('en', 'matchInspectorDistance', $$Distance$$),
  ('es', 'matchInspectorDistance', $$Distancia$$),
  ('he', 'matchInspectorDistance', $$מרחק$$),

  ('en', 'matchInspectorDistanceUnknown', $$Location not reported$$),
  ('es', 'matchInspectorDistanceUnknown', $$Ubicación no reportada$$),
  ('he', 'matchInspectorDistanceUnknown', $$מיקום לא דווח$$),

  ('en', 'matchInspectorVisibilityHeader', $$Visibility$$),
  ('es', 'matchInspectorVisibilityHeader', $$Visibilidad$$),
  ('he', 'matchInspectorVisibilityHeader', $$נראות$$),

  ('en', 'matchInspectorIncognito', $$Incognito$$),
  ('es', 'matchInspectorIncognito', $$Incógnito$$),
  ('he', 'matchInspectorIncognito', $$במצב מוסתר$$),

  ('en', 'matchInspectorLiveActivity', $$Live Activity$$),
  ('es', 'matchInspectorLiveActivity', $$Actividad en vivo$$),
  ('he', 'matchInspectorLiveActivity', $$פעילות בזמן אמת$$),

  ('en', 'matchInspectorOnline', $$Online$$),
  ('es', 'matchInspectorOnline', $$En línea$$),
  ('he', 'matchInspectorOnline', $$מחובר$$),

  ('en', 'matchInspectorOffline', $$Offline$$),
  ('es', 'matchInspectorOffline', $$Desconectado$$),
  ('he', 'matchInspectorOffline', $$לא מחובר$$),

  ('en', 'matchInspectorVisible', $$Visible$$),
  ('es', 'matchInspectorVisible', $$Visible$$),
  ('he', 'matchInspectorVisible', $$גלוי$$),

  ('en', 'matchInspectorHidden', $$Hidden$$),
  ('es', 'matchInspectorHidden', $$Oculto$$),
  ('he', 'matchInspectorHidden', $$מוסתר$$),

  ('en', 'matchInspectorGhosted', $$Ghosted$$),
  ('es', 'matchInspectorGhosted', $$Modo fantasma$$),
  ('he', 'matchInspectorGhosted', $$במצב רפאים$$),

  ('en', 'matchInspectorWithinRadius', $$Within radius$$),
  ('es', 'matchInspectorWithinRadius', $$Dentro del radio$$),
  ('he', 'matchInspectorWithinRadius', $$בטווח הרדיוס$$),

  ('en', 'matchInspectorOutOfRadius', $$Exceeds match radius$$),
  ('es', 'matchInspectorOutOfRadius', $$Supera el radio de match$$),
  ('he', 'matchInspectorOutOfRadius', $$חורג מרדיוס ההתאמה$$),

  -- Matrix Table
  ('en', 'matchInspectorPerIntentHeader', $$Active Intent Comparison$$),
  ('es', 'matchInspectorPerIntentHeader', $$Comparación de intenciones activas$$),
  ('he', 'matchInspectorPerIntentHeader', $$השוואת כוונות פעילות$$),

  ('en', 'matchInspectorMatrixHeaderSuffix', $$Matrix$$),
  ('es', 'matchInspectorMatrixHeaderSuffix', $$Matriz$$),
  ('he', 'matchInspectorMatrixHeaderSuffix', $$מטריצה$$),

  ('en', 'matchInspectorMatrixParam', $$Criteria / Filter$$),
  ('es', 'matchInspectorMatrixParam', $$Criterio / Filtro$$),
  ('he', 'matchInspectorMatrixParam', $$קריטריון / מסנן$$),

  ('en', 'matchInspectorMatrixUserA', $$User A (Profile & Wants)$$),
  ('es', 'matchInspectorMatrixUserA', $$Usuario A (Perfil y Deseos)$$),
  ('he', 'matchInspectorMatrixUserA', $$משתמש א' (פרופיל והעדפות)$$),

  ('en', 'matchInspectorMatrixUserB', $$User B (Profile & Wants)$$),
  ('es', 'matchInspectorMatrixUserB', $$Usuario B (Perfil y Deseos)$$),
  ('he', 'matchInspectorMatrixUserB', $$משתמש ב' (פרופיל והעדפות)$$),

  ('en', 'matchInspectorMatrixVerdict', $$Match Verdict$$),
  ('es', 'matchInspectorMatrixVerdict', $$Veredicto$$),
  ('he', 'matchInspectorMatrixVerdict', $$פסק דין$$),

  ('en', 'matchInspectorWants', $$Wants: {val}$$),
  ('es', 'matchInspectorWants', $$Busca: {val}$$),
  ('he', 'matchInspectorWants', $$רוצה: {val}$$),

  ('en', 'matchInspectorCategories', $${count} categories$$),
  ('es', 'matchInspectorCategories', $${count} categorías$$),
  ('he', 'matchInspectorCategories', $${count} קטגוריות$$),

  ('en', 'matchInspectorSharedCount', $${count} Shared$$),
  ('es', 'matchInspectorSharedCount', $${count} Compartidos$$),
  ('he', 'matchInspectorSharedCount', $${count} משותפים$$),

  ('en', 'matchInspectorNoMatch', $$No match$$),
  ('es', 'matchInspectorNoMatch', $$Sin coincidencia$$),
  ('he', 'matchInspectorNoMatch', $$אין התאמה$$),

  ('en', 'matchInspectorPass', $$Pass$$),
  ('es', 'matchInspectorPass', $$Aprobado$$),
  ('he', 'matchInspectorPass', $$עבר$$),

  ('en', 'matchInspectorFail', $$Fail$$),
  ('es', 'matchInspectorFail', $$No aprobado$$),
  ('he', 'matchInspectorFail', $$נכשל$$),

  ('en', 'matchInspectorUnrestricted', $$Unrestricted / Any$$),
  ('es', 'matchInspectorUnrestricted', $$Sin restricción / Cualquiera$$),
  ('he', 'matchInspectorUnrestricted', $$ללא הגבלה / הכל$$),

  ('en', 'matchInspectorEmpty', $$Not set$$),
  ('es', 'matchInspectorEmpty', $$No establecido$$),
  ('he', 'matchInspectorEmpty', $$לא הוגדר$$),

  ('en', 'matchInspectorHeightUnit', $$centimeters$$),
  ('es', 'matchInspectorHeightUnit', $$centímetros$$),
  ('he', 'matchInspectorHeightUnit', $$סנטימטרים$$),

  ('en', 'matchInspectorReasonsHeader', $$Criteria Breakdown$$),
  ('es', 'matchInspectorReasonsHeader', $$Desglose de criterios$$),
  ('he', 'matchInspectorReasonsHeader', $$פירוט קריטריונים$$),

  ('en', 'matchInspectorReasonGender', $$Gender Preference$$),
  ('es', 'matchInspectorReasonGender', $$Preferencia de género$$),
  ('he', 'matchInspectorReasonGender', $$העדפת מגדר$$),

  ('en', 'matchInspectorReasonAge', $$Age Preference$$),
  ('es', 'matchInspectorReasonAge', $$Preferencia de edad$$),
  ('he', 'matchInspectorReasonAge', $$העדפת גיל$$),

  ('en', 'matchInspectorReasonLifestyle', $$Lifestyle Habits$$),
  ('es', 'matchInspectorReasonLifestyle', $$Hábitos de estilo de vida$$),
  ('he', 'matchInspectorReasonLifestyle', $$הרגלי אורח חיים$$),

  ('en', 'matchInspectorReasonFamily', $$Family & Children$$),
  ('es', 'matchInspectorReasonFamily', $$Familia e hijos$$),
  ('he', 'matchInspectorReasonFamily', $$משפחה וילדים$$),

  ('en', 'matchInspectorReasonReligion', $$Religion$$),
  ('es', 'matchInspectorReasonReligion', $$Religión$$),
  ('he', 'matchInspectorReasonReligion', $$דת$$),

  ('en', 'matchInspectorReasonHeight', $$Height Range$$),
  ('es', 'matchInspectorReasonHeight', $$Rango de altura$$),
  ('he', 'matchInspectorReasonHeight', $$טווח גובה$$),

  ('en', 'matchInspectorReasonInterests', $$Shared Interests$$),
  ('es', 'matchInspectorReasonInterests', $$Intereses compartidos$$),
  ('he', 'matchInspectorReasonInterests', $$תחומי עניין משותפים$$),

  ('en', 'matchInspectorReasonSubIntents', $$Sub-Intents Overlap$$),
  ('es', 'matchInspectorReasonSubIntents', $$Sub-intenciones coincidentes$$),
  ('he', 'matchInspectorReasonSubIntents', $$חפיפת תת-כוונות$$),

  ('en', 'matchInspectorSmoking', $$Smoking$$),
  ('es', 'matchInspectorSmoking', $$Fumar$$),
  ('he', 'matchInspectorSmoking', $$עישון$$),

  ('en', 'matchInspectorDrinking', $$Drinking$$),
  ('es', 'matchInspectorDrinking', $$Bebida$$),
  ('he', 'matchInspectorDrinking', $$שתייה$$),

  ('en', 'matchInspectorDiet', $$Diet$$),
  ('es', 'matchInspectorDiet', $$Dieta$$),
  ('he', 'matchInspectorDiet', $$תזונה$$),

  ('en', 'matchInspectorExercise', $$Exercise$$),
  ('es', 'matchInspectorExercise', $$Ejercicio$$),
  ('he', 'matchInspectorExercise', $$כושר גופני$$),

  ('en', 'matchInspectorHasChildren', $$Has Children$$),
  ('es', 'matchInspectorHasChildren', $$Tiene hijos$$),
  ('he', 'matchInspectorHasChildren', $$יש ילדים$$),

  ('en', 'matchInspectorWantsChildren', $$Wants Children$$),
  ('es', 'matchInspectorWantsChildren', $$Desea hijos$$),
  ('he', 'matchInspectorWantsChildren', $$רוצה ילדים$$),

  ('en', 'matchInspectorReligion', $$Religion$$),
  ('es', 'matchInspectorReligion', $$Religión$$),
  ('he', 'matchInspectorReligion', $$דת$$),

  ('en', 'matchInspectorHeight', $$Height$$),
  ('es', 'matchInspectorHeight', $$Altura$$),
  ('he', 'matchInspectorHeight', $$גובה$$),

  ('en', 'matchInspectorInterests', $$Interests Overlap$$),
  ('es', 'matchInspectorInterests', $$Coincidencia de intereses$$),
  ('he', 'matchInspectorInterests', $$חפיפת תחומי עניין$$),

  ('en', 'matchInspectorSubIntents', $$Sub-Intents$$),
  ('es', 'matchInspectorSubIntents', $$Sub-intenciones$$),
  ('he', 'matchInspectorSubIntents', $$תת-כוונות$$),

  ('en', 'matchInspectorMismatch', $$Mismatch$$),
  ('es', 'matchInspectorMismatch', $$Discrepancia$$),
  ('he', 'matchInspectorMismatch', $$אי-התאמה$$),

  ('en', 'matchInspectorMutualPass', $$Mutual Match$$),
  ('es', 'matchInspectorMutualPass', $$Coincidencia mutua$$),
  ('he', 'matchInspectorMutualPass', $$התאמה הדדית$$),

  ('en', 'generalEdit', $$Edit$$),
  ('es', 'generalEdit', $$Editar$$),
  ('he', 'generalEdit', $$ערוך$$),

  ('en', 'generalAdd', $$Select User$$),
  ('es', 'generalAdd', $$Seleccionar usuario$$),
  ('he', 'generalAdd', $$בחר משתמש$$),

  ('en', 'generalCancel', $$Cancel$$),
  ('es', 'generalCancel', $$Cancelar$$),
  ('he', 'generalCancel', $$ביטול$$),

  ('en', 'generalRetry', $$Retry$$),
  ('es', 'generalRetry', $$Reintentar$$),
  ('he', 'generalRetry', $$נסה שוב$$),

  ('en', 'generalLoading', $$Loading...$$),
  ('es', 'generalLoading', $$Cargando...$$),
  ('he', 'generalLoading', $$טוען...$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
