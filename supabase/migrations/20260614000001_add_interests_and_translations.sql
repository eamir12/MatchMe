-- Seed additional interests, categories, sub-interests and their translations
-- Adds drill-down interests under existing and new categories

BEGIN;

-- ============================================================
-- NEW TOP-LEVEL SPECIFIC INTERESTS
-- ============================================================

INSERT INTO public.interests (parent_id, key, translation_key, sort_order, is_social, is_business)
VALUES
  (NULL, 'photography',      'interest.photography',      50, true,  false),
  (NULL, 'cooking',          'interest.cooking',          60, true,  false),
  (NULL, 'hiking',           'interest.hiking',           70, true,  false),
  (NULL, 'reading',          'interest.reading',          80, true,  false),
  (NULL, 'volunteering',     'interest.volunteering',     90, true,  false),
  (NULL, 'painting',         'interest.painting',         100, true,  false),
  (NULL, 'yoga',             'interest.yoga',             110, true,  false),
  (NULL, 'entrepreneurship', 'interest.entrepreneurship', 50, false, true),
  (NULL, 'technology',       'interest.technology',       60, false, true),
  (NULL, 'consulting',       'interest.consulting',       70, false, true),
  (NULL, 'ecommerce',        'interest.ecommerce',        80, false, true)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- NEW TOP-LEVEL CATEGORIES
-- ============================================================

INSERT INTO public.interests (parent_id, key, translation_key, sort_order, is_social, is_business)
VALUES
  (NULL, 'arts_and_crafts',     'interest_category.arts_and_crafts',     10, true,  false),
  (NULL, 'wellness',            'interest_category.wellness',            20, true,  false),
  (NULL, 'pets_and_animals',    'interest_category.pets_and_animals',    30, true,  false),
  (NULL, 'travel',              'interest_category.travel',              10, true,  false),
  (NULL, 'sports',              'interest_category.sports',              20, true,  false),
  (NULL, 'music',               'interest_category.music',               30, true,  false),
  (NULL, 'entrepreneurship_cat','interest_category.entrepreneurship',    10, false, true),
  (NULL, 'technology_cat',      'interest_category.technology',          20, false, true),
  (NULL, 'consulting_cat',      'interest_category.consulting',          30, false, true)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- SUB-INTERESTS UNDER EXISTING SPECIFIC INTERESTS
-- ============================================================

INSERT INTO public.interests (parent_id, key, translation_key, sort_order, is_social, is_business)
VALUES
  -- Singing (parent_id = 2) - no existing sub-interests
  ((SELECT id FROM public.interests WHERE key = 'singing'), 'karaoke',   'interest.karaoke',   10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'singing'), 'choir',     'interest.choir',     20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'singing'), 'open_mic',  'interest.open_mic',  30, true, false),

  -- Traveling (parent_id = 3) - no existing sub-interests
  ((SELECT id FROM public.interests WHERE key = 'traveling'), 'backpacking',      'interest.backpacking',      10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'traveling'), 'road_trips',       'interest.road_trips',       20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'traveling'), 'adventure_travel', 'interest.adventure_travel', 30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'traveling'), 'cultural_tourism', 'interest.cultural_tourism', 40, true, false),

  -- Eating Out (parent_id = 4) - no existing sub-interests
  ((SELECT id FROM public.interests WHERE key = 'eating_out'), 'fine_dining',   'interest.fine_dining',   10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'eating_out'), 'brunch',        'interest.brunch',        20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'eating_out'), 'food_trucks',   'interest.food_trucks',   30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'eating_out'), 'ethnic_cuisine','interest.ethnic_cuisine',40, true, false),

  -- Dancing (parent_id = 1) - existing: salsa(10), tango(20), line_dancing(30). Continuing at 40+
  ((SELECT id FROM public.interests WHERE key = 'dancing'), 'ballroom',     'interest.dancing.ballroom',     40, true, false),
  ((SELECT id FROM public.interests WHERE key = 'dancing'), 'hip_hop',      'interest.dancing.hip_hop',      50, true, false),
  ((SELECT id FROM public.interests WHERE key = 'dancing'), 'contemporary', 'interest.dancing.contemporary', 60, true, false),
  ((SELECT id FROM public.interests WHERE key = 'dancing'), 'swing',        'interest.dancing.swing',        70, true, false),
  ((SELECT id FROM public.interests WHERE key = 'dancing'), 'bachata',      'interest.dancing.bachata',      80, true, false),

  -- Startups (parent_id = 8) - no existing sub-interests
  ((SELECT id FROM public.interests WHERE key = 'startups'), 'saas',       'interest.saas',       10, false, true),
  ((SELECT id FROM public.interests WHERE key = 'startups'), 'fintech',    'interest.fintech',    20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'startups'), 'biotech',    'interest.biotech',    30, false, true),
  ((SELECT id FROM public.interests WHERE key = 'startups'), 'cleantech',  'interest.cleantech',  40, false, true),

  -- Venture Capital (parent_id = 9) - no existing sub-interests
  ((SELECT id FROM public.interests WHERE key = 'venture_capital'), 'seed_stage',     'interest.seed_stage',     10, false, true),
  ((SELECT id FROM public.interests WHERE key = 'venture_capital'), 'growth_equity',  'interest.growth_equity',  20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'venture_capital'), 'angel_investing','interest.angel_investing',30, false, true),

  -- Finance (parent_id = 10) - no existing sub-interests
  ((SELECT id FROM public.interests WHERE key = 'finance'), 'personal_finance', 'interest.personal_finance', 10, false, true),
  ((SELECT id FROM public.interests WHERE key = 'finance'), 'investing',        'interest.investing',        20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'finance'), 'stock_trading',    'interest.stock_trading',    30, false, true),

  -- Marketing (parent_id = 11) - no existing sub-interests
  ((SELECT id FROM public.interests WHERE key = 'marketing'), 'digital_marketing','interest.digital_marketing',10, false, true),
  ((SELECT id FROM public.interests WHERE key = 'marketing'), 'content_creation', 'interest.content_creation', 20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'marketing'), 'brand_strategy',   'interest.brand_strategy',   30, false, true),
  ((SELECT id FROM public.interests WHERE key = 'marketing'), 'growth_hacking',   'interest.growth_hacking',   40, false, true)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- MORE SUB-INTERESTS UNDER EXISTING CATEGORIES
-- ============================================================

