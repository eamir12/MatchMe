-- Migration: Shared movement (co-motion) match copy + settings subtitles
-- Date: 2026-10-05
--
-- 1) matchReasonMovingTogether - match profile basis row title for
--    match_type = 'co_motion' (already rendered by match_profile_screen.dart).
-- 2) matchedByCoMotionLabel - matches-list reason line label (parallels
--    matchedByProximityLabel 'Proximity').
-- 3) Subtitles for the two matching toggles, which previously had no
--    description of what they do.

INSERT INTO translations (locale, key, value) VALUES
  ('en', 'matchReasonMovingTogether', 'Moving together'),
  ('he', 'matchReasonMovingTogether', 'תנועה משותפת'),
  ('es', 'matchReasonMovingTogether', 'Movimiento compartido'),
  ('en', 'matchedByCoMotionLabel', 'Shared movement'),
  ('he', 'matchedByCoMotionLabel', 'תנועה משותפת'),
  ('es', 'matchedByCoMotionLabel', 'Movimiento compartido'),
  ('en', 'settingsSharedEventMatchingSubtitle', 'Get matched with people attending the same events as you.'),
  ('he', 'settingsSharedEventMatchingSubtitle', 'התאמה עם אנשים שמשתתפים באותם אירועים כמוך.'),
  ('es', 'settingsSharedEventMatchingSubtitle', 'Recibe matches con personas que asisten a los mismos eventos que tú.'),
  ('en', 'settingsSharedMovementMatchingSubtitle', 'When you and another person are detected moving together (similar direction and speed), matching may temporarily look slightly beyond your radius. It returns to normal once the shared movement ends.'),
  ('he', 'settingsSharedMovementMatchingSubtitle', 'כאשר מזוהה שאתה ואדם נוסף נעים יחד (בכיוון ובמהירות דומים), ההתאמה עשויה להתרחב זמנית מעט מעבר לרדיוס שהוגדר. היא חוזרת לקדמותה עם סיום התנועה המשותפת.'),
  ('es', 'settingsSharedMovementMatchingSubtitle', 'Cuando se detecta que tú y otra persona se mueven juntos (dirección y velocidad similares), la búsqueda puede ampliarse temporalmente un poco más allá de tu radio. Vuelve a la normalidad cuando termina el movimiento compartido.')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value;
