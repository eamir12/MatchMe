-- Migration: Seed missing intent & interest translations for Match Inspector localization
-- Purpose: Ensure every intent, sub-intent, interest and sub-interest displayed in Match Inspector
--          appears in the user's UI language (en/es/he) via Supabase translations table.
--          Covers 25 missing intent keys and 40 missing interest keys detected by audit.
--          All user-facing text besides user names must be localized.
BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Base intents
  ('en', 'intent.romantic', $$Romantic$$),
  ('es', 'intent.romantic', $$Romántico$$),
  ('he', 'intent.romantic', $$רומנטי$$),

  ('en', 'intent.friendship', $$Friendship$$),
  ('es', 'intent.friendship', $$Amistad$$),
  ('he', 'intent.friendship', $$חברות$$),

  ('en', 'intent.activity_partner', $$Activity Partner$$),
  ('es', 'intent.activity_partner', $$Compañero de Actividad$$),
  ('he', 'intent.activity_partner', $$שותף לפעילות$$),

  ('en', 'intent.business_networking', $$Business Networking$$),
  ('es', 'intent.business_networking', $$Networking Profesional$$),
  ('he', 'intent.business_networking', $$נטוורקינג עסקי$$),

  -- Romantic sub-intents
  ('en', 'intent.romantic.long_term', $$Long Term$$),
  ('es', 'intent.romantic.long_term', $$Largo Plazo$$),
  ('he', 'intent.romantic.long_term', $$ארוך טווח$$),

  ('en', 'intent.romantic.short_term', $$Short Term$$),
  ('es', 'intent.romantic.short_term', $$Corto Plazo$$),
  ('he', 'intent.romantic.short_term', $$קצר טווח$$),

  ('en', 'intent.romantic.casual', $$Casual$$),
  ('es', 'intent.romantic.casual', $$Casual$$),
  ('he', 'intent.romantic.casual', $$קליל$$),

  ('en', 'intent.romantic.fwb', $$Friends with Benefits$$),
  ('es', 'intent.romantic.fwb', $$Amigos con Beneficios$$),
  ('he', 'intent.romantic.fwb', $$ידידות עם הטבות$$),

  ('en', 'intent.romantic.open', $$Open Relationship$$),
  ('es', 'intent.romantic.open', $$Relación Abierta$$),
  ('he', 'intent.romantic.open', $$יחסים פתוחים$$),

  ('en', 'intent.romantic.polyamory', $$Polyamory$$),
  ('es', 'intent.romantic.polyamory', $$Poliamor$$),
  ('he', 'intent.romantic.polyamory', $$פוליאמוריה$$),

  -- Friendship sub-intents
  ('en', 'intent.friendship.hangouts', $$Hangouts$$),
  ('es', 'intent.friendship.hangouts', $$Quedadas$$),
  ('he', 'intent.friendship.hangouts', $$בילויים$$),

  ('en', 'intent.friendship.chat', $$Chat$$),
  ('es', 'intent.friendship.chat', $$Charla$$),
  ('he', 'intent.friendship.chat', $$שיחה$$),

  ('en', 'intent.friendship.travel_buddy', $$Travel Buddy$$),
  ('es', 'intent.friendship.travel_buddy', $$Compañero de Viaje$$),
  ('he', 'intent.friendship.travel_buddy', $$שותף לטיול$$),

  ('en', 'intent.friendship.group_activities', $$Group Activities$$),
  ('es', 'intent.friendship.group_activities', $$Actividades Grupales$$),
  ('he', 'intent.friendship.group_activities', $$פעילויות קבוצתיות$$),

  ('en', 'intent.friendship.study_buddy', $$Study Buddy$$),
  ('es', 'intent.friendship.study_buddy', $$Compañero de Estudio$$),
  ('he', 'intent.friendship.study_buddy', $$שותף ללימודים$$),

  -- Activity partner sub-intents
  ('en', 'intent.activity.workout', $$Workout$$),
  ('es', 'intent.activity.workout', $$Entrenamiento$$),
  ('he', 'intent.activity.workout', $$אימון$$),

  ('en', 'intent.activity.hiking', $$Hiking$$),
  ('es', 'intent.activity.hiking', $$Senderismo$$),
  ('he', 'intent.activity.hiking', $$טיול רגלי$$),

  ('en', 'intent.activity.sports', $$Sports$$),
  ('es', 'intent.activity.sports', $$Deportes$$),
  ('he', 'intent.activity.sports', $$ספורט$$),

  ('en', 'intent.activity.travel_partner', $$Travel Partner$$),
  ('es', 'intent.activity.travel_partner', $$Compañero de Viaje$$),
  ('he', 'intent.activity.travel_partner', $$שותף לנסיעה$$),

  ('en', 'intent.activity.gaming', $$Gaming$$),
  ('es', 'intent.activity.gaming', $$Juegos$$),
  ('he', 'intent.activity.gaming', $$גיימינג$$),

  -- Business networking sub-intents
  ('en', 'intent.business.mentorship', $$Mentorship$$),
  ('es', 'intent.business.mentorship', $$Mentoría$$),
  ('he', 'intent.business.mentorship', $$חניכה$$),

  ('en', 'intent.business.hiring', $$Hiring$$),
  ('es', 'intent.business.hiring', $$Contratación$$),
  ('he', 'intent.business.hiring', $$גיוס עובדים$$),

  ('en', 'intent.business.cofounder', $$Co-founder$$),
  ('es', 'intent.business.cofounder', $$Cofundador$$),
  ('he', 'intent.business.cofounder', $$שותף להקמה$$),

  ('en', 'intent.business.events', $$Business Events$$),
  ('es', 'intent.business.events', $$Eventos de Negocios$$),
  ('he', 'intent.business.events', $$אירועים עסקיים$$),

  ('en', 'intent.business.skill_exchange', $$Skill Exchange$$),
  ('es', 'intent.business.skill_exchange', $$Intercambio de Habilidades$$),
  ('he', 'intent.business.skill_exchange', $$החלפת מיומנויות$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Top-level interests
  ('en', 'interest.singing', $$Singing$$),
  ('es', 'interest.singing', $$Cantar$$),
  ('he', 'interest.singing', $$שירה$$),

  ('en', 'interest.traveling', $$Traveling$$),
  ('es', 'interest.traveling', $$Viajar$$),
  ('he', 'interest.traveling', $$טיולים$$),

  ('en', 'interest.eating_out', $$Eating Out$$),
  ('es', 'interest.eating_out', $$Comer Fuera$$),
  ('he', 'interest.eating_out', $$אכילה בחוץ$$),

  ('en', 'interest.dancing.salsa', $$Salsa$$),
  ('es', 'interest.dancing.salsa', $$Salsa$$),
  ('he', 'interest.dancing.salsa', $$סלסה$$),

  ('en', 'interest.dancing.tango', $$Tango$$),
  ('es', 'interest.dancing.tango', $$Tango$$),
  ('he', 'interest.dancing.tango', $$טנגו$$),

  ('en', 'interest.dancing.line', $$Line Dancing$$),
  ('es', 'interest.dancing.line', $$Baile en Línea$$),
  ('he', 'interest.dancing.line', $$ריקוד שורות$$),

  ('en', 'interest.startups', $$Startups$$),
  ('es', 'interest.startups', $$Startups$$),
  ('he', 'interest.startups', $$סטארטאפים$$),

  ('en', 'interest.vc', $$Venture Capital$$),
  ('es', 'interest.vc', $$Capital de Riesgo$$),
  ('he', 'interest.vc', $$הון סיכון$$),

  ('en', 'interest.finance', $$Finance$$),
  ('es', 'interest.finance', $$Finanzas$$),
  ('he', 'interest.finance', $$פיננסים$$),

  ('en', 'interest.marketing', $$Marketing$$),
  ('es', 'interest.marketing', $$Marketing$$),
  ('he', 'interest.marketing', $$שיווק$$),

  -- Interest categories
  ('en', 'interest_category.dates', $$Dates$$),
  ('es', 'interest_category.dates', $$Citas$$),
  ('he', 'interest_category.dates', $$דייטים$$),

  ('en', 'interest_category.music_and_art', $$Music & Art$$),
  ('es', 'interest_category.music_and_art', $$Música y Arte$$),
  ('he', 'interest_category.music_and_art', $$מוזיקה ואמנות$$),

  ('en', 'interest_category.food_and_drink', $$Food & Drink$$),
  ('es', 'interest_category.food_and_drink', $$Comida y Bebida$$),
  ('he', 'interest_category.food_and_drink', $$אוכל ושתייה$$),

  ('en', 'interest_category.hangouts', $$Hangouts$$),
  ('es', 'interest_category.hangouts', $$Quedadas$$),
  ('he', 'interest_category.hangouts', $$בילויים$$),

  ('en', 'interest_category.group_activities', $$Group Activities$$),
  ('es', 'interest_category.group_activities', $$Actividades Grupales$$),
  ('he', 'interest_category.group_activities', $$פעילויות קבוצתיות$$),

  ('en', 'interest_category.study_and_learning', $$Study & Learning$$),
  ('es', 'interest_category.study_and_learning', $$Estudio y Aprendizaje$$),
  ('he', 'interest_category.study_and_learning', $$לימודים$$),

  ('en', 'interest_category.fitness', $$Fitness$$),
  ('es', 'interest_category.fitness', $$Fitness$$),
  ('he', 'interest_category.fitness', $$כושר$$),

  ('en', 'interest_category.outdoors', $$Outdoors$$),
  ('es', 'interest_category.outdoors', $$Aire Libre$$),
  ('he', 'interest_category.outdoors', $$פעילויות חוץ$$),

  ('en', 'interest_category.gaming', $$Gaming$$),
  ('es', 'interest_category.gaming', $$Juegos$$),
  ('he', 'interest_category.gaming', $$גיימינג$$),

  ('en', 'interest_category.mentorship', $$Mentorship$$),
  ('es', 'interest_category.mentorship', $$Mentoría$$),
  ('he', 'interest_category.mentorship', $$חניכה$$),

  ('en', 'interest_category.business_events', $$Business Events$$),
  ('es', 'interest_category.business_events', $$Eventos de Negocios$$),
  ('he', 'interest_category.business_events', $$אירועים עסקיים$$),

  ('en', 'interest_category.skill_sharing', $$Skill Sharing$$),
  ('es', 'interest_category.skill_sharing', $$Intercambio de Habilidades$$),
  ('he', 'interest_category.skill_sharing', $$שיתוף מיומנויות$$),

  -- Specific sub-interests
  ('en', 'interest.dinner', $$Dinner$$),
  ('es', 'interest.dinner', $$Cena$$),
  ('he', 'interest.dinner', $$ארוחת ערב$$),

  ('en', 'interest.movies', $$Movies$$),
  ('es', 'interest.movies', $$Películas$$),
  ('he', 'interest.movies', $$סרטים$$),

  ('en', 'interest.walks', $$Walks$$),
  ('es', 'interest.walks', $$Paseos$$),
  ('he', 'interest.walks', $$טיולים רגליים$$),

  ('en', 'interest.live_music', $$Live Music$$),
  ('es', 'interest.live_music', $$Música en Vivo$$),
  ('he', 'interest.live_music', $$מוזיקה חיה$$),

  ('en', 'interest.art_galleries', $$Art Galleries$$),
  ('es', 'interest.art_galleries', $$Galerías de Arte$$),
  ('he', 'interest.art_galleries', $$גלריות אמנות$$),

  ('en', 'interest.coffee', $$Coffee$$),
  ('es', 'interest.coffee', $$Café$$),
  ('he', 'interest.coffee', $$קפה$$),

  ('en', 'interest.cocktails', $$Cocktails$$),
  ('es', 'interest.cocktails', $$Cócteles$$),
  ('he', 'interest.cocktails', $$קוקטיילים$$),

  ('en', 'interest.board_games', $$Board Games$$),
  ('es', 'interest.board_games', $$Juegos de Mesa$$),
  ('he', 'interest.board_games', $$משחקי לוח$$),

  ('en', 'interest.coffee_meetups', $$Coffee Meetups$$),
  ('es', 'interest.coffee_meetups', $$Quedadas para Café$$),
  ('he', 'interest.coffee_meetups', $$מפגשי קפה$$),

  ('en', 'interest.language_exchange', $$Language Exchange$$),
  ('es', 'interest.language_exchange', $$Intercambio de Idiomas$$),
  ('he', 'interest.language_exchange', $$חילופי שפות$$),

  ('en', 'interest.study_groups', $$Study Groups$$),
  ('es', 'interest.study_groups', $$Grupos de Estudio$$),
  ('he', 'interest.study_groups', $$קבוצות לימוד$$),

  ('en', 'interest.gym_buddies', $$Gym Buddies$$),
  ('es', 'interest.gym_buddies', $$Compañeros de Gimnasio$$),
  ('he', 'interest.gym_buddies', $$שותפים לחדר כושר$$),

  ('en', 'interest.hiking_trails', $$Hiking Trails$$),
  ('es', 'interest.hiking_trails', $$Senderos$$),
  ('he', 'interest.hiking_trails', $$שבילי טיול$$),

  ('en', 'interest.pickup_sports', $$Pickup Sports$$),
  ('es', 'interest.pickup_sports', $$Deportes Informales$$),
  ('he', 'interest.pickup_sports', $$ספורט מזדמן$$),

  ('en', 'interest.co_op_gaming', $$Co-op Gaming$$),
  ('es', 'interest.co_op_gaming', $$Juegos Cooperativos$$),
  ('he', 'interest.co_op_gaming', $$משחק שיתופי$$),

  ('en', 'interest.startup_founders', $$Startup Founders$$),
  ('es', 'interest.startup_founders', $$Fundadores de Startups$$),
  ('he', 'interest.startup_founders', $$מייסדי סטארטאפ$$),

  ('en', 'interest.job_openings', $$Job Openings$$),
  ('es', 'interest.job_openings', $$Ofertas de Empleo$$),
  ('he', 'interest.job_openings', $$משרות פנויות$$),

  ('en', 'interest.skill_swap', $$Skill Swap$$),
  ('es', 'interest.skill_swap', $$Intercambio de Habilidades$$),
  ('he', 'interest.skill_swap', $$החלפת כישורים$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Ensure domain type labels are available (used by _localizeDomainType)
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'domain.personal', $$Personal$$),
  ('es', 'domain.personal', $$Personal$$),
  ('he', 'domain.personal', $$אישי$$),
  ('en', 'domain.business', $$Business$$),
  ('es', 'domain.business', $$Negocio$$),
  ('he', 'domain.business', $$עסקי$$),
  ('en', 'domain.merged', $$Combined$$),
  ('es', 'domain.merged', $$Combinado$$),
  ('he', 'domain.merged', $$משולב$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