INSERT INTO public.interests (parent_id, key, translation_key, sort_order, is_social, is_business)
VALUES
  -- Dates (parent_id = 12) - existing: dinner(10), movies(20), walks(30). Continuing at 40+
  ((SELECT id FROM public.interests WHERE key = 'dates'), 'picnic',           'interest.picnic',           40, true, false),
  ((SELECT id FROM public.interests WHERE key = 'dates'), 'stargazing',       'interest.stargazing',       50, true, false),
  ((SELECT id FROM public.interests WHERE key = 'dates'), 'amusement_park',   'interest.amusement_park',   60, true, false),

  -- Music and Art (parent_id = 13) - existing: live_music(10), art_galleries(20). Continuing at 30+
  ((SELECT id FROM public.interests WHERE key = 'music_and_art'), 'concerts',     'interest.concerts',     30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'music_and_art'), 'theater',      'interest.theater',      40, true, false),
  ((SELECT id FROM public.interests WHERE key = 'music_and_art'), 'museums',      'interest.museums',      50, true, false),
  ((SELECT id FROM public.interests WHERE key = 'music_and_art'), 'festivals',    'interest.festivals',    60, true, false),

  -- Food and Drink (parent_id = 14) - existing: coffee(10), cocktails(20). Continuing at 30+
  ((SELECT id FROM public.interests WHERE key = 'food_and_drink'), 'brunch',        'interest.brunch',        30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'food_and_drink'), 'wine_tasting',  'interest.wine_tasting',   40, true, false),
  ((SELECT id FROM public.interests WHERE key = 'food_and_drink'), 'craft_beer',    'interest.craft_beer',    50, true, false),
  ((SELECT id FROM public.interests WHERE key = 'food_and_drink'), 'tea',           'interest.tea',           60, true, false),

  -- Hangouts (parent_id = 15) - existing: board_games(10), coffee_meetups(20). Continuing at 30+
  ((SELECT id FROM public.interests WHERE key = 'hangouts'), 'trivia_nights',  'interest.trivia_nights', 30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'hangouts'), 'karaoke',        'interest.karaoke',       40, true, false),
  ((SELECT id FROM public.interests WHERE key = 'hangouts'), 'rooftop_bars',   'interest.rooftop_bars',  50, true, false),

  -- Group Activities (parent_id = 16) - existing: language_exchange(10). Continuing at 20+
  ((SELECT id FROM public.interests WHERE key = 'group_activities'), 'book_clubs',      'interest.book_clubs',      20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'group_activities'), 'cooking_classes', 'interest.cooking_classes', 30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'group_activities'), 'dance_classes',   'interest.dance_classes',   40, true, false),

  -- Study and Learning (parent_id = 17) - existing: study_groups(10). Continuing at 20+
  ((SELECT id FROM public.interests WHERE key = 'study_and_learning'), 'workshops',     'interest.workshops',      20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'study_and_learning'), 'online_courses','interest.online_courses', 30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'study_and_learning'), 'lectures',      'interest.lectures',       40, true, false),

  -- Fitness (parent_id = 18) - existing: gym_buddies(10), pickup_sports(20). Continuing at 30+
  ((SELECT id FROM public.interests WHERE key = 'fitness'), 'running_clubs',  'interest.running_clubs',  30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'fitness'), 'yoga',           'interest.yoga',           40, true, false),
  ((SELECT id FROM public.interests WHERE key = 'fitness'), 'cycling',        'interest.cycling',        50, true, false),
  ((SELECT id FROM public.interests WHERE key = 'fitness'), 'swimming',       'interest.swimming',       60, true, false),
  ((SELECT id FROM public.interests WHERE key = 'fitness'), 'crossfit',       'interest.crossfit',       70, true, false),
  ((SELECT id FROM public.interests WHERE key = 'fitness'), 'pilates',        'interest.pilates',        80, true, false),

  -- Outdoors (parent_id = 19) - existing: hiking_trails(10). Continuing at 20+
  ((SELECT id FROM public.interests WHERE key = 'outdoors'), 'camping',         'interest.camping',         20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'outdoors'), 'fishing',         'interest.fishing',         30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'outdoors'), 'kayaking',        'interest.kayaking',        40, true, false),
  ((SELECT id FROM public.interests WHERE key = 'outdoors'), 'climbing',        'interest.climbing',        50, true, false),
  ((SELECT id FROM public.interests WHERE key = 'outdoors'), 'mountain_biking','interest.mountain_biking', 60, true, false),

  -- Gaming (parent_id = 20) - existing: co_op_gaming(10). Continuing at 20+
  ((SELECT id FROM public.interests WHERE key = 'gaming'), 'video_games',  'interest.video_games',  20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'gaming'), 'esports',      'interest.esports',      30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'gaming'), 'tabletop_rpg', 'interest.tabletop_rpg', 40, true, false),
  ((SELECT id FROM public.interests WHERE key = 'gaming'), 'card_games',   'interest.card_games',   50, true, false),

  -- Mentorship (parent_id = 21) - existing: startup_founders(10). Continuing at 20+
  ((SELECT id FROM public.interests WHERE key = 'mentorship'), 'career_guidance',       'interest.career_guidance',       20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'mentorship'), 'leadership_coaching',   'interest.leadership_coaching',   30, false, true),
  ((SELECT id FROM public.interests WHERE key = 'mentorship'), 'technical_mentorship',  'interest.technical_mentorship',  40, false, true),

  -- Business Events (parent_id = 22) - existing: job_openings(10). Continuing at 20+
  ((SELECT id FROM public.interests WHERE key = 'business_events'), 'conferences',          'interest.conferences',          20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'business_events'), 'networking_mixers',    'interest.networking_mixers',    30, false, true),
  ((SELECT id FROM public.interests WHERE key = 'business_events'), 'trade_shows',          'interest.trade_shows',          40, false, true),
  ((SELECT id FROM public.interests WHERE key = 'business_events'), 'hackathons',           'interest.hackathons',           50, false, true),

  -- Skill Sharing (parent_id = 23) - existing: skill_swap(10). Continuing at 20+
  ((SELECT id FROM public.interests WHERE key = 'skill_sharing'), 'coding_workshops',   'interest.coding_workshops',   20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'skill_sharing'), 'design_critiques',   'interest.design_critiques',   30, false, true),
  ((SELECT id FROM public.interests WHERE key = 'skill_sharing'), 'language_partners',  'interest.language_partners',  40, false, true),
  ((SELECT id FROM public.interests WHERE key = 'skill_sharing'), 'public_speaking',    'interest.public_speaking',    50, false, true)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- SUB-INTERESTS UNDER NEW SPECIFIC INTERESTS
-- ============================================================

