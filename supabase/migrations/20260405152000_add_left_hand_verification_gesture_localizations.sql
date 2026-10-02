BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('verificationGestureClosedFistLeftTitle', 'Show a closed fist with your left hand', 'en'),
  ('verificationGestureClosedFistLeftDescription', 'Show a closed fist with your left hand next to your face.', 'en'),
  ('verificationGestureOpenPalmLeftTitle', 'Show an open palm with your left hand', 'en'),
  ('verificationGestureOpenPalmLeftDescription', 'Show an open palm with your left hand next to your face, with your fingers fully visible.', 'en'),
  ('verificationGesturePeaceSignLeftTitle', 'Show a peace sign with your left hand', 'en'),
  ('verificationGesturePeaceSignLeftDescription', 'Show a V-shaped peace sign with your left hand next to your face.', 'en'),
  ('verificationGesturePointingUpLeftTitle', 'Point up with your left index finger', 'en'),
  ('verificationGesturePointingUpLeftDescription', 'Point up with your left index finger next to your face.', 'en'),
  ('verificationGestureThumbsDownLeftTitle', 'Show a thumbs-down with your left hand', 'en'),
  ('verificationGestureThumbsDownLeftDescription', 'Show a clear thumbs-down with your left hand next to your face.', 'en'),
  ('verificationGestureThumbsUpLeftTitle', 'Show a thumbs-up with your left hand', 'en'),
  ('verificationGestureThumbsUpLeftDescription', 'Show a clear thumbs-up with your left hand next to your face.', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO translations (key, value, locale) VALUES
  ('verificationGestureClosedFistLeftTitle', 'Muestra un puno cerrado con tu mano izquierda', 'es'),
  ('verificationGestureClosedFistLeftDescription', 'Muestra un puno cerrado con tu mano izquierda junto a tu rostro.', 'es'),
  ('verificationGestureOpenPalmLeftTitle', 'Muestra una palma abierta con tu mano izquierda', 'es'),
  ('verificationGestureOpenPalmLeftDescription', 'Muestra una palma abierta con tu mano izquierda junto a tu rostro, con todos los dedos visibles.', 'es'),
  ('verificationGesturePeaceSignLeftTitle', 'Muestra una senal de paz con tu mano izquierda', 'es'),
  ('verificationGesturePeaceSignLeftDescription', 'Muestra una senal de paz en forma de V con tu mano izquierda junto a tu rostro.', 'es'),
  ('verificationGesturePointingUpLeftTitle', 'Apunta hacia arriba con tu dedo indice izquierdo', 'es'),
  ('verificationGesturePointingUpLeftDescription', 'Apunta hacia arriba con tu dedo indice izquierdo junto a tu rostro.', 'es'),
  ('verificationGestureThumbsDownLeftTitle', 'Muestra un pulgar hacia abajo con tu mano izquierda', 'es'),
  ('verificationGestureThumbsDownLeftDescription', 'Muestra claramente un pulgar hacia abajo con tu mano izquierda junto a tu rostro.', 'es'),
  ('verificationGestureThumbsUpLeftTitle', 'Muestra un pulgar hacia arriba con tu mano izquierda', 'es'),
  ('verificationGestureThumbsUpLeftDescription', 'Muestra claramente un pulgar hacia arriba con tu mano izquierda junto a tu rostro.', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO translations (key, value, locale) VALUES
  ('verificationGestureClosedFistLeftTitle', 'הראה/י אגרוף קמוץ ביד שמאל', 'he'),
  ('verificationGestureClosedFistLeftDescription', 'הראה/י אגרוף קמוץ ביד שמאל ליד הפנים.', 'he'),
  ('verificationGestureOpenPalmLeftTitle', 'הראה/י כף יד פתוחה ביד שמאל', 'he'),
  ('verificationGestureOpenPalmLeftDescription', 'הראה/י כף יד פתוחה ביד שמאל ליד הפנים, כך שכל האצבעות נראות.', 'he'),
  ('verificationGesturePeaceSignLeftTitle', 'הראה/י סימן שלום ביד שמאל', 'he'),
  ('verificationGesturePeaceSignLeftDescription', 'הראה/י סימן שלום בצורת V ביד שמאל ליד הפנים.', 'he'),
  ('verificationGesturePointingUpLeftTitle', 'הצביע/י למעלה עם האצבע המורה של יד שמאל', 'he'),
  ('verificationGesturePointingUpLeftDescription', 'הצביע/י למעלה עם האצבע המורה של יד שמאל ליד הפנים.', 'he'),
  ('verificationGestureThumbsDownLeftTitle', 'הראה/י אגודל למטה ביד שמאל', 'he'),
  ('verificationGestureThumbsDownLeftDescription', 'הראה/י אגודל ברור למטה ביד שמאל ליד הפנים.', 'he'),
  ('verificationGestureThumbsUpLeftTitle', 'הראה/י אגודל למעלה ביד שמאל', 'he'),
  ('verificationGestureThumbsUpLeftDescription', 'הראה/י אגודל ברור למעלה ביד שמאל ליד הפנים.', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

COMMIT;
