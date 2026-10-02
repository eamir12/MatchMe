-- Onboarding tour second feedback round.
--  * Home1 now narrates the automatic online → invisible → online switch
--    demo (the wizard performs it, the user only watches).
--  * Chats2 no longer claims end-to-end encryption: messages are encrypted
--    and stored securely, with an encrypted copy on the device (chat
--    translation is incompatible with an end-to-end claim).
--  * Events1 explains shared events as the alternative to being in the same
--    radius right now (same place in the future, when the event happens).
--  * New world-map chapter (separate screen, as in the real app) with its
--    title and two beats, plus a second, distinct demo event.
-- English values intentionally match the built-in fallbacks in
-- locale_provider.dart (later migration wins over earlier seeds).
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run (ON CONFLICT DO UPDATE).

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'onboardingBeatHome1', 'This is your home screen, your daily dashboard… Everything on MatchMe is reachable from here with one tap. Watch the switch at the top: it takes you offline and invisible… then brings you back online again.'),
  ('en', 'onboardingBeatChats2', 'Messages are encrypted and stored securely, with an encrypted copy on your device… They can even be translated automatically, so language is never a barrier. You can block or report anyone, and share your live location with one match at a time.'),
  ('en', 'onboardingBeatEvents1', 'Shared events are an alternative to being in the same radius right now… You will be in the same place in the future, when the event happens. Import from your calendar, upload a PDF ticket, paste an event link, or create one manually.'),
  ('en', 'onboardingChapterWorldMap', 'Online around the world'),
  ('en', 'onboardingBeatWorldMap1', 'This is the online world map, opened from your home screen… The pill up top shows how many members are online right now.'),
  ('en', 'onboardingBeatWorldMap2', 'Each label counts the online members in that country… so you can see where the community is most active.'),
  ('en', 'demoEventTitle2', 'Rooftop jazz night'),
  ('en', 'demoEventMeta2', 'Old Town · Friday 20:00')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'onboardingBeatHome1', 'Esta es tu pantalla de inicio, tu panel diario… Todo en MatchMe está a un solo toque desde aquí. Mira el interruptor de arriba: te pone invisible por un momento… y luego te devuelve en línea.'),
  ('es', 'onboardingBeatChats2', 'Los mensajes están cifrados y se guardan de forma segura, con una copia cifrada en tu dispositivo… Incluso pueden traducirse automáticamente, para que el idioma nunca sea una barrera. Puedes bloquear o denunciar a cualquiera, y compartir tu ubicación en vivo con una coincidencia a la vez.'),
  ('es', 'onboardingBeatEvents1', 'Los eventos compartidos son una alternativa a estar en el mismo radio ahora mismo… Estarán en el mismo lugar en el futuro, cuando ocurra el evento. Importa desde tu calendario, sube un boleto en PDF, pega un enlace del evento o créalo manualmente.'),
  ('es', 'onboardingChapterWorldMap', 'En línea en el mundo'),
  ('es', 'onboardingBeatWorldMap1', 'Este es el mapa mundial en línea, abierto desde tu pantalla de inicio… La píldora de arriba muestra cuántos miembros están en línea ahora mismo.'),
  ('es', 'onboardingBeatWorldMap2', 'Cada etiqueta cuenta los miembros en línea en ese país… así ves dónde está más activa la comunidad.'),
  ('es', 'demoEventTitle2', 'Noche de jazz en la azotea'),
  ('es', 'demoEventMeta2', 'Casco antiguo · viernes 20:00')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'onboardingBeatHome1', 'זה מסך הבית שלכם, לוח הבקרה היומי… הכול ב-MatchMe נגיש מכאן בנגיעה אחת. צפו במתג למעלה: הוא הופך אתכם לבלתי נראים לרגע… ואז מחזיר אתכם למקוון.'),
  ('he', 'onboardingBeatChats2', 'ההודעות מוצפנות ונשמרות בצורה מאובטחת, עם עותק מוצפן במכשיר שלכם… אפשר גם לתרגם אותן אוטומטית, כדי ששפה לא תהיה מחסום. אפשר לחסום או לדווח על כל אחד, ולשתף את המיקום החי עם התאמה אחת בכל פעם.'),
  ('he', 'onboardingBeatEvents1', 'אירועים משותפים הם אלטרנטיבה להיות באותו רדיוס כרגע… אתם תהיו באותו מקום בעתיד, כשהאירוע יתקיים. ייבאו מהיומן שלכם, העלו כרטיס PDF, הדביקו קישור לאירוע, או צרו אחד ידנית.'),
  ('he', 'onboardingChapterWorldMap', 'מקוונים ברחבי העולם'),
  ('he', 'onboardingBeatWorldMap1', 'זוהי מפת העולם המקוונת, שנפתחת ממסך הבית שלכם… הבועה למעלה מראה כמה חברים מקוונים כרגע.'),
  ('he', 'onboardingBeatWorldMap2', 'כל תווית סופרת את החברים המקוונים באותה מדינה… כך אתם רואים איפה הקהילה הכי פעילה.'),
  ('he', 'demoEventTitle2', 'ערב ג׳אז על הגג'),
  ('he', 'demoEventMeta2', 'העיר העתיקה · יום שישי 20:00')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