INSERT INTO public.interests (parent_id, key, translation_key, sort_order, is_social, is_business)
VALUES
  -- Photography (new top-level)
  ((SELECT id FROM public.interests WHERE key = 'photography'), 'portrait',          'interest.photography.portrait',          10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'photography'), 'landscape',         'interest.photography.landscape',         20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'photography'), 'street_photography','interest.photography.street',            30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'photography'), 'wildlife',          'interest.photography.wildlife',          40, true, false),

  -- Cooking (new top-level)
  ((SELECT id FROM public.interests WHERE key = 'cooking'), 'baking',              'interest.cooking.baking',              10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'cooking'), 'grilling',            'interest.cooking.grilling',            20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'cooking'), 'international','interest.cooking.international_cuisine', 30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'cooking'), 'vegan_cooking',       'interest.cooking.vegan',               40, true, false),

  -- Hiking (new top-level)
  ((SELECT id FROM public.interests WHERE key = 'hiking'), 'day_hikes',        'interest.hiking.day_hikes',        10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'hiking'), 'overnight_treks',  'interest.hiking.overnight_treks',  20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'hiking'), 'nature_trails',    'interest.hiking.nature_trails',    30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'hiking'), 'mountain_hiking',  'interest.hiking.mountain',         40, true, false),

  -- Reading (new top-level)
  ((SELECT id FROM public.interests WHERE key = 'reading'), 'fiction',     'interest.reading.fiction',     10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'reading'), 'non_fiction', 'interest.reading.non_fiction', 20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'reading'), 'poetry',      'interest.reading.poetry',      30, true, false),

  -- Volunteering (new top-level)
  ((SELECT id FROM public.interests WHERE key = 'volunteering'), 'community_service',  'interest.volunteering.community',   10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'volunteering'), 'animal_rescue',      'interest.volunteering.animals',    20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'volunteering'), 'environmental',      'interest.volunteering.environment',30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'volunteering'), 'education',          'interest.volunteering.education',  40, true, false),

  -- Painting (new top-level)
  ((SELECT id FROM public.interests WHERE key = 'painting'), 'oil_painting',    'interest.painting.oil',      10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'painting'), 'watercolor',     'interest.painting.watercolor',20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'painting'), 'acrylic',        'interest.painting.acrylic',   30, true, false),

  -- Yoga (new top-level)
  ((SELECT id FROM public.interests WHERE key = 'yoga'), 'hatha',           'interest.yoga.hatha',           10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'yoga'), 'vinyasa',         'interest.yoga.vinyasa',         20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'yoga'), 'ashtanga',        'interest.yoga.ashtanga',        30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'yoga'), 'meditation',      'interest.yoga.meditation',      40, true, false),

  -- Entrepreneurship (new top-level business)
  ((SELECT id FROM public.interests WHERE key = 'entrepreneurship'), 'bootstrapping',     'interest.entrepreneurship.bootstrapping',     10, false, true),
  ((SELECT id FROM public.interests WHERE key = 'entrepreneurship'), 'social_enterprise', 'interest.entrepreneurship.social_enterprise', 20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'entrepreneurship'), 'side_hustles',      'interest.entrepreneurship.side_hustles',      30, false, true),
  ((SELECT id FROM public.interests WHERE key = 'entrepreneurship'), 'incubators',        'interest.entrepreneurship.incubators',        40, false, true),

  -- Technology (new top-level business)
  ((SELECT id FROM public.interests WHERE key = 'technology'), 'ai_ml',            'interest.technology.ai_ml',            10, false, true),
  ((SELECT id FROM public.interests WHERE key = 'technology'), 'cybersecurity',    'interest.technology.cybersecurity',    20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'technology'), 'web_development',  'interest.technology.web_development',  30, false, true),
  ((SELECT id FROM public.interests WHERE key = 'technology'), 'mobile_dev',       'interest.technology.mobile_dev',       40, false, true),
  ((SELECT id FROM public.interests WHERE key = 'technology'), 'cloud_computing',  'interest.technology.cloud_computing',  50, false, true),

  -- Consulting (new top-level business)
  ((SELECT id FROM public.interests WHERE key = 'consulting'), 'strategy',        'interest.consulting.strategy',        10, false, true),
  ((SELECT id FROM public.interests WHERE key = 'consulting'), 'operations',      'interest.consulting.operations',      20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'consulting'), 'hr_consulting',   'interest.consulting.hr',              30, false, true),
  ((SELECT id FROM public.interests WHERE key = 'consulting'), 'it_consulting',   'interest.consulting.it',              40, false, true),

  -- Ecommerce (new top-level business)
  ((SELECT id FROM public.interests WHERE key = 'ecommerce'), 'dropshipping',     'interest.ecommerce.dropshipping',     10, false, true),
  ((SELECT id FROM public.interests WHERE key = 'ecommerce'), 'amazon_fba',       'interest.ecommerce.amazon_fba',       20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'ecommerce'), 'shopify_stores',   'interest.ecommerce.shopify',          30, false, true),
  ((SELECT id FROM public.interests WHERE key = 'ecommerce'), 'digital_products', 'interest.ecommerce.digital_products', 40, false, true)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- SUB-INTERESTS UNDER NEW CATEGORIES
-- ============================================================

INSERT INTO public.interests (parent_id, key, translation_key, sort_order, is_social, is_business)
VALUES
  -- Arts & Crafts (new category)
  ((SELECT id FROM public.interests WHERE key = 'arts_and_crafts'), 'pottery',       'interest.pottery',       10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'arts_and_crafts'), 'knitting',      'interest.knitting',      20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'arts_and_crafts'), 'scrapbooking',  'interest.scrapbooking',  30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'arts_and_crafts'), 'jewelry_making','interest.jewelry_making',40, true, false),

  -- Wellness (new category)
  ((SELECT id FROM public.interests WHERE key = 'wellness'), 'meditation',  'interest.meditation',   10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'wellness'), 'spa',         'interest.spa',          20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'wellness'), 'massage',     'interest.massage',      30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'wellness'), 'sauna',       'interest.sauna',        40, true, false),

  -- Pets & Animals (new category)
  ((SELECT id FROM public.interests WHERE key = 'pets_and_animals'), 'dog_owners',     'interest.dog_owners',     10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'pets_and_animals'), 'cat_owners',     'interest.cat_owners',     20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'pets_and_animals'), 'horseback',      'interest.horseback',      30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'pets_and_animals'), 'bird_watching',  'interest.bird_watching',  40, true, false),

  -- Travel (new category)
  ((SELECT id FROM public.interests WHERE key = 'travel'), 'beach_vacations',   'interest.beach_vacations',   10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'travel'), 'mountain_retreats', 'interest.mountain_retreats', 20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'travel'), 'city_breaks',       'interest.city_breaks',       30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'travel'), 'cruises',           'interest.cruises',           40, true, false),

  -- Sports (new category)
  ((SELECT id FROM public.interests WHERE key = 'sports'), 'soccer',       'interest.soccer',       10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'sports'), 'basketball',   'interest.basketball',   20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'sports'), 'tennis',       'interest.tennis',       30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'sports'), 'volleyball',   'interest.volleyball',   40, true, false),
  ((SELECT id FROM public.interests WHERE key = 'sports'), 'martial_arts', 'interest.martial_arts', 50, true, false),

  -- Music (new category)
  ((SELECT id FROM public.interests WHERE key = 'music'), 'jazz',          'interest.jazz',          10, true, false),
  ((SELECT id FROM public.interests WHERE key = 'music'), 'classical',     'interest.classical',     20, true, false),
  ((SELECT id FROM public.interests WHERE key = 'music'), 'rock',          'interest.rock',          30, true, false),
  ((SELECT id FROM public.interests WHERE key = 'music'), 'electronic',    'interest.electronic',    40, true, false),
  ((SELECT id FROM public.interests WHERE key = 'music'), 'hip_hop_music', 'interest.hip_hop_music', 50, true, false),

  -- Entrepreneurship Category (new business category)
  ((SELECT id FROM public.interests WHERE key = 'entrepreneurship_cat'), 'startup_events',    'interest.startup_events',    10, false, true),
  ((SELECT id FROM public.interests WHERE key = 'entrepreneurship_cat'), 'pitch_nights',      'interest.pitch_nights',      20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'entrepreneurship_cat'), 'founder_groups',    'interest.founder_groups',    30, false, true),

  -- Technology Category (new business category)
  ((SELECT id FROM public.interests WHERE key = 'technology_cat'), 'tech_meetups',       'interest.tech_meetups',       10, false, true),
  ((SELECT id FROM public.interests WHERE key = 'technology_cat'), 'coding_bootcamps',   'interest.coding_bootcamps',   20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'technology_cat'), 'open_source',        'interest.open_source',        30, false, true),

  -- Consulting Category (new business category)
  ((SELECT id FROM public.interests WHERE key = 'consulting_cat'), 'management_consulting','interest.management_consulting', 10, false, true),
  ((SELECT id FROM public.interests WHERE key = 'consulting_cat'), 'financial_advisory',   'interest.financial_advisory',    20, false, true),
  ((SELECT id FROM public.interests WHERE key = 'consulting_cat'), 'career_coaching',      'interest.career_coaching',       30, false, true)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- TRANSLATIONS (en)
-- ============================================================

