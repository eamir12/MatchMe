-- Onboarding tour feedback round: dedupe + missing coverage.
--  * Intent filters were explained four times (Home3, Home4, Matches4,
--    Chats1). Matches4 keeps the single canonical explanation relating the
--    filters to both Matches and Chats; Home3, Home4 and Chats1 are reworded
--    to describe only their own screen.
--  * Home1 now narrates the online/visible toggle simulation (flip the
--    switch to go invisible, flip it back to come online).
--  * New Nearby4 beat covers the online-by-country world map counts, which
--    the tour never mentioned (the legend row already rendered it).
-- English values intentionally match the built-in fallbacks in
-- locale_provider.dart (later migration wins over earlier seeds).
-- Table: public.translations(locale, key, value)
-- Idempotent: safe to re-run (ON CONFLICT DO UPDATE).

-- English translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'onboardingBeatHome1', 'This is your home screen, your daily dashboard… Everything on MatchMe is reachable from here with one tap. The switch at the top shows you are online and visible… flip it to go invisible, then flip it back to come online again.'),
  ('en', 'onboardingBeatHome3', 'Below, your most recent matches and chats are waiting, so you can pick up right where you left off.'),
  ('en', 'onboardingBeatHome4', 'These chips narrow what you see here… pick friends, dating, or both.'),
  ('en', 'onboardingBeatChats1', 'All your conversations live here… Unread chats are highlighted, so you can jump straight back in.'),
  ('en', 'onboardingBeatNearby4', 'The world map counts online members by country… so you can see where the community is most active right now.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'onboardingBeatHome1', 'Esta es tu pantalla de inicio, tu panel diario… Todo en MatchMe está a un solo toque desde aquí. El interruptor de arriba muestra que estás en línea y visible… tócalo para volverte invisible y tócalo de nuevo para volver a estar en línea.'),
  ('es', 'onboardingBeatHome3', 'Abajo te esperan tus coincidencias y chats más recientes, para que continúes donde lo dejaste.'),
  ('es', 'onboardingBeatHome4', 'Estos chips limitan lo que ves aquí… elige amistad, citas o ambas.'),
  ('es', 'onboardingBeatChats1', 'Todas tus conversaciones viven aquí… Los chats no leídos se destacan, para que retomes donde lo dejaste.'),
  ('es', 'onboardingBeatNearby4', 'El mapa mundial cuenta los miembros en línea por país… así ves dónde está más activa la comunidad ahora mismo.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew translations
INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'onboardingBeatHome1', 'זה מסך הבית שלכם, לוח הבקרה היומי… הכול ב-MatchMe נגיש מכאן בנגיעה אחת. המתג למעלה מראה שאתם מקוונים וגלויים… געו בו כדי להפוך לבלתי נראים, וגעו שוב כדי לחזור להיות מקוונים.'),
  ('he', 'onboardingBeatHome3', 'למטה ממתינות ההתאמות והשיחות האחרונות שלכם, כדי שתוכלו להמשיך בדיוק מהמקום שבו הפסקתם.'),
  ('he', 'onboardingBeatHome4', 'המסננים האלה מצמצמים את מה שאתם רואים כאן… חברות, דייטים או שניהם.'),
  ('he', 'onboardingBeatChats1', 'כל השיחות שלכם נמצאות כאן… שיחות שלא נקראו מסומנות, כדי שתוכלו להמשיך בדיוק מהמקום שבו הפסקתם.'),
  ('he', 'onboardingBeatNearby4', 'מפת העולם סופרת את החברים המקוונים לפי מדינה… כך אתם רואים איפה הקהילה הכי פעילה כרגע.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
