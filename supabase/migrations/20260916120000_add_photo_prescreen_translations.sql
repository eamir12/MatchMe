-- Photo prescreen translations (en/es/he)
-- Covers prescreen failure messages, the failure-dialog actions, and the
-- visual photo-rules card shown on the profile wizard's photo step.
-- Table structure: public.translations(locale, key, value)
-- Idempotent: safe to re-run.

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'photoErrorInvalidFormat', 'Invalid image format. Please use JPEG, PNG, or WEBP.'),
  ('en', 'photoErrorFileTooLarge', 'File is too large. Maximum size is 10MB.'),
  ('en', 'photoErrorFileTooSmall', 'File is too small. Minimum size is 10KB.'),
  ('en', 'photoErrorResolutionTooLow', 'Image resolution too low. Minimum resolution is 200x200 for secondary photos and 400x400 for primary photos.'),
  ('en', 'photoErrorAspectRatioInvalid', 'Image aspect ratio not supported. Aspect ratio must be between 0.33 and 3.0.'),
  ('en', 'photoErrorImageCorrupted', 'Image file is corrupted or invalid.'),
  ('en', 'photoErrorDuplicatePhoto', 'This photo has already been added to your profile.'),
  ('en', 'photoErrorNoFaceOrBody', 'Photo must show at least your face or body clearly.'),
  ('en', 'photoErrorMultipleFaces', 'Primary photo must show only you (no group photos).'),
  ('en', 'photoErrorFaceTooSmall', 'Face is too small in the photo. Please use a photo where your face is clearly visible.'),
  ('en', 'photoErrorFaceNotVisible', 'Face is not clearly visible. Please use a clearer photo.'),
  ('en', 'photoErrorImageTooBlurry', 'Image is too blurry. Please use a sharper photo.'),
  ('en', 'photoErrorImageTooDark', 'Image is too dark. Please use a brighter photo.'),
  ('en', 'photoErrorImageTooBright', 'Image is too bright. Please use a photo with better lighting.'),
  ('en', 'photoErrorGeneral', 'Photo validation failed. Please try a different photo.'),
  ('en', 'photoPrescreenFailedTitle', 'Photo needs a small fix'),
  ('en', 'photoPrescreenAdjustPhoto', 'Adjust photo'),
  ('en', 'photoPrescreenChooseAnother', 'Choose another photo'),
  ('en', 'photoRulesTitle', 'Photo rules'),
  ('en', 'photoRulePrimaryFace', 'Your first photo must be a clear solo photo of your face.'),
  ('en', 'photoRuleOnlyYou', 'Only you in the first photo — no group shots.'),
  ('en', 'photoRuleClearPhoto', 'Well-lit, sharp, and not heavily edited.'),
  ('en', 'photoRuleRealPerson', 'Real photos of you — no screenshots, memes, or watermarks.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'photoErrorInvalidFormat', 'Formato de imagen no válido. Por favor usa JPEG, PNG o WEBP.'),
  ('es', 'photoErrorFileTooLarge', 'El archivo es demasiado grande. El tamaño máximo es 10MB.'),
  ('es', 'photoErrorFileTooSmall', 'El archivo es demasiado pequeño. El tamaño mínimo es 10KB.'),
  ('es', 'photoErrorResolutionTooLow', 'Resolución de imagen demasiado baja. La resolución mínima es 200x200 para fotos secundarias y 400x400 para fotos principales.'),
  ('es', 'photoErrorAspectRatioInvalid', 'Relación de aspecto de imagen no soportada. La relación de aspecto debe estar entre 0.33 y 3.0.'),
  ('es', 'photoErrorImageCorrupted', 'El archivo de imagen está corrupto o no es válido.'),
  ('es', 'photoErrorDuplicatePhoto', 'Esta foto ya fue agregada a tu perfil.'),
  ('es', 'photoErrorNoFaceOrBody', 'La foto debe mostrar claramente al menos tu cara o cuerpo.'),
  ('es', 'photoErrorMultipleFaces', 'La foto principal debe mostrarte solo a ti (sin fotos grupales).'),
  ('es', 'photoErrorFaceTooSmall', 'La cara es demasiado pequeña en la foto. Por favor usa una foto donde tu cara sea claramente visible.'),
  ('es', 'photoErrorFaceNotVisible', 'La cara no es claramente visible. Por favor usa una foto más clara.'),
  ('es', 'photoErrorImageTooBlurry', 'La imagen está demasiado borrosa. Por favor usa una foto más nítida.'),
  ('es', 'photoErrorImageTooDark', 'La imagen está demasiado oscura. Por favor usa una foto más brillante.'),
  ('es', 'photoErrorImageTooBright', 'La imagen está demasiado brillante. Por favor usa una foto con mejor iluminación.'),
  ('es', 'photoErrorGeneral', 'La validación de foto falló. Por favor intenta con una foto diferente.'),
  ('es', 'photoPrescreenFailedTitle', 'La foto necesita un pequeño ajuste'),
  ('es', 'photoPrescreenAdjustPhoto', 'Ajustar foto'),
  ('es', 'photoPrescreenChooseAnother', 'Elegir otra foto'),
  ('es', 'photoRulesTitle', 'Reglas de las fotos'),
  ('es', 'photoRulePrimaryFace', 'Tu primera foto debe ser una foto clara solo de tu rostro.'),
  ('es', 'photoRuleOnlyYou', 'Solo tú en la primera foto, sin fotos grupales.'),
  ('es', 'photoRuleClearPhoto', 'Bien iluminada, nítida y sin ediciones pesadas.'),
  ('es', 'photoRuleRealPerson', 'Fotos reales de ti: sin capturas de pantalla, memes ni marcas de agua.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations (RTL support)
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'photoErrorInvalidFormat', 'פורמט תמונה לא חוקי. אנא השתמש ב-JPEG, PNG או WEBP.'),
  ('he', 'photoErrorFileTooLarge', 'הקובץ גדול מדי. הגודל המקסימלי הוא 10MB.'),
  ('he', 'photoErrorFileTooSmall', 'הקובץ קטן מדי. הגודל המינימלי הוא 10KB.'),
  ('he', 'photoErrorResolutionTooLow', 'רזולוציית התמונה נמוכה מדי. הרזולוציה המינימלית היא 200x200 לתמונות משנה ו-400x400 לתמונות ראשיות.'),
  ('he', 'photoErrorAspectRatioInvalid', 'יחס גובה-רוחב של התמונה לא נתמך. יחס הגובה-רוחב חייב להיות בין 0.33 ל-3.0.'),
  ('he', 'photoErrorImageCorrupted', 'קובץ התמונה פגום או לא חוקי.'),
  ('he', 'photoErrorDuplicatePhoto', 'התמונה הזו כבר נוספה לפרופיל שלך.'),
  ('he', 'photoErrorNoFaceOrBody', 'התמונה חייבת להציג לפחות את הפנים או הגוף שלך בבירור.'),
  ('he', 'photoErrorMultipleFaces', 'התמונה הראשית חייבת להציג רק אותך (ללא תמונות קבוצתיות).'),
  ('he', 'photoErrorFaceTooSmall', 'הפנים קטנים מדי בתמונה. אנא השתמש בתמונה שבה הפנים שלך ברורים.'),
  ('he', 'photoErrorFaceNotVisible', 'הפנים לא ברורים. אנא השתמש בתמונה ברורה יותר.'),
  ('he', 'photoErrorImageTooBlurry', 'התמונה מטושטשת מדי. אנא השתמש בתמונה חדה יותר.'),
  ('he', 'photoErrorImageTooDark', 'התמונה כהה מדי. אנא השתמש בתמונה בהירה יותר.'),
  ('he', 'photoErrorImageTooBright', 'התמונה בהירה מדי. אנא השתמש בתמונה עם תאורה טובה יותר.'),
  ('he', 'photoErrorGeneral', 'אימות התמונה נכשל. אנא נסה תמונה אחרת.'),
  ('he', 'photoPrescreenFailedTitle', 'התמונה צריכה תיקון קטן'),
  ('he', 'photoPrescreenAdjustPhoto', 'התאם תמונה'),
  ('he', 'photoPrescreenChooseAnother', 'בחר תמונה אחרת'),
  ('he', 'photoRulesTitle', 'כללי התמונות'),
  ('he', 'photoRulePrimaryFace', 'התמונה הראשונה חייבת להיות תמונה ברורה של הפנים שלך בלבד.'),
  ('he', 'photoRuleOnlyYou', 'רק אתה בתמונה הראשונה — בלי תמונות קבוצתיות.'),
  ('he', 'photoRuleClearPhoto', 'תאורה טובה, חדה וללא עריכות כבדות.'),
  ('he', 'photoRuleRealPerson', 'תמונות אמיתיות שלך — בלי צילומי מסך, ממים או סימני מים.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