INSERT INTO public.translations (key, locale, value) VALUES
  -- New top-level specific interests
  ('interest.photography', 'en', 'Photography'),
  ('interest.cooking', 'en', 'Cooking'),
  ('interest.hiking', 'en', 'Hiking'),
  ('interest.reading', 'en', 'Reading'),
  ('interest.volunteering', 'en', 'Volunteering'),
  ('interest.painting', 'en', 'Painting'),
  ('interest.yoga', 'en', 'Yoga'),
  ('interest.entrepreneurship', 'en', 'Entrepreneurship'),
  ('interest.technology', 'en', 'Technology'),
  ('interest.consulting', 'en', 'Consulting'),
  ('interest.ecommerce', 'en', 'E-Commerce'),

  -- New categories
  ('interest_category.arts_and_crafts', 'en', 'Arts & Crafts'),
  ('interest_category.wellness', 'en', 'Wellness'),
  ('interest_category.pets_and_animals', 'en', 'Pets & Animals'),
  ('interest_category.travel', 'en', 'Travel'),
  ('interest_category.sports', 'en', 'Sports'),
  ('interest_category.music', 'en', 'Music'),
  ('interest_category.entrepreneurship', 'en', 'Entrepreneurship'),
  ('interest_category.technology', 'en', 'Technology'),
  ('interest_category.consulting', 'en', 'Consulting'),

  -- Sub-interests for singing
  ('interest.karaoke', 'en', 'Karaoke'),
  ('interest.choir', 'en', 'Choir'),
  ('interest.open_mic', 'en', 'Open Mic'),

  -- Sub-interests for traveling
  ('interest.backpacking', 'en', 'Backpacking'),
  ('interest.road_trips', 'en', 'Road Trips'),
  ('interest.adventure_travel', 'en', 'Adventure Travel'),
  ('interest.cultural_tourism', 'en', 'Cultural Tourism'),

  -- Sub-interests for eating out
  ('interest.fine_dining', 'en', 'Fine Dining'),
  ('interest.brunch', 'en', 'Brunch'),
  ('interest.food_trucks', 'en', 'Food Trucks'),
  ('interest.ethnic_cuisine', 'en', 'Ethnic Cuisine'),

  -- Sub-interests for dancing
  ('interest.dancing.ballroom', 'en', 'Ballroom'),
  ('interest.dancing.hip_hop', 'en', 'Hip-Hop'),
  ('interest.dancing.contemporary', 'en', 'Contemporary'),
  ('interest.dancing.swing', 'en', 'Swing'),
  ('interest.dancing.bachata', 'en', 'Bachata'),

  -- Sub-interests for startups
  ('interest.saas', 'en', 'SaaS'),
  ('interest.fintech', 'en', 'Fintech'),
  ('interest.biotech', 'en', 'Biotech'),
  ('interest.cleantech', 'en', 'Cleantech'),

  -- Sub-interests for venture capital
  ('interest.seed_stage', 'en', 'Seed Stage'),
  ('interest.growth_equity', 'en', 'Growth Equity'),
  ('interest.angel_investing', 'en', 'Angel Investing'),

  -- Sub-interests for finance
  ('interest.personal_finance', 'en', 'Personal Finance'),
  ('interest.investing', 'en', 'Investing'),
  ('interest.stock_trading', 'en', 'Stock Trading'),

  -- Sub-interests for marketing
  ('interest.digital_marketing', 'en', 'Digital Marketing'),
  ('interest.content_creation', 'en', 'Content Creation'),
  ('interest.brand_strategy', 'en', 'Brand Strategy'),
  ('interest.growth_hacking', 'en', 'Growth Hacking'),

  -- More sub-interests for dates
  ('interest.picnic', 'en', 'Picnic'),
  ('interest.stargazing', 'en', 'Stargazing'),
  ('interest.amusement_park', 'en', 'Amusement Park'),

  -- More sub-interests for music_and_art
  ('interest.concerts', 'en', 'Concerts'),
  ('interest.theater', 'en', 'Theater'),
  ('interest.museums', 'en', 'Museums'),
  ('interest.festivals', 'en', 'Festivals'),

  -- More sub-interests for food_and_drink
  ('interest.wine_tasting', 'en', 'Wine Tasting'),
  ('interest.craft_beer', 'en', 'Craft Beer'),
  ('interest.tea', 'en', 'Tea'),

  -- More sub-interests for hangouts
  ('interest.trivia_nights', 'en', 'Trivia Nights'),
  ('interest.rooftop_bars', 'en', 'Rooftop Bars'),

  -- More sub-interests for group_activities
  ('interest.book_clubs', 'en', 'Book Clubs'),
  ('interest.cooking_classes', 'en', 'Cooking Classes'),
  ('interest.dance_classes', 'en', 'Dance Classes'),

  -- More sub-interests for study_and_learning
  ('interest.workshops', 'en', 'Workshops'),
  ('interest.online_courses', 'en', 'Online Courses'),
  ('interest.lectures', 'en', 'Lectures'),

  -- More sub-interests for fitness
  ('interest.running_clubs', 'en', 'Running Clubs'),
  ('interest.cycling', 'en', 'Cycling'),
  ('interest.swimming', 'en', 'Swimming'),
  ('interest.crossfit', 'en', 'Crossfit'),
  ('interest.pilates', 'en', 'Pilates'),

  -- More sub-interests for outdoors
  ('interest.camping', 'en', 'Camping'),
  ('interest.fishing', 'en', 'Fishing'),
  ('interest.kayaking', 'en', 'Kayaking'),
  ('interest.climbing', 'en', 'Climbing'),
  ('interest.mountain_biking', 'en', 'Mountain Biking'),

  -- More sub-interests for gaming
  ('interest.video_games', 'en', 'Video Games'),
  ('interest.esports', 'en', 'Esports'),
  ('interest.tabletop_rpg', 'en', 'Tabletop RPGs'),
  ('interest.card_games', 'en', 'Card Games'),

  -- More sub-interests for mentorship
  ('interest.career_guidance', 'en', 'Career Guidance'),
  ('interest.leadership_coaching', 'en', 'Leadership Coaching'),
  ('interest.technical_mentorship', 'en', 'Technical Mentorship'),

  -- More sub-interests for business_events
  ('interest.conferences', 'en', 'Conferences'),
  ('interest.networking_mixers', 'en', 'Networking Mixers'),
  ('interest.trade_shows', 'en', 'Trade Shows'),
  ('interest.hackathons', 'en', 'Hackathons'),

  -- More sub-interests for skill_sharing
  ('interest.coding_workshops', 'en', 'Coding Workshops'),
  ('interest.design_critiques', 'en', 'Design Critiques'),
  ('interest.language_partners', 'en', 'Language Partners'),
  ('interest.public_speaking', 'en', 'Public Speaking'),

  -- Sub-interests for new interest: photography
  ('interest.photography.portrait', 'en', 'Portrait'),
  ('interest.photography.landscape', 'en', 'Landscape'),
  ('interest.photography.street', 'en', 'Street Photography'),
  ('interest.photography.wildlife', 'en', 'Wildlife'),

  -- Sub-interests for new interest: cooking
  ('interest.cooking.baking', 'en', 'Baking'),
  ('interest.cooking.grilling', 'en', 'Grilling'),
  ('interest.cooking.international_cuisine', 'en', 'International Cuisine'),
  ('interest.cooking.vegan', 'en', 'Vegan Cooking'),

  -- Sub-interests for new interest: hiking
  ('interest.hiking.day_hikes', 'en', 'Day Hikes'),
  ('interest.hiking.overnight_treks', 'en', 'Overnight Treks'),
  ('interest.hiking.nature_trails', 'en', 'Nature Trails'),
  ('interest.hiking.mountain', 'en', 'Mountain Hiking'),

  -- Sub-interests for new interest: reading
  ('interest.reading.fiction', 'en', 'Fiction'),
  ('interest.reading.non_fiction', 'en', 'Non-Fiction'),
  ('interest.reading.poetry', 'en', 'Poetry'),

  -- Sub-interests for new interest: volunteering
  ('interest.volunteering.community', 'en', 'Community Service'),
  ('interest.volunteering.animals', 'en', 'Animal Rescue'),
  ('interest.volunteering.environment', 'en', 'Environmental Protection'),
  ('interest.volunteering.education', 'en', 'Educational Volunteering'),

  -- Sub-interests for new interest: painting
  ('interest.painting.oil', 'en', 'Oil Painting'),
  ('interest.painting.watercolor', 'en', 'Watercolor'),
  ('interest.painting.acrylic', 'en', 'Acrylic'),

  -- Sub-interests for new interest: yoga
  ('interest.yoga.hatha', 'en', 'Hatha'),
  ('interest.yoga.vinyasa', 'en', 'Vinyasa'),
  ('interest.yoga.ashtanga', 'en', 'Ashtanga'),
  ('interest.yoga.meditation', 'en', 'Meditation'),

  -- Sub-interests for entrepreneurship
  ('interest.entrepreneurship.bootstrapping', 'en', 'Bootstrapping'),
  ('interest.entrepreneurship.social_enterprise', 'en', 'Social Enterprise'),
  ('interest.entrepreneurship.side_hustles', 'en', 'Side Hustles'),
  ('interest.entrepreneurship.incubators', 'en', 'Incubators & Accelerators'),

  -- Sub-interests for technology
  ('interest.technology.ai_ml', 'en', 'AI & Machine Learning'),
  ('interest.technology.cybersecurity', 'en', 'Cybersecurity'),
  ('interest.technology.web_development', 'en', 'Web Development'),
  ('interest.technology.mobile_dev', 'en', 'Mobile Development'),
  ('interest.technology.cloud_computing', 'en', 'Cloud Computing'),

  -- Sub-interests for consulting
  ('interest.consulting.strategy', 'en', 'Strategy Consulting'),
  ('interest.consulting.operations', 'en', 'Operations Consulting'),
  ('interest.consulting.hr', 'en', 'HR Consulting'),
  ('interest.consulting.it', 'en', 'IT Consulting'),

  -- Sub-interests for ecommerce
  ('interest.ecommerce.dropshipping', 'en', 'Dropshipping'),
  ('interest.ecommerce.amazon_fba', 'en', 'Amazon FBA'),
  ('interest.ecommerce.shopify', 'en', 'Shopify Stores'),
  ('interest.ecommerce.digital_products', 'en', 'Digital Products'),

  -- Sub-interests for new categories
  ('interest.pottery', 'en', 'Pottery'),
  ('interest.knitting', 'en', 'Knitting'),
  ('interest.scrapbooking', 'en', 'Scrapbooking'),
  ('interest.jewelry_making', 'en', 'Jewelry Making'),
  ('interest.spa', 'en', 'Spa'),
  ('interest.massage', 'en', 'Massage'),
  ('interest.sauna', 'en', 'Sauna'),
  ('interest.dog_owners', 'en', 'Dog Owners'),
  ('interest.cat_owners', 'en', 'Cat Owners'),
  ('interest.horseback', 'en', 'Horseback Riding'),
  ('interest.bird_watching', 'en', 'Bird Watching'),
  ('interest.beach_vacations', 'en', 'Beach Vacations'),
  ('interest.mountain_retreats', 'en', 'Mountain Retreats'),
  ('interest.city_breaks', 'en', 'City Breaks'),
  ('interest.cruises', 'en', 'Cruises'),
  ('interest.soccer', 'en', 'Soccer'),
  ('interest.basketball', 'en', 'Basketball'),
  ('interest.tennis', 'en', 'Tennis'),
  ('interest.volleyball', 'en', 'Volleyball'),
  ('interest.martial_arts', 'en', 'Martial Arts'),
  ('interest.jazz', 'en', 'Jazz'),
  ('interest.classical', 'en', 'Classical'),
  ('interest.rock', 'en', 'Rock'),
  ('interest.electronic', 'en', 'Electronic'),
  ('interest.hip_hop_music', 'en', 'Hip-Hop'),
  ('interest.startup_events', 'en', 'Startup Events'),
  ('interest.pitch_nights', 'en', 'Pitch Nights'),
  ('interest.founder_groups', 'en', 'Founder Groups'),
  ('interest.tech_meetups', 'en', 'Tech Meetups'),
  ('interest.coding_bootcamps', 'en', 'Coding Bootcamps'),
  ('interest.open_source', 'en', 'Open Source'),
  ('interest.management_consulting', 'en', 'Management Consulting'),
  ('interest.financial_advisory', 'en', 'Financial Advisory'),
  ('interest.career_coaching', 'en', 'Career Coaching')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- ============================================================
