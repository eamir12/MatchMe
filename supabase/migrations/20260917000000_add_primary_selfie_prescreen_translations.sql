-- Primary selfie prescreen + live-capture translations (en/es/he)
-- Adds face-only primary photo failure messages and the live primary-selfie
-- capture strings (face-only mode of the shared MediaPipe capture page).
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run.

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'photoErrorNoFaceDetected', 'No face found. Your first photo must be a clear selfie showing only your face.'),
  ('en', 'photoErrorBodyShotNotAllowed', 'The first photo must be a face-only selfie. Body shots are not allowed.'),
  ('en', 'primarySelfieCaptureInstruction', 'Face the camera — fit your face inside the oval'),
  ('en', 'primarySelfieCaptureDescription', 'Only you in the frame. Keep your face clearly visible with good lighting.'),
  ('en', 'primarySelfieCaptureLoading', 'Loading camera & face detection...')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'photoErrorNoFaceDetected', 'No se encontró ningún rostro. Tu primera foto debe ser una selfie clara que muestre solo tu rostro.'),
  ('es', 'photoErrorBodyShotNotAllowed', 'La primera foto debe ser una selfie solo del rostro. No se permiten fotos de cuerpo.'),
  ('es', 'primarySelfieCaptureInstruction', 'Mira a la cámara — ajusta tu rostro dentro del óvalo'),
  ('es', 'primarySelfieCaptureDescription', 'Solo tú en el encuadre. Mantén tu rostro claramente visible con buena iluminación.'),
  ('es', 'primarySelfieCaptureLoading', 'Cargando cámara y detección de rostro...')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations (RTL support)
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'photoErrorNoFaceDetected', 'לא נמצאו פנים. התמונה הראשונה שלך חייבת להיות סלפי ברור המציג רק את הפנים שלך.'),
  ('he', 'photoErrorBodyShotNotAllowed', 'התמונה הראשונה חייבת להיות סלפי של הפנים בלבד. תמונות גוף אינן מותרות.'),
  ('he', 'primarySelfieCaptureInstruction', 'הבט למצלמה — מקם את הפנים בתוך האליפסה'),
  ('he', 'primarySelfieCaptureDescription', 'רק אתה בפריים. שמור על פנים ברורות עם תאורה טובה.'),
  ('he', 'primarySelfieCaptureLoading', 'טוען מצלמה וזיהוי פנים...')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
