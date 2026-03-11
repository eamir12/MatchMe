BEGIN;

INSERT INTO public.translations (locale, key, value)
VALUES
  ('en', 'profileEditFileBytesMissing', $$Could not read the selected file. Please pick another file.$$),
  ('es', 'profileEditFileBytesMissing', $$No se pudo leer el archivo seleccionado. Elige otro archivo.$$),
  ('he', 'profileEditFileBytesMissing', $$לא ניתן לקרוא את הקובץ שנבחר. נסו לבחור קובץ אחר.$$),

  ('en', 'profileEditAttachmentTooLarge', $$File is too large. Max size is {maxMb} MB.$$),
  ('es', 'profileEditAttachmentTooLarge', $$El archivo es demasiado grande. El tamaño máximo es {maxMb} MB.$$),
  ('he', 'profileEditAttachmentTooLarge', $$הקובץ גדול מדי. הגודל המקסימלי הוא {maxMb} MB.$$),

  ('en', 'profileEditAttachmentInvalidType', $$Unsupported file type. Allowed: {types}.$$),
  ('es', 'profileEditAttachmentInvalidType', $$Tipo de archivo no compatible. Permitidos: {types}.$$),
  ('he', 'profileEditAttachmentInvalidType', $$סוג קובץ לא נתמך. מותר: {types}.$$),

  ('en', 'profileEditAttachmentUploadFailed', $$Upload failed for "{file}". Please try again.$$),
  ('es', 'profileEditAttachmentUploadFailed', $$La carga falló para "{file}". Inténtalo de nuevo.$$),
  ('he', 'profileEditAttachmentUploadFailed', $$ההעלאה נכשלה עבור "{file}". נסו שוב.$$),

  ('en', 'adminAttachmentNotPreviewable', $$This file cannot be previewed here. Copy the link to open it.$$),
  ('es', 'adminAttachmentNotPreviewable', $$Este archivo no se puede previsualizar aquí. Copia el enlace para abrirlo.$$),
  ('he', 'adminAttachmentNotPreviewable', $$לא ניתן להציג קובץ זה כאן. העתיקו את הקישור כדי לפתוח אותו.$$),

  ('en', 'adminAttachmentOpenInSystem', $$Open in system$$),
  ('es', 'adminAttachmentOpenInSystem', $$Abrir en el sistema$$),
  ('he', 'adminAttachmentOpenInSystem', $$פתיחה במערכת$$),

  ('en', 'adminAttachmentOpenFailed', $$Failed to open attachment.$$),
  ('es', 'adminAttachmentOpenFailed', $$No se pudo abrir el archivo adjunto.$$),
  ('he', 'adminAttachmentOpenFailed', $$לא ניתן לפתוח את הקובץ המצורף.$$),

  ('en', 'adminAttachmentCopyLink', $$Copy link$$),
  ('es', 'adminAttachmentCopyLink', $$Copiar enlace$$),
  ('he', 'adminAttachmentCopyLink', $$העתקת קישור$$),

  ('en', 'adminAttachmentLinkCopied', $$Link copied.$$),
  ('es', 'adminAttachmentLinkCopied', $$Enlace copiado.$$),
  ('he', 'adminAttachmentLinkCopied', $$הקישור הועתק.$$)
ON CONFLICT (locale, key) DO UPDATE
SET value = EXCLUDED.value;

COMMIT;
