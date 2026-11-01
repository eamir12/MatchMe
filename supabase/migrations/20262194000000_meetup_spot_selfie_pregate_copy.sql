-- Copy for the Spot me single-person selfie gate.
--
-- The gate runs entirely on the device (no AI/server validation), but its
-- rejection and checking messages are user-facing copy, so en/es/he stay
-- aligned. The English fallback also lives in lib/providers/locale_provider.dart.
-- The selfie hint is updated (not added) to state the "only you" rule before
-- the camera opens.

INSERT INTO public.translations (locale, key, value) VALUES
('en', 'photoErrorMultiplePeople',
 'Only you can be in the selfie. Retake it with just yourself in the frame.'),
('en', 'photoErrorPersonCheckUnavailable',
 'This device can''t check who is in the photo. Add outfit details or a note instead.'),
('en', 'photoPrescreenDetailFaces', 'Faces detected'),
('en', 'photoPrescreenDetailBodies', 'Bodies detected'),
('en', 'meetupSpotMeChecking', 'Checking selfie…'),
('en', 'meetupSpotMeSelfieHint',
 'Use your front camera and make sure you''re the only person in the photo. Only the photo is shared.'),
('es', 'photoErrorMultiplePeople',
 'Solo tú puedes aparecer en la selfi. Vuelve a tomarla contigo únicamente en el encuadre.'),
('es', 'photoErrorPersonCheckUnavailable',
 'Este dispositivo no puede comprobar quién aparece en la foto. Añade detalles de tu ropa o una nota.'),
('es', 'photoPrescreenDetailFaces', 'Rostros detectados'),
('es', 'photoPrescreenDetailBodies', 'Cuerpos detectados'),
('es', 'meetupSpotMeChecking', 'Comprobando la selfi…'),
('es', 'meetupSpotMeSelfieHint',
 'Usa la cámara frontal y asegúrate de ser la única persona en la foto. Solo se comparte la foto.'),
('he', 'photoErrorMultiplePeople',
 'רק אתם יכולים להופיע בסלפי. צלמו שוב עם עצמכם בלבד בפריים.'),
('he', 'photoErrorPersonCheckUnavailable',
 'המכשיר הזה לא יכול לבדוק מי בתמונה. הוסיפו פרטי לבוש או הערה במקום.'),
('he', 'photoPrescreenDetailFaces', 'פנים שזוהו'),
('he', 'photoPrescreenDetailBodies', 'גופים שזוהו'),
('he', 'meetupSpotMeChecking', 'בודק את הסלפי…'),
('he', 'meetupSpotMeSelfieHint',
 'השתמשו במצלמה הקדמית וודאו שאתם האדם היחיד בתמונה. רק התמונה משותפת.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
