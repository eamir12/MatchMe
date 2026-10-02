BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('verificationCaptureChecklistFaceVisible', 'Face visible', 'en'),
  ('verificationCaptureChecklistHandPositioned', 'Hand in position', 'en'),
  ('verificationCaptureChecklistGestureRecognized', 'Gesture recognized', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO translations (key, value, locale) VALUES
  ('verificationCaptureChecklistFaceVisible', 'Rostro visible', 'es'),
  ('verificationCaptureChecklistHandPositioned', 'Mano en posicion', 'es'),
  ('verificationCaptureChecklistGestureRecognized', 'Gesto reconocido', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO translations (key, value, locale) VALUES
  ('verificationCaptureChecklistFaceVisible', 'הפנים נראות', 'he'),
  ('verificationCaptureChecklistHandPositioned', 'היד במקום', 'he'),
  ('verificationCaptureChecklistGestureRecognized', 'המחווה זוהתה', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

COMMIT;