-- TRANSLATIONS (es)
-- ============================================================

INSERT INTO public.translations (key, locale, value) VALUES
  -- New top-level specific interests
  ('interest.photography', 'es', 'Fotografia'),
  ('interest.cooking', 'es', 'Cocinar'),
  ('interest.hiking', 'es', 'Senderismo'),
  ('interest.reading', 'es', 'Leer'),
  ('interest.volunteering', 'es', 'Voluntariado'),
  ('interest.painting', 'es', 'Pintura'),
  ('interest.yoga', 'es', 'Yoga'),
  ('interest.entrepreneurship', 'es', 'Emprendimiento'),
  ('interest.technology', 'es', 'Tecnologia'),
  ('interest.consulting', 'es', 'Consultoria'),
  ('interest.ecommerce', 'es', 'Comercio Electronico'),

  -- New categories
  ('interest_category.arts_and_crafts', 'es', 'Artes y Manualidades'),
  ('interest_category.wellness', 'es', 'Bienestar'),
  ('interest_category.pets_and_animals', 'es', 'Mascotas y Animales'),
  ('interest_category.travel', 'es', 'Viajes'),
  ('interest_category.sports', 'es', 'Deportes'),
  ('interest_category.music', 'es', 'Musica'),
  ('interest_category.entrepreneurship', 'es', 'Emprendimiento'),
  ('interest_category.technology', 'es', 'Tecnologia'),
  ('interest_category.consulting', 'es', 'Consultoria'),

  -- Sub-interests for singing
  ('interest.karaoke', 'es', 'Karaoke'),
  ('interest.choir', 'es', 'Coro'),
  ('interest.open_mic', 'es', 'Microfono Abierto'),

  -- Sub-interests for traveling
  ('interest.backpacking', 'es', 'Mochilero'),
  ('interest.road_trips', 'es', 'Viajes por Carretera'),
  ('interest.adventure_travel', 'es', 'Viajes de Aventura'),
  ('interest.cultural_tourism', 'es', 'Turismo Cultural'),

  -- Sub-interests for eating out
  ('interest.fine_dining', 'es', 'Alta Cocina'),
  ('interest.brunch', 'es', 'Brunch'),
  ('interest.food_trucks', 'es', 'Puestos de Comida'),
  ('interest.ethnic_cuisine', 'es', 'Cocina Etnica'),

  -- Sub-interests for dancing
  ('interest.dancing.ballroom', 'es', 'Baile de Salon'),
  ('interest.dancing.hip_hop', 'es', 'Hip-Hop'),
  ('interest.dancing.contemporary', 'es', 'Contemporaneo'),
  ('interest.dancing.swing', 'es', 'Swing'),
  ('interest.dancing.bachata', 'es', 'Bachata'),

  -- Sub-interests for startups
  ('interest.saas', 'es', 'SaaS'),
  ('interest.fintech', 'es', 'Fintech'),
  ('interest.biotech', 'es', 'Biotecnologia'),
  ('interest.cleantech', 'es', 'Tecnologia Limpia'),

  -- Sub-interests for venture capital
  ('interest.seed_stage', 'es', 'Etapa Semilla'),
  ('interest.growth_equity', 'es', 'Capital de Crecimiento'),
  ('interest.angel_investing', 'es', 'Inversion Angel'),

  -- Sub-interests for finance
  ('interest.personal_finance', 'es', 'Finanzas Personales'),
  ('interest.investing', 'es', 'Inversiones'),
  ('interest.stock_trading', 'es', 'Negociacion de Acciones'),

  -- Sub-interests for marketing
  ('interest.digital_marketing', 'es', 'Marketing Digital'),
  ('interest.content_creation', 'es', 'Creacion de Contenido'),
  ('interest.brand_strategy', 'es', 'Estrategia de Marca'),
  ('interest.growth_hacking', 'es', 'Growth Hacking'),

  -- More sub-interests for dates
  ('interest.picnic', 'es', 'Picnic'),
  ('interest.stargazing', 'es', 'Observacion de Estrellas'),
  ('interest.amusement_park', 'es', 'Parque de Diversiones'),

  -- More sub-interests for music_and_art
  ('interest.concerts', 'es', 'Conciertos'),
  ('interest.theater', 'es', 'Teatro'),
  ('interest.museums', 'es', 'Museos'),
  ('interest.festivals', 'es', 'Festivales'),

  -- More sub-interests for food_and_drink
  ('interest.wine_tasting', 'es', 'Cata de Vinos'),
  ('interest.craft_beer', 'es', 'Cerveza Artesanal'),
  ('interest.tea', 'es', 'Te'),

  -- More sub-interests for hangouts
  ('interest.trivia_nights', 'es', 'Noches de Trivia'),
  ('interest.rooftop_bars', 'es', 'Bares en Azoteas'),

  -- More sub-interests for group_activities
  ('interest.book_clubs', 'es', 'Clubes de Lectura'),
  ('interest.cooking_classes', 'es', 'Clases de Cocina'),
  ('interest.dance_classes', 'es', 'Clases de Baile'),

  -- More sub-interests for study_and_learning
  ('interest.workshops', 'es', 'Talleres'),
  ('interest.online_courses', 'es', 'Cursos en Linea'),
  ('interest.lectures', 'es', 'Conferencias'),

  -- More sub-interests for fitness
  ('interest.running_clubs', 'es', 'Clubes de Corredores'),
  ('interest.cycling', 'es', 'Ciclismo'),
  ('interest.swimming', 'es', 'Natacion'),
  ('interest.crossfit', 'es', 'Crossfit'),
  ('interest.pilates', 'es', 'Pilates'),

  -- More sub-interests for outdoors
  ('interest.camping', 'es', 'Campamento'),
  ('interest.fishing', 'es', 'Pesca'),
  ('interest.kayaking', 'es', 'Kayak'),
  ('interest.climbing', 'es', 'Escalada'),
  ('interest.mountain_biking', 'es', 'Ciclismo de Montana'),

  -- More sub-interests for gaming
  ('interest.video_games', 'es', 'Videojuegos'),
  ('interest.esports', 'es', 'Esports'),
  ('interest.tabletop_rpg', 'es', 'Juegos de Mesa RPG'),
  ('interest.card_games', 'es', 'Juegos de Cartas'),

  -- More sub-interests for mentorship
  ('interest.career_guidance', 'es', 'Orientacion Profesional'),
  ('interest.leadership_coaching', 'es', 'Coaching de Liderazgo'),
  ('interest.technical_mentorship', 'es', 'Mentoria Tecnica'),

  -- More sub-interests for business_events
  ('interest.conferences', 'es', 'Conferencias'),
  ('interest.networking_mixers', 'es', 'Eventos de Networking'),
  ('interest.trade_shows', 'es', 'Ferias Comerciales'),
  ('interest.hackathons', 'es', 'Hackathons'),

  -- More sub-interests for skill_sharing
  ('interest.coding_workshops', 'es', 'Talleres de Programacion'),
  ('interest.design_critiques', 'es', 'Criticas de Diseno'),
  ('interest.language_partners', 'es', 'Intercambio de Idiomas'),
  ('interest.public_speaking', 'es', 'Hablar en Publico'),

  -- Sub-interests for new interest: photography
  ('interest.photography.portrait', 'es', 'Retrato'),
  ('interest.photography.landscape', 'es', 'Paisaje'),
  ('interest.photography.street', 'es', 'Fotografia Callejera'),
  ('interest.photography.wildlife', 'es', 'Vida Salvaje'),

  -- Sub-interests for new interest: cooking
  ('interest.cooking.baking', 'es', 'Hornear'),
  ('interest.cooking.grilling', 'es', 'Asar a la Parrilla'),
  ('interest.cooking.international_cuisine', 'es', 'Cocina Internacional'),
  ('interest.cooking.vegan', 'es', 'Cocina Vegana'),

  -- Sub-interests for new interest: hiking
  ('interest.hiking.day_hikes', 'es', 'Excursiones de Dia'),
  ('interest.hiking.overnight_treks', 'es', 'Excursiones Nocturnas'),
  ('interest.hiking.nature_trails', 'es', 'Senderos Naturales'),
  ('interest.hiking.mountain', 'es', 'Senderismo de Montana'),

  -- Sub-interests for new interest: reading
  ('interest.reading.fiction', 'es', 'Ficcion'),
  ('interest.reading.non_fiction', 'es', 'No Ficcion'),
  ('interest.reading.poetry', 'es', 'Poesia'),

  -- Sub-interests for new interest: volunteering
  ('interest.volunteering.community', 'es', 'Servicio Comunitario'),
  ('interest.volunteering.animals', 'es', 'Rescate de Animales'),
  ('interest.volunteering.environment', 'es', 'Proteccion Ambiental'),
  ('interest.volunteering.education', 'es', 'Voluntariado Educativo'),

  -- Sub-interests for new interest: painting
  ('interest.painting.oil', 'es', 'Pintura al Oleo'),
  ('interest.painting.watercolor', 'es', 'Acuarela'),
  ('interest.painting.acrylic', 'es', 'Acrilico'),

  -- Sub-interests for new interest: yoga
  ('interest.yoga.hatha', 'es', 'Hatha'),
  ('interest.yoga.vinyasa', 'es', 'Vinyasa'),
  ('interest.yoga.ashtanga', 'es', 'Ashtanga'),
  ('interest.yoga.meditation', 'es', 'Meditacion'),

  -- Sub-interests for entrepreneurship
  ('interest.entrepreneurship.bootstrapping', 'es', 'Bootstrapping'),
  ('interest.entrepreneurship.social_enterprise', 'es', 'Empresa Social'),
  ('interest.entrepreneurship.side_hustles', 'es', 'Trabajos Extra'),
  ('interest.entrepreneurship.incubators', 'es', 'Incubadoras y Aceleradoras'),

  -- Sub-interests for technology
  ('interest.technology.ai_ml', 'es', 'IA y Aprendizaje Automatico'),
  ('interest.technology.cybersecurity', 'es', 'Ciberseguridad'),
  ('interest.technology.web_development', 'es', 'Desarrollo Web'),
  ('interest.technology.mobile_dev', 'es', 'Desarrollo Movil'),
  ('interest.technology.cloud_computing', 'es', 'Computacion en la Nube'),

  -- Sub-interests for consulting
  ('interest.consulting.strategy', 'es', 'Consultoria Estrategica'),
  ('interest.consulting.operations', 'es', 'Consultoria Operativa'),
  ('interest.consulting.hr', 'es', 'Consultoria de RRHH'),
  ('interest.consulting.it', 'es', 'Consultoria TI'),

  -- Sub-interests for ecommerce
  ('interest.ecommerce.dropshipping', 'es', 'Dropshipping'),
  ('interest.ecommerce.amazon_fba', 'es', 'Amazon FBA'),
  ('interest.ecommerce.shopify', 'es', 'Tiendas Shopify'),
  ('interest.ecommerce.digital_products', 'es', 'Productos Digitales'),

  -- Sub-interests for new categories
  ('interest.pottery', 'es', 'Alfareria'),
  ('interest.knitting', 'es', 'Tejer'),
  ('interest.scrapbooking', 'es', 'Scrapbooking'),
  ('interest.jewelry_making', 'es', 'Fabricacion de Joyas'),
  ('interest.spa', 'es', 'Spa'),
  ('interest.massage', 'es', 'Masaje'),
  ('interest.sauna', 'es', 'Sauna'),
  ('interest.dog_owners', 'es', 'Duennos de Perros'),
  ('interest.cat_owners', 'es', 'Duennos de Gatos'),
  ('interest.horseback', 'es', 'Equitacion'),
  ('interest.bird_watching', 'es', 'Observacion de Aves'),
  ('interest.beach_vacations', 'es', 'Vacaciones en la Playa'),
  ('interest.mountain_retreats', 'es', 'Retiros de Montana'),
  ('interest.city_breaks', 'es', 'Escapadas Urbanas'),
  ('interest.cruises', 'es', 'Cruceros'),
  ('interest.soccer', 'es', 'Futbol'),
  ('interest.basketball', 'es', 'Baloncesto'),
  ('interest.tennis', 'es', 'Tenis'),
  ('interest.volleyball', 'es', 'Voleibol'),
  ('interest.martial_arts', 'es', 'Artes Marciales'),
  ('interest.jazz', 'es', 'Jazz'),
  ('interest.classical', 'es', 'Clasica'),
  ('interest.rock', 'es', 'Rock'),
  ('interest.electronic', 'es', 'Electronica'),
  ('interest.hip_hop_music', 'es', 'Hip-Hop'),
  ('interest.startup_events', 'es', 'Eventos de Startups'),
  ('interest.pitch_nights', 'es', 'Noches de Presentacion'),
  ('interest.founder_groups', 'es', 'Grupos de Fundadores'),
  ('interest.tech_meetups', 'es', 'Encuentros Tecnologicos'),
  ('interest.coding_bootcamps', 'es', 'Bootcamps de Programacion'),
  ('interest.open_source', 'es', 'Codigo Abierto'),
  ('interest.management_consulting', 'es', 'Consultoria de Gestion'),
  ('interest.financial_advisory', 'es', 'Asesoria Financiera'),
  ('interest.career_coaching', 'es', 'Coaching Profesional')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

