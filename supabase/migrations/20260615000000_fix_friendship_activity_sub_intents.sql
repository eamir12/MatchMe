-- Fix Friendship and Activity Partner sub-intents
-- Removes activity-focused items from Friendship (parent_id=2) and moves them to Activity Partner (parent_id=3)
-- Adds relationship-focused Friendship sub-intents

BEGIN;

-- ============================================================
-- DELETE old Friendship sub-intents and their translations
-- ============================================================

DELETE FROM public.translations WHERE key IN (
  'intent.friendship.gym_buddy',
  'intent.friendship.movie_buddy',
  'intent.friendship.food_buddy',
  'intent.friendship.coffee_buddy',
  'intent.friendship.walking_buddy',
  'intent.friendship.language_exchange',
  'intent.friendship.music_buddy',
  'intent.friendship.networking',
  'intent.friendship.book_club',
  'intent.friendship.board_game_buddy',
  'intent.friendship.pet_buddy',
  'intent.friendship.shopping_buddy',
  'intent.friendship.volunteer_buddy',
  'intent.friendship.concert_buddy',
  'intent.friendship.art_buddy',
  'intent.friendship.karaoke_buddy',
  'intent.friendship.dance_partner',
  'intent.friendship.outdoor_buddy',
  'intent.friendship.photo_buddy'
);

DELETE FROM public.intents WHERE key IN (
  'friendship::gym_buddy',
  'friendship::movie_buddy',
  'friendship::food_buddy',
  'friendship::coffee_buddy',
  'friendship::walking_buddy',
  'friendship::language_exchange',
  'friendship::music_buddy',
  'friendship::networking',
  'friendship::book_club',
  'friendship::board_game_buddy',
  'friendship::pet_buddy',
  'friendship::shopping_buddy',
  'friendship::volunteer_buddy',
  'friendship::concert_buddy',
  'friendship::art_buddy',
  'friendship::karaoke_buddy',
  'friendship::dance_partner',
  'friendship::outdoor_buddy',
  'friendship::photo_buddy'
);

-- ============================================================
-- INSERT new Friendship sub-intents (relationship-focused)
-- ============================================================

INSERT INTO public.intents (parent_id, key, translation_key, sort_order, is_social, is_business) VALUES
  (2, 'friendship::casual',          'intent.friendship.casual',          225, true, false),
  (2, 'friendship::deep_connection', 'intent.friendship.deep_connection', 226, true, false),
  (2, 'friendship::new_in_town',     'intent.friendship.new_in_town',     227, true, false),
  (2, 'friendship::student_life',    'intent.friendship.student_life',    228, true, false),
  (2, 'friendship::expats',          'intent.friendship.expats',          229, true, false),
  (2, 'friendship::neighbors',       'intent.friendship.neighbors',       230, true, false),
  (2, 'friendship::lgbtqia',         'intent.friendship.lgbtqia',         231, true, false),
  (2, 'friendship::spiritual',       'intent.friendship.spiritual',       232, true, false),
  (2, 'friendship::single_parents',  'intent.friendship.single_parents',  233, true, false),
  (2, 'friendship::seniors',         'intent.friendship.seniors',         234, true, false)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- INSERT Activity Partner sub-intents (moved from Friendship)
-- ============================================================

INSERT INTO public.intents (parent_id, key, translation_key, sort_order, is_social, is_business) VALUES
  (3, 'activity_partner::gym',              'intent.activity.gym',              328, true, false),
  (3, 'activity_partner::movies',           'intent.activity.movies',           329, true, false),
  (3, 'activity_partner::dining_out',       'intent.activity.dining_out',       330, true, false),
  (3, 'activity_partner::coffee',           'intent.activity.coffee',           331, true, false),
  (3, 'activity_partner::walking',          'intent.activity.walking',          332, true, false),
  (3, 'activity_partner::language_exchange','intent.activity.language_exchange', 333, true, false),
  (3, 'activity_partner::music',            'intent.activity.music',            334, true, false),
  (3, 'activity_partner::book_club',        'intent.activity.book_club',        335, true, false),
  (3, 'activity_partner::board_games',      'intent.activity.board_games',      336, true, false),
  (3, 'activity_partner::pets',             'intent.activity.pets',             337, true, false),
  (3, 'activity_partner::shopping',         'intent.activity.shopping',         338, true, false),
  (3, 'activity_partner::volunteering',     'intent.activity.volunteering',     339, true, false),
  (3, 'activity_partner::concerts',         'intent.activity.concerts',         340, true, false),
  (3, 'activity_partner::art',              'intent.activity.art',              341, true, false),
  (3, 'activity_partner::karaoke',          'intent.activity.karaoke',          342, true, false),
  (3, 'activity_partner::outdoors',         'intent.activity.outdoors',         343, true, false)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- TRANSLATIONS (en)
-- ============================================================

