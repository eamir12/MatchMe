-- Copy for the redesigned incoming Spot me card.
--
-- The English fallback also lives in lib/providers/locale_provider.dart;
-- these rows keep en/es/he aligned so the card never mixes a translated
-- headline with an English age label.

INSERT INTO public.translations (locale, key, value) VALUES
('en', 'meetupSpotMeNew', 'New'),
('en', 'meetupSpotMeWearing', 'What they’re wearing'),
('en', 'meetupSpotMeNoOutfit', 'No outfit details shared'),
('en', 'meetupSpotMeNoPhotoShared', 'No photo shared'),
('en', 'meetupSpotMeViewPhoto', 'View photo'),
('en', 'meetupSpotMeJustNow', 'just now'),
('en', 'meetupSpotMeMinutesAgo', '{count} min ago'),
('en', 'meetupSpotMeHoursAgo', '{count} h ago'),
('en', 'meetupSpotMeHoursMinutesAgo', '{hours} h {minutes} min ago'),
('es', 'meetupSpotMeNew', 'Nuevo'),
('es', 'meetupSpotMeWearing', 'Lo que lleva puesto'),
('es', 'meetupSpotMeNoOutfit', 'No compartió detalles de su ropa'),
('es', 'meetupSpotMeNoPhotoShared', 'No compartió foto'),
('es', 'meetupSpotMeViewPhoto', 'Ver foto'),
('es', 'meetupSpotMeJustNow', 'ahora mismo'),
('es', 'meetupSpotMeMinutesAgo', 'hace {count} min'),
('es', 'meetupSpotMeHoursAgo', 'hace {count} h'),
('es', 'meetupSpotMeHoursMinutesAgo', 'hace {hours} h {minutes} min'),
('he', 'meetupSpotMeNew', 'חדש'),
('he', 'meetupSpotMeWearing', 'הלבוש שלהם'),
('he', 'meetupSpotMeNoOutfit', 'לא שותפו פרטי לבוש'),
('he', 'meetupSpotMeNoPhotoShared', 'לא שותפה תמונה'),
('he', 'meetupSpotMeViewPhoto', 'הצגת התמונה'),
('he', 'meetupSpotMeJustNow', 'ממש עכשיו'),
('he', 'meetupSpotMeMinutesAgo', 'לפני {count} דק׳'),
('he', 'meetupSpotMeHoursAgo', 'לפני {count} שע׳'),
('he', 'meetupSpotMeHoursMinutesAgo', 'לפני {hours} שע׳ ו-{minutes} דק׳')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
