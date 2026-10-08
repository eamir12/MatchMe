-- Photo prescreen document/occlusion translations (en/es/he)
-- Keys introduced with the prescreen hardening: text-over-face,
-- object-over-face, document-visible-near-face, eyes-closed, the rejection
-- dialog chip label, and the server DOCUMENT_DETECTED fixed messages.
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run.

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'photoErrorTextOverFace', 'A card or text is covering part of your face. Please retake the photo without covering your face.'),
  ('en', 'photoErrorObjectOverFace', 'Something is covering part of your face. Please retake the photo with your face fully visible.'),
  ('en', 'photoErrorDocumentDetected', 'ID cards and documents are not allowed in photos. Please retake the photo without them.'),
  ('en', 'photoErrorEyesClosed', 'Your eyes appear closed. Please retake the photo with your eyes open.'),
  ('en', 'photoIssueDocument', 'ID card / document'),
  ('en', 'primaryPhotoVerificationErrorDocument', 'ID cards and documents are not allowed in photos. Please retake it without them.'),
  ('en', 'secondaryPhotoVerificationErrorDocument', 'ID cards and documents are not allowed in photos. Please use a photo without them.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'photoErrorTextOverFace', 'Una tarjeta o texto está cubriendo parte de tu cara. Vuelve a tomar la foto sin cubrirte la cara.'),
  ('es', 'photoErrorObjectOverFace', 'Algo está cubriendo parte de tu cara. Vuelve a tomar la foto con la cara completamente visible.'),
  ('es', 'photoErrorDocumentDetected', 'No se permiten tarjetas de identidad ni documentos en las fotos. Vuelve a tomar la foto sin ellos.'),
  ('es', 'photoErrorEyesClosed', 'Parece que tienes los ojos cerrados. Vuelve a tomar la foto con los ojos abiertos.'),
  ('es', 'photoIssueDocument', 'Tarjeta / documento'),
  ('es', 'primaryPhotoVerificationErrorDocument', 'No se permiten tarjetas de identidad ni documentos en las fotos. Vuelve a tomarla sin ellos.'),
  ('es', 'secondaryPhotoVerificationErrorDocument', 'No se permiten tarjetas de identidad ni documentos en las fotos. Usa una foto sin ellos.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations (RTL support)
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'photoErrorTextOverFace', 'כרטיס או טקסט מסתירים חלק מהפנים שלך. נא לצלם את התמונה מחדש בלי להסתיר את הפנים.'),
  ('he', 'photoErrorObjectOverFace', 'משהו מסתיר חלק מהפנים שלך. נא לצלם את התמונה מחדש כך שהפנים יהיו גלויים במלואם.'),
  ('he', 'photoErrorDocumentDetected', 'אין לכלול כרטיסי תעודה או מסמכים בתמונות. נא לצלם את התמונה מחדש בלעדיהם.'),
  ('he', 'photoErrorEyesClosed', 'נראה שהעיניים שלך עצומות. נא לצלם את התמונה מחדש כשהעיניים פקוחות.'),
  ('he', 'photoIssueDocument', 'כרטיס / מסמך'),
  ('he', 'primaryPhotoVerificationErrorDocument', 'אין לכלול כרטיסי תעודה או מסמכים בתמונות. נא לצלם מחדש בלעדיהם.'),
  ('he', 'secondaryPhotoVerificationErrorDocument', 'אין לכלול כרטיסי תעודה או מסמכים בתמונות. יש להשתמש בתמונה בלעדיהם.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