INSERT INTO public.translations (key, locale, value) VALUES
  -- Friendship
  ('intent.friendship.casual', 'en', 'Casual Friendship'),
  ('intent.friendship.deep_connection', 'en', 'Deep Connection'),
  ('intent.friendship.new_in_town', 'en', 'New in Town'),
  ('intent.friendship.student_life', 'en', 'Student Life'),
  ('intent.friendship.expats', 'en', 'Expat Community'),
  ('intent.friendship.neighbors', 'en', 'Neighbors'),
  ('intent.friendship.lgbtqia', 'en', 'LGBTQIA+ Friends'),
  ('intent.friendship.spiritual', 'en', 'Spiritual Connection'),
  ('intent.friendship.single_parents', 'en', 'Single Parents'),
  ('intent.friendship.seniors', 'en', 'Seniors'),
  -- Activity Partner
  ('intent.activity.gym', 'en', 'Gym'),
  ('intent.activity.movies', 'en', 'Movies'),
  ('intent.activity.dining_out', 'en', 'Dining Out'),
  ('intent.activity.coffee', 'en', 'Coffee'),
  ('intent.activity.walking', 'en', 'Walking'),
  ('intent.activity.language_exchange', 'en', 'Language Exchange'),
  ('intent.activity.music', 'en', 'Music'),
  ('intent.activity.book_club', 'en', 'Book Club'),
  ('intent.activity.board_games', 'en', 'Board Games'),
  ('intent.activity.pets', 'en', 'Pets'),
  ('intent.activity.shopping', 'en', 'Shopping'),
  ('intent.activity.volunteering', 'en', 'Volunteering'),
  ('intent.activity.concerts', 'en', 'Concerts'),
  ('intent.activity.art', 'en', 'Art'),
  ('intent.activity.karaoke', 'en', 'Karaoke'),
  ('intent.activity.outdoors', 'en', 'Outdoors')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- ============================================================
-- TRANSLATIONS (es)
-- ============================================================

INSERT INTO public.translations (key, locale, value) VALUES
  -- Friendship
  ('intent.friendship.casual', 'es', 'Amistad Casual'),
  ('intent.friendship.deep_connection', 'es', 'Conexión Profunda'),
  ('intent.friendship.new_in_town', 'es', 'Nuevo en la Ciudad'),
  ('intent.friendship.student_life', 'es', 'Vida Estudiantil'),
  ('intent.friendship.expats', 'es', 'Comunidad de Expatriados'),
  ('intent.friendship.neighbors', 'es', 'Vecinos'),
  ('intent.friendship.lgbtqia', 'es', 'Amigos LGBTQIA+'),
  ('intent.friendship.spiritual', 'es', 'Conexión Espiritual'),
  ('intent.friendship.single_parents', 'es', 'Padres Solteros'),
  ('intent.friendship.seniors', 'es', 'Adultos Mayores'),
  -- Activity Partner
  ('intent.activity.gym', 'es', 'Gimnasio'),
  ('intent.activity.movies', 'es', 'Cine'),
  ('intent.activity.dining_out', 'es', 'Salir a Cenar'),
  ('intent.activity.coffee', 'es', 'Café'),
  ('intent.activity.walking', 'es', 'Caminar'),
  ('intent.activity.language_exchange', 'es', 'Intercambio de Idiomas'),
  ('intent.activity.music', 'es', 'Música'),
  ('intent.activity.book_club', 'es', 'Club de Lectura'),
  ('intent.activity.board_games', 'es', 'Juegos de Mesa'),
  ('intent.activity.pets', 'es', 'Mascotas'),
  ('intent.activity.shopping', 'es', 'Compras'),
  ('intent.activity.volunteering', 'es', 'Voluntariado'),
  ('intent.activity.concerts', 'es', 'Conciertos'),
  ('intent.activity.art', 'es', 'Arte'),
  ('intent.activity.karaoke', 'es', 'Karaoke'),
  ('intent.activity.outdoors', 'es', 'Actividades al Aire Libre')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- ============================================================
-- TRANSLATIONS (he)
-- ============================================================

INSERT INTO public.translations (key, locale, value) VALUES
  -- Friendship
  ('intent.friendship.casual', 'he', 'חברות מזדמנת'),
  ('intent.friendship.deep_connection', 'he', 'קשר עמוק'),
  ('intent.friendship.new_in_town', 'he', 'חדש בעיר'),
  ('intent.friendship.student_life', 'he', 'חיי סטודנט'),
  ('intent.friendship.expats', 'he', 'קהילת גולים'),
  ('intent.friendship.neighbors', 'he', 'שכנים'),
  ('intent.friendship.lgbtqia', 'he', 'חברים להט"ב+'),
  ('intent.friendship.spiritual', 'he', 'חיבור רוחני'),
  ('intent.friendship.single_parents', 'he', 'הורים יחידניים'),
  ('intent.friendship.seniors', 'he', 'מבוגרים'),
  -- Activity Partner
  ('intent.activity.gym', 'he', 'חדר כושר'),
  ('intent.activity.movies', 'he', 'סרטים'),
  ('intent.activity.dining_out', 'he', 'ארוחות בחוץ'),
  ('intent.activity.coffee', 'he', 'קפה'),
  ('intent.activity.walking', 'he', 'הליכה'),
  ('intent.activity.language_exchange', 'he', 'החלפת שפות'),
  ('intent.activity.music', 'he', 'מוזיקה'),
  ('intent.activity.book_club', 'he', 'מועדון ספרים'),
  ('intent.activity.board_games', 'he', 'משחקי לוח'),
  ('intent.activity.pets', 'he', 'חיות מחמד'),
  ('intent.activity.shopping', 'he', 'קניות'),
  ('intent.activity.volunteering', 'he', 'התנדבות'),
  ('intent.activity.concerts', 'he', 'הופעות'),
  ('intent.activity.art', 'he', 'אמנות'),
  ('intent.activity.karaoke', 'he', 'קריוקי'),
  ('intent.activity.outdoors', 'he', 'פעילויות בחוץ')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
