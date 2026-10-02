BEGIN;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'profileWizardPhotoUploadFailed', $$We couldn't add that photo right now.$$),
    ('es', 'profileWizardPhotoUploadFailed', $$No pudimos agregar esa foto en este momento.$$),
    ('he', 'profileWizardPhotoUploadFailed', $$לא הצלחנו להוסיף את התמונה הזו כרגע.$$),
    ('en', 'profileWizardPhotoUploadFailedWithReason', $$We couldn't add that photo. {reason}$$),
    ('es', 'profileWizardPhotoUploadFailedWithReason', $$No pudimos agregar esa foto. {reason}$$),
    ('he', 'profileWizardPhotoUploadFailedWithReason', $$לא הצלחנו להוסיף את התמונה הזו. {reason}$$),
    ('en', 'profileWizardPhotosTip', $$Your first photo must be a clear solo face photo of you. Additional photos must show a real person and cannot be screenshots, memes, prominent text, watermarks, or explicit content.$$),
    ('es', 'profileWizardPhotosTip', $$Tu primera foto debe ser una foto clara solo de tu rostro. Las fotos adicionales deben mostrar a una persona real y no pueden ser capturas de pantalla, memes, texto destacado, marcas de agua ni contenido explícito.$$),
    ('he', 'profileWizardPhotosTip', $$התמונה הראשונה חייבת להיות תמונת פנים ברורה שלך בלבד. התמונות הנוספות חייבות להציג אדם אמיתי ואסור שיהיו צילומי מסך, ממים, טקסט בולט, סימני מים או תוכן מיני מפורש.$$),
    ('en', 'profileWizardPrimaryPhotoFaceOnlyTitle', $$Photo rules$$),
    ('es', 'profileWizardPrimaryPhotoFaceOnlyTitle', $$Reglas de las fotos$$),
    ('he', 'profileWizardPrimaryPhotoFaceOnlyTitle', $$כללי התמונות$$),
    ('en', 'profileWizardPrimaryPhotoFaceOnlyBody', $$Your first photo must be a clear solo face photo of you. Additional photos must show a real person and cannot be screenshots, memes, prominent text, watermarks, or explicit content.$$),
    ('es', 'profileWizardPrimaryPhotoFaceOnlyBody', $$Tu primera foto debe ser una foto clara solo de tu rostro. Las fotos adicionales deben mostrar a una persona real y no pueden ser capturas de pantalla, memes, texto destacado, marcas de agua ni contenido explícito.$$),
    ('he', 'profileWizardPrimaryPhotoFaceOnlyBody', $$התמונה הראשונה חייבת להיות תמונת פנים ברורה שלך בלבד. התמונות הנוספות חייבות להציג אדם אמיתי ואסור שיהיו צילומי מסך, ממים, טקסט בולט, סימני מים או תוכן מיני מפורש.$$),
    ('en', 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark', $$Choose a real photo of yourself with no screenshots, memes, large text, or watermarks.$$),
    ('es', 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark', $$Elige una foto real tuya, sin capturas de pantalla, memes, texto grande ni marcas de agua.$$),
    ('he', 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark', $$יש לבחור תמונה אמיתית שלך ללא צילומי מסך, ממים, טקסט גדול או סימני מים.$$)
)
UPDATE translations AS t
SET value = translation_values.value,
    updated_at = now()
FROM translation_values
WHERE t.locale = translation_values.locale
  AND t.key = translation_values.key;

WITH translation_values(locale, key, value) AS (
  VALUES
    ('en', 'profileWizardPhotoUploadFailed', $$We couldn't add that photo right now.$$),
    ('es', 'profileWizardPhotoUploadFailed', $$No pudimos agregar esa foto en este momento.$$),
    ('he', 'profileWizardPhotoUploadFailed', $$לא הצלחנו להוסיף את התמונה הזו כרגע.$$),
    ('en', 'profileWizardPhotoUploadFailedWithReason', $$We couldn't add that photo. {reason}$$),
    ('es', 'profileWizardPhotoUploadFailedWithReason', $$No pudimos agregar esa foto. {reason}$$),
    ('he', 'profileWizardPhotoUploadFailedWithReason', $$לא הצלחנו להוסיף את התמונה הזו. {reason}$$),
    ('en', 'profileWizardPhotosTip', $$Your first photo must be a clear solo face photo of you. Additional photos must show a real person and cannot be screenshots, memes, prominent text, watermarks, or explicit content.$$),
    ('es', 'profileWizardPhotosTip', $$Tu primera foto debe ser una foto clara solo de tu rostro. Las fotos adicionales deben mostrar a una persona real y no pueden ser capturas de pantalla, memes, texto destacado, marcas de agua ni contenido explícito.$$),
    ('he', 'profileWizardPhotosTip', $$התמונה הראשונה חייבת להיות תמונת פנים ברורה שלך בלבד. התמונות הנוספות חייבות להציג אדם אמיתי ואסור שיהיו צילומי מסך, ממים, טקסט בולט, סימני מים או תוכן מיני מפורש.$$),
    ('en', 'profileWizardPrimaryPhotoFaceOnlyTitle', $$Photo rules$$),
    ('es', 'profileWizardPrimaryPhotoFaceOnlyTitle', $$Reglas de las fotos$$),
    ('he', 'profileWizardPrimaryPhotoFaceOnlyTitle', $$כללי התמונות$$),
    ('en', 'profileWizardPrimaryPhotoFaceOnlyBody', $$Your first photo must be a clear solo face photo of you. Additional photos must show a real person and cannot be screenshots, memes, prominent text, watermarks, or explicit content.$$),
    ('es', 'profileWizardPrimaryPhotoFaceOnlyBody', $$Tu primera foto debe ser una foto clara solo de tu rostro. Las fotos adicionales deben mostrar a una persona real y no pueden ser capturas de pantalla, memes, texto destacado, marcas de agua ni contenido explícito.$$),
    ('he', 'profileWizardPrimaryPhotoFaceOnlyBody', $$התמונה הראשונה חייבת להיות תמונת פנים ברורה שלך בלבד. התמונות הנוספות חייבות להציג אדם אמיתי ואסור שיהיו צילומי מסך, ממים, טקסט בולט, סימני מים או תוכן מיני מפורש.$$),
    ('en', 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark', $$Choose a real photo of yourself with no screenshots, memes, large text, or watermarks.$$),
    ('es', 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark', $$Elige una foto real tuya, sin capturas de pantalla, memes, texto grande ni marcas de agua.$$),
    ('he', 'secondaryPhotoVerificationErrorTextScreenshotOrWatermark', $$יש לבחור תמונה אמיתית שלך ללא צילומי מסך, ממים, טקסט גדול או סימני מים.$$)
)
INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), translation_values.locale, translation_values.key, translation_values.value, now(), now()
FROM translation_values
WHERE NOT EXISTS (
  SELECT 1
  FROM translations t
  WHERE t.locale = translation_values.locale
    AND t.key = translation_values.key
);

COMMIT;