-- ============================================================
-- TRANSLATIONS (he)
-- ============================================================

INSERT INTO public.translations (key, locale, value) VALUES
  -- New top-level specific interests
  ('interest.photography', 'he', 'צילום'),
  ('interest.cooking', 'he', 'בישול'),
  ('interest.hiking', 'he', 'טיולים רגליים'),
  ('interest.reading', 'he', 'קריאה'),
  ('interest.volunteering', 'he', 'התנדבות'),
  ('interest.painting', 'he', 'ציור'),
  ('interest.yoga', 'he', 'יוגה'),
  ('interest.entrepreneurship', 'he', 'יזמות'),
  ('interest.technology', 'he', 'טכנולוגיה'),
  ('interest.consulting', 'he', 'ייעוץ'),
  ('interest.ecommerce', 'he', 'מסחר אלקטרוני'),

  -- New categories
  ('interest_category.arts_and_crafts', 'he', 'אומנויות ומלאכה'),
  ('interest_category.wellness', 'he', 'רווחה'),
  ('interest_category.pets_and_animals', 'he', 'חיות מחמד ובעלי חיים'),
  ('interest_category.travel', 'he', 'טיולים'),
  ('interest_category.sports', 'he', 'ספורט'),
  ('interest_category.music', 'he', 'מוזיקה'),
  ('interest_category.entrepreneurship', 'he', 'יזמות'),
  ('interest_category.technology', 'he', 'טכנולוגיה'),
  ('interest_category.consulting', 'he', 'ייעוץ'),

  -- Sub-interests for singing
  ('interest.karaoke', 'he', 'קריוקי'),
  ('interest.choir', 'he', 'מקהלה'),
  ('interest.open_mic', 'he', 'במה פתוחה'),

  -- Sub-interests for traveling
  ('interest.backpacking', 'he', 'טיול תרמילאים'),
  ('interest.road_trips', 'he', 'טיולי כביש'),
  ('interest.adventure_travel', 'he', 'טיולי הרפתקאות'),
  ('interest.cultural_tourism', 'he', 'תיירות תרבותית'),

  -- Sub-interests for eating out
  ('interest.fine_dining', 'he', 'מסעדות יוקרה'),
  ('interest.brunch', 'he', 'בראנץ'''),
  ('interest.food_trucks', 'he', 'אוכל רחוב'),
  ('interest.ethnic_cuisine', 'he', 'מטבח אתני'),

  -- Sub-interests for dancing
  ('interest.dancing.ballroom', 'he', 'ריקוד סלוני'),
  ('interest.dancing.hip_hop', 'he', 'היפ הופ'),
  ('interest.dancing.contemporary', 'he', 'עכשווי'),
  ('interest.dancing.swing', 'he', 'סווינג'),
  ('interest.dancing.bachata', 'he', 'באצ''טה'),

  -- Sub-interests for startups
  ('interest.saas', 'he', 'SaaS'),
  ('interest.fintech', 'he', 'פינטק'),
  ('interest.biotech', 'he', 'ביוטק'),
  ('interest.cleantech', 'he', 'קלינטק'),

  -- Sub-interests for venture capital
  ('interest.seed_stage', 'he', 'שלב הסיד'),
  ('interest.growth_equity', 'he', 'הון צמיחה'),
  ('interest.angel_investing', 'he', 'השקעות אנג''ל'),

  -- Sub-interests for finance
  ('interest.personal_finance', 'he', 'מימון אישי'),
  ('interest.investing', 'he', 'השקעות'),
  ('interest.stock_trading', 'he', 'מסחר במניות'),

  -- Sub-interests for marketing
  ('interest.digital_marketing', 'he', 'שיווק דיגיטלי'),
  ('interest.content_creation', 'he', 'יצירת תוכן'),
  ('interest.brand_strategy', 'he', 'אסטרטגיית מותג'),
  ('interest.growth_hacking', 'he', 'גרוט'' האקינג'),

  -- More sub-interests for dates
  ('interest.picnic', 'he', 'פיקניק'),
  ('interest.stargazing', 'he', 'צפייה בכוכבים'),
  ('interest.amusement_park', 'he', 'פארק שעשועים'),

  -- More sub-interests for music_and_art
  ('interest.concerts', 'he', 'הופעות'),
  ('interest.theater', 'he', 'תיאטרון'),
  ('interest.museums', 'he', 'מוזיאונים'),
  ('interest.festivals', 'he', 'פסטיבלים'),

  -- More sub-interests for food_and_drink
  ('interest.wine_tasting', 'he', 'טעימות יין'),
  ('interest.craft_beer', 'he', 'בירה מלאכה'),
  ('interest.tea', 'he', 'תה'),

  -- More sub-interests for hangouts
  ('interest.trivia_nights', 'he', 'לילות טריוויה'),
  ('interest.rooftop_bars', 'he', 'ברים על גג'),

  -- More sub-interests for group_activities
  ('interest.book_clubs', 'he', 'מועדוני ספרים'),
  ('interest.cooking_classes', 'he', 'סדנאות בישול'),
  ('interest.dance_classes', 'he', 'שיעורי ריקוד'),

  -- More sub-interests for study_and_learning
  ('interest.workshops', 'he', 'סדנאות'),
  ('interest.online_courses', 'he', 'קורסים מקוונים'),
  ('interest.lectures', 'he', 'הרצאות'),

  -- More sub-interests for fitness
  ('interest.running_clubs', 'he', 'מועדוני ריצה'),
  ('interest.cycling', 'he', 'רכיבת אופניים'),
  ('interest.swimming', 'he', 'שחייה'),
  ('interest.crossfit', 'he', 'קרוספיט'),
  ('interest.pilates', 'he', 'פילאטיס'),

  -- More sub-interests for outdoors
  ('interest.camping', 'he', 'קמפינג'),
  ('interest.fishing', 'he', 'דיג'),
  ('interest.kayaking', 'he', 'קיאקים'),
  ('interest.climbing', 'he', 'טיפוס'),
  ('interest.mountain_biking', 'he', 'אופני הרים'),

  -- More sub-interests for gaming
  ('interest.video_games', 'he', 'משחקי וידאו'),
  ('interest.esports', 'he', 'ספורט אלקטרוני'),
  ('interest.tabletop_rpg', 'he', 'משחקי שולחן RPG'),
  ('interest.card_games', 'he', 'משחקי קלפים'),

  -- More sub-interests for mentorship
  ('interest.career_guidance', 'he', 'הכוונה מקצועית'),
  ('interest.leadership_coaching', 'he', 'אימון מנהיגות'),
  ('interest.technical_mentorship', 'he', 'חונכות טכנית'),

  -- More sub-interests for business_events
  ('interest.conferences', 'he', 'כנסים'),
  ('interest.networking_mixers', 'he', 'מפגשי נטוורקינג'),
  ('interest.trade_shows', 'he', 'תערוכות'),
  ('interest.hackathons', 'he', 'האקתונים'),

  -- More sub-interests for skill_sharing
  ('interest.coding_workshops', 'he', 'סדנאות קידוד'),
  ('interest.design_critiques', 'he', 'ביקורת עיצוב'),
  ('interest.language_partners', 'he', 'שותפי שפה'),
  ('interest.public_speaking', 'he', 'דיבור בציבור'),

  -- Sub-interests for new interest: photography
  ('interest.photography.portrait', 'he', 'פורטרט'),
  ('interest.photography.landscape', 'he', 'נוף'),
  ('interest.photography.street', 'he', 'צילום רחוב'),
  ('interest.photography.wildlife', 'he', 'חיות בר'),

  -- Sub-interests for new interest: cooking
  ('interest.cooking.baking', 'he', 'אפייה'),
  ('interest.cooking.grilling', 'he', 'צלייה'),
  ('interest.cooking.international_cuisine', 'he', 'מטבח בינלאומי'),
  ('interest.cooking.vegan', 'he', 'בישול טבעוני'),

  -- Sub-interests for new interest: hiking
  ('interest.hiking.day_hikes', 'he', 'טיולי יום'),
  ('interest.hiking.overnight_treks', 'he', 'טרקים ליליים'),
  ('interest.hiking.nature_trails', 'he', 'שבילי טבע'),
  ('interest.hiking.mountain', 'he', 'טיולי הרים'),

  -- Sub-interests for new interest: reading
  ('interest.reading.fiction', 'he', 'סיפורת'),
  ('interest.reading.non_fiction', 'he', 'עיון'),
  ('interest.reading.poetry', 'he', 'שירה'),

  -- Sub-interests for new interest: volunteering
  ('interest.volunteering.community', 'he', 'שירות קהילתי'),
  ('interest.volunteering.animals', 'he', 'הצלת בעלי חיים'),
  ('interest.volunteering.environment', 'he', 'שמירת הסביבה'),
  ('interest.volunteering.education', 'he', 'התנדבות חינוכית'),

  -- Sub-interests for new interest: painting
  ('interest.painting.oil', 'he', 'ציור שמן'),
  ('interest.painting.watercolor', 'he', 'צבעי מים'),
  ('interest.painting.acrylic', 'he', 'אקריליק'),

  -- Sub-interests for new interest: yoga
  ('interest.yoga.hatha', 'he', 'האתה'),
  ('interest.yoga.vinyasa', 'he', 'ויניאסה'),
  ('interest.yoga.ashtanga', 'he', 'אשטנגה'),
  ('interest.yoga.meditation', 'he', 'מדיטציה'),

  -- Sub-interests for entrepreneurship
  ('interest.entrepreneurship.bootstrapping', 'he', 'בוטסטראפינג'),
  ('interest.entrepreneurship.social_enterprise', 'he', 'מיזם חברתי'),
  ('interest.entrepreneurship.side_hustles', 'he', 'עבודה צדדית'),
  ('interest.entrepreneurship.incubators', 'he', 'אינקובטורים ומאיצים'),

  -- Sub-interests for technology
  ('interest.technology.ai_ml', 'he', 'AI ולמידת מכונה'),
  ('interest.technology.cybersecurity', 'he', 'אבטחת סייבר'),
  ('interest.technology.web_development', 'he', 'פיתוח אתרים'),
  ('interest.technology.mobile_dev', 'he', 'פיתוח מובייל'),
  ('interest.technology.cloud_computing', 'he', 'מחשוב ענן'),

  -- Sub-interests for consulting
  ('interest.consulting.strategy', 'he', 'ייעוץ אסטרטגי'),
  ('interest.consulting.operations', 'he', 'ייעוץ תפעולי'),
  ('interest.consulting.hr', 'he', 'ייעוץ משאבי אנוש'),
  ('interest.consulting.it', 'he', 'ייעוץ IT'),

  -- Sub-interests for ecommerce
  ('interest.ecommerce.dropshipping', 'he', 'דרופשיפינג'),
  ('interest.ecommerce.amazon_fba', 'he', 'אמזון FBA'),
  ('interest.ecommerce.shopify', 'he', 'חנויות Shopify'),
  ('interest.ecommerce.digital_products', 'he', 'מוצרים דיגיטליים'),

  -- Sub-interests for new categories
  ('interest.pottery', 'he', 'קדרות'),
  ('interest.knitting', 'he', 'סריגה'),
  ('interest.scrapbooking', 'he', 'סקראפבוקינג'),
  ('interest.jewelry_making', 'he', 'ייצור תכשיטים'),
  ('interest.spa', 'he', 'ספא'),
  ('interest.massage', 'he', 'עיסוי'),
  ('interest.sauna', 'he', 'סאונה'),
  ('interest.dog_owners', 'he', 'בעלי כלבים'),
  ('interest.cat_owners', 'he', 'בעלי חתולים'),
  ('interest.horseback', 'he', 'רכיבה על סוסים'),
  ('interest.bird_watching', 'he', 'צפרות'),
  ('interest.beach_vacations', 'he', 'חופשות חוף'),
  ('interest.mountain_retreats', 'he', 'נופש הרים'),
  ('interest.city_breaks', 'he', 'חופשות עירוניות'),
  ('interest.cruises', 'he', 'שייט'),
  ('interest.soccer', 'he', 'כדורגל'),
  ('interest.basketball', 'he', 'כדורסל'),
  ('interest.tennis', 'he', 'טניס'),
  ('interest.volleyball', 'he', 'כדורעף'),
  ('interest.martial_arts', 'he', 'אמנויות לחימה'),
  ('interest.jazz', 'he', 'ג''אז'),
  ('interest.classical', 'he', 'קלאסי'),
  ('interest.rock', 'he', 'רוק'),
  ('interest.electronic', 'he', 'אלקטרוני'),
  ('interest.hip_hop_music', 'he', 'היפ הופ'),
  ('interest.startup_events', 'he', 'אירועי סטארטאפים'),
  ('interest.pitch_nights', 'he', 'ערבי פיץ'''),
  ('interest.founder_groups', 'he', 'קבוצות מייסדים'),
  ('interest.tech_meetups', 'he', 'מפגשי טכנולוגיה'),
  ('interest.coding_bootcamps', 'he', 'בוטקאמפים לקידוד'),
  ('interest.open_source', 'he', 'קוד פתוח'),
  ('interest.management_consulting', 'he', 'ייעוץ ניהולי'),
  ('interest.financial_advisory', 'he', 'ייעוץ פיננסי'),
  ('interest.career_coaching', 'he', 'אימון קריירה')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
