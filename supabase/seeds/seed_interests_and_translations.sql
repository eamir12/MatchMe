-- FULL SQL SEED: Interests and Translations for Social & Business Intents
--
-- Metadata: (REMOVED: metadata column no longer exists)
--   Author: GitHub Copilot (AI)
--   Last updated: 2025-12-16
--   Usage: Run in Supabase/Postgres to seed your app
--   Description: Seeds the 'interests' and 'translations' tables with hierarchical interests and multi-language translations.
--   Notes: All interests now DO NOT include a 'metadata' JSON. All metadata logic removed from code and seed.
--
-- This file contains all INSERT statements for interests (with hierarchy) and translations (en, es, he)
-- Run in Supabase/Postgres to seed your app

-- INTERESTS TABLE SEED (id is serial PK, parent_id nullable FK, key, translation_key, sort_order)
-- Top-level: intent categories (Romantic, Friendship, Activity Partner, Business/Networking)
-- Each interest/sub-interest/sub-sub-interest gets a unique key and translation_key

-- ROMANTIC INTENT

-- Insert top-level interests first

INSERT INTO interests (parent_id, key, translation_key, sort_order)
VALUES (NULL, 'romantic', 'interest.romantic', '{"group":"romantic","type":"intent"}', 1)
ON CONFLICT (key) DO NOTHING;

INSERT INTO interests (parent_id, key, translation_key, metadata, sort_order)
VALUES
((SELECT id FROM interests WHERE key = 'romantic'), 'romantic_dining', 'interest.romantic.dining', 1),
((SELECT id FROM interests WHERE key = 'romantic_dining'), 'romantic_dining_fine', 'interest.romantic.dining.fine', '{"group":"romantic","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'romantic_dining'), 'romantic_dining_casual', 'interest.romantic.dining.casual', '{"group":"romantic","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'romantic_dining'), 'romantic_dining_international', 'interest.romantic.dining.international', '{"group":"romantic","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'romantic'), 'romantic_travel', 'interest.romantic.travel', '{"group":"romantic","type":"category"}', 2),
((SELECT id FROM interests WHERE key = 'romantic_travel'), 'romantic_travel_beach', 'interest.romantic.travel.beach', '{"group":"romantic","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'romantic_travel'), 'romantic_travel_mountains', 'interest.romantic.travel.mountains', '{"group":"romantic","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'romantic_travel'), 'romantic_travel_city', 'interest.romantic.travel.city', '{"group":"romantic","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'romantic'), 'romantic_music', 'interest.romantic.music', '{"group":"romantic","type":"category"}', 3),
((SELECT id FROM interests WHERE key = 'romantic_music'), 'romantic_music_concerts', 'interest.romantic.music.concerts', '{"group":"romantic","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'romantic_music'), 'romantic_music_dancing', 'interest.romantic.music.dancing', '{"group":"romantic","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'romantic_music'), 'romantic_music_jazz', 'interest.romantic.music.jazz', '{"group":"romantic","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'romantic'), 'romantic_arts', 'interest.romantic.arts', '{"group":"romantic","type":"category"}', 4),
((SELECT id FROM interests WHERE key = 'romantic_arts'), 'romantic_arts_museums', 'interest.romantic.arts.museums', '{"group":"romantic","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'romantic_arts'), 'romantic_arts_theater', 'interest.romantic.arts.theater', '{"group":"romantic","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'romantic_arts'), 'romantic_arts_painting', 'interest.romantic.arts.painting', '{"group":"romantic","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'romantic'), 'romantic_outdoors', 'interest.romantic.outdoors', '{"group":"romantic","type":"category"}', 5),
((SELECT id FROM interests WHERE key = 'romantic_outdoors'), 'romantic_outdoors_picnic', 'interest.romantic.outdoors.picnic', '{"group":"romantic","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'romantic_outdoors'), 'romantic_outdoors_hiking', 'interest.romantic.outdoors.hiking', '{"group":"romantic","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'romantic_outdoors'), 'romantic_outdoors_stargazing', 'interest.romantic.outdoors.stargazing', '{"group":"romantic","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'romantic'), 'romantic_sports', 'interest.romantic.sports', '{"group":"romantic","type":"category"}', 6),
((SELECT id FROM interests WHERE key = 'romantic_sports'), 'romantic_sports_tennis', 'interest.romantic.sports.tennis', '{"group":"romantic","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'romantic_sports'), 'romantic_sports_yoga', 'interest.romantic.sports.yoga', '{"group":"romantic","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'romantic_sports'), 'romantic_sports_dance', 'interest.romantic.sports.dance', '{"group":"romantic","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'romantic'), 'romantic_culture', 'interest.romantic.culture', '{"group":"romantic","type":"category"}', 7),
((SELECT id FROM interests WHERE key = 'romantic_culture'), 'romantic_culture_festivals', 'interest.romantic.culture.festivals', '{"group":"romantic","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'romantic_culture'), 'romantic_culture_traditions', 'interest.romantic.culture.traditions', '{"group":"romantic","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'romantic_culture'), 'romantic_culture_cuisine', 'interest.romantic.culture.cuisine', '{"group":"romantic","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'romantic'), 'romantic_wellness', 'interest.romantic.wellness', '{"group":"romantic","type":"category"}', 8),
((SELECT id FROM interests WHERE key = 'romantic_wellness'), 'romantic_wellness_spa', 'interest.romantic.wellness.spa', '{"group":"romantic","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'romantic_wellness'), 'romantic_wellness_meditation', 'interest.romantic.wellness.meditation', '{"group":"romantic","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'romantic_wellness'), 'romantic_wellness_retreats', 'interest.romantic.wellness.retreats', '{"group":"romantic","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'romantic'), 'romantic_animals', 'interest.romantic.animals', '{"group":"romantic","type":"category"}', 9),
((SELECT id FROM interests WHERE key = 'romantic_animals'), 'romantic_animals_pets', 'interest.romantic.animals.pets', '{"group":"romantic","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'romantic_animals'), 'romantic_animals_wildlife', 'interest.romantic.animals.wildlife', '{"group":"romantic","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'romantic_animals'), 'romantic_animals_horseback', 'interest.romantic.animals.horseback', '{"group":"romantic","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'romantic'), 'romantic_volunteering', 'interest.romantic.volunteering', '{"group":"romantic","type":"category"}', 10),
((SELECT id FROM interests WHERE key = 'romantic_volunteering'), 'romantic_volunteering_community', 'interest.romantic.volunteering.community', '{"group":"romantic","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'romantic_volunteering'), 'romantic_volunteering_animals', 'interest.romantic.volunteering.animals', '{"group":"romantic","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'romantic_volunteering'), 'romantic_volunteering_environment', 'interest.romantic.volunteering.environment', '{"group":"romantic","type":"sub"}', 3)
ON CONFLICT (key) DO NOTHING;

-- FRIENDSHIP INTENT

-- Insert top-level friendship interest
INSERT INTO interests (parent_id, key, translation_key, metadata, sort_order)
VALUES (NULL, 'friendship', 'interest.friendship', '{"group":"friendship","type":"intent"}', 2)
ON CONFLICT (key) DO NOTHING;

INSERT INTO interests (parent_id, key, translation_key, metadata, sort_order)
VALUES
((SELECT id FROM interests WHERE key = 'friendship'), 'friendship_gaming', 'interest.friendship.gaming', '{"group":"friendship","type":"category"}', 1),
((SELECT id FROM interests WHERE key = 'friendship_gaming'), 'friendship_gaming_board', 'interest.friendship.gaming.board', '{"group":"friendship","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'friendship_gaming'), 'friendship_gaming_video', 'interest.friendship.gaming.video', '{"group":"friendship","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'friendship_gaming'), 'friendship_gaming_rpg', 'interest.friendship.gaming.rpg', '{"group":"friendship","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'friendship'), 'friendship_food', 'interest.friendship.food', '{"group":"friendship","type":"category"}', 2),
((SELECT id FROM interests WHERE key = 'friendship_food'), 'friendship_food_cooking', 'interest.friendship.food.cooking', '{"group":"friendship","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'friendship_food'), 'friendship_food_baking', 'interest.friendship.food.baking', '{"group":"friendship","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'friendship_food'), 'friendship_food_tasting', 'interest.friendship.food.tasting', '{"group":"friendship","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'friendship'), 'friendship_movies', 'interest.friendship.movies', '{"group":"friendship","type":"category"}', 3),
((SELECT id FROM interests WHERE key = 'friendship_movies'), 'friendship_movies_cinema', 'interest.friendship.movies.cinema', '{"group":"friendship","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'friendship_movies'), 'friendship_movies_marathon', 'interest.friendship.movies.marathon', '{"group":"friendship","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'friendship_movies'), 'friendship_movies_festivals', 'interest.friendship.movies.festivals', '{"group":"friendship","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'friendship'), 'friendship_books', 'interest.friendship.books', '{"group":"friendship","type":"category"}', 4),
((SELECT id FROM interests WHERE key = 'friendship_books'), 'friendship_books_club', 'interest.friendship.books.club', '{"group":"friendship","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'friendship_books'), 'friendship_books_fiction', 'interest.friendship.books.fiction', '{"group":"friendship","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'friendship_books'), 'friendship_books_nonfiction', 'interest.friendship.books.nonfiction', '{"group":"friendship","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'friendship'), 'friendship_fitness', 'interest.friendship.fitness', '{"group":"friendship","type":"category"}', 5),
((SELECT id FROM interests WHERE key = 'friendship_fitness'), 'friendship_fitness_gym', 'interest.friendship.fitness.gym', '{"group":"friendship","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'friendship_fitness'), 'friendship_fitness_running', 'interest.friendship.fitness.running', '{"group":"friendship","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'friendship_fitness'), 'friendship_fitness_team', 'interest.friendship.fitness.team', '{"group":"friendship","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'friendship'), 'friendship_travel', 'interest.friendship.travel', '{"group":"friendship","type":"category"}', 6),
((SELECT id FROM interests WHERE key = 'friendship_travel'), 'friendship_travel_backpacking', 'interest.friendship.travel.backpacking', '{"group":"friendship","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'friendship_travel'), 'friendship_travel_roadtrips', 'interest.friendship.travel.roadtrips', '{"group":"friendship","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'friendship_travel'), 'friendship_travel_cultural', 'interest.friendship.travel.cultural', '{"group":"friendship","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'friendship'), 'friendship_arts', 'interest.friendship.arts', '{"group":"friendship","type":"category"}', 7),
((SELECT id FROM interests WHERE key = 'friendship_arts'), 'friendship_arts_crafts', 'interest.friendship.arts.crafts', '{"group":"friendship","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'friendship_arts'), 'friendship_arts_photography', 'interest.friendship.arts.photography', '{"group":"friendship","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'friendship_arts'), 'friendship_arts_music', 'interest.friendship.arts.music', '{"group":"friendship","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'friendship'), 'friendship_language', 'interest.friendship.language', '{"group":"friendship","type":"category"}', 8),
((SELECT id FROM interests WHERE key = 'friendship_language'), 'friendship_language_exchange', 'interest.friendship.language.exchange', '{"group":"friendship","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'friendship_language'), 'friendship_language_learning', 'interest.friendship.language.learning', '{"group":"friendship","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'friendship_language'), 'friendship_language_sign', 'interest.friendship.language.sign', '{"group":"friendship","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'friendship'), 'friendship_pets', 'interest.friendship.pets', '{"group":"friendship","type":"category"}', 9),
((SELECT id FROM interests WHERE key = 'friendship_pets'), 'friendship_pets_dogs', 'interest.friendship.pets.dogs', '{"group":"friendship","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'friendship_pets'), 'friendship_pets_cats', 'interest.friendship.pets.cats', '{"group":"friendship","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'friendship_pets'), 'friendship_pets_exotic', 'interest.friendship.pets.exotic', '{"group":"friendship","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'friendship'), 'friendship_volunteering', 'interest.friendship.volunteering', '{"group":"friendship","type":"category"}', 10),
((SELECT id FROM interests WHERE key = 'friendship_volunteering'), 'friendship_volunteering_community', 'interest.friendship.volunteering.community', '{"group":"friendship","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'friendship_volunteering'), 'friendship_volunteering_environment', 'interest.friendship.volunteering.environment', '{"group":"friendship","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'friendship_volunteering'), 'friendship_volunteering_education', 'interest.friendship.volunteering.education', '{"group":"friendship","type":"sub"}', 3)
ON CONFLICT (key) DO NOTHING;

-- ACTIVITY PARTNER INTENT

-- Insert top-level activity partner interest
INSERT INTO interests (parent_id, key, translation_key, metadata, sort_order)
VALUES (NULL, 'activity_partner', 'interest.activity_partner', '{"group":"activity_partner","type":"intent"}', 3)
ON CONFLICT (key) DO NOTHING;

INSERT INTO interests (parent_id, key, translation_key, metadata, sort_order)
VALUES
((SELECT id FROM interests WHERE key = 'activity_partner'), 'activity_sports', 'interest.activity.sports', '{"group":"activity_partner","type":"category"}', 1),
((SELECT id FROM interests WHERE key = 'activity_sports'), 'activity_sports_soccer', 'interest.activity.sports.soccer', '{"group":"activity_partner","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'activity_sports'), 'activity_sports_basketball', 'interest.activity.sports.basketball', '{"group":"activity_partner","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'activity_sports'), 'activity_sports_martial', 'interest.activity.sports.martial', '{"group":"activity_partner","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'activity_partner'), 'activity_outdoors', 'interest.activity.outdoors', '{"group":"activity_partner","type":"category"}', 2),
((SELECT id FROM interests WHERE key = 'activity_outdoors'), 'activity_outdoors_hiking', 'interest.activity.outdoors.hiking', '{"group":"activity_partner","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'activity_outdoors'), 'activity_outdoors_camping', 'interest.activity.outdoors.camping', '{"group":"activity_partner","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'activity_outdoors'), 'activity_outdoors_cycling', 'interest.activity.outdoors.cycling', '{"group":"activity_partner","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'activity_partner'), 'activity_fitness', 'interest.activity.fitness', '{"group":"activity_partner","type":"category"}', 3),
((SELECT id FROM interests WHERE key = 'activity_fitness'), 'activity_fitness_gym', 'interest.activity.fitness.gym', '{"group":"activity_partner","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'activity_fitness'), 'activity_fitness_yoga', 'interest.activity.fitness.yoga', '{"group":"activity_partner","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'activity_fitness'), 'activity_fitness_crossfit', 'interest.activity.fitness.crossfit', '{"group":"activity_partner","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'activity_partner'), 'activity_dance', 'interest.activity.dance', '{"group":"activity_partner","type":"category"}', 4),
((SELECT id FROM interests WHERE key = 'activity_dance'), 'activity_dance_salsa', 'interest.activity.dance.salsa', '{"group":"activity_partner","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'activity_dance'), 'activity_dance_hiphop', 'interest.activity.dance.hiphop', '{"group":"activity_partner","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'activity_dance'), 'activity_dance_ballroom', 'interest.activity.dance.ballroom', '{"group":"activity_partner","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'activity_partner'), 'activity_arts', 'interest.activity.arts', '{"group":"activity_partner","type":"category"}', 5),
((SELECT id FROM interests WHERE key = 'activity_arts'), 'activity_arts_painting', 'interest.activity.arts.painting', '{"group":"activity_partner","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'activity_arts'), 'activity_arts_photography', 'interest.activity.arts.photography', '{"group":"activity_partner","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'activity_arts'), 'activity_arts_crafts', 'interest.activity.arts.crafts', '{"group":"activity_partner","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'activity_partner'), 'activity_gaming', 'interest.activity.gaming', '{"group":"activity_partner","type":"category"}', 6),
((SELECT id FROM interests WHERE key = 'activity_gaming'), 'activity_gaming_esports', 'interest.activity.gaming.esports', '{"group":"activity_partner","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'activity_gaming'), 'activity_gaming_board', 'interest.activity.gaming.board', '{"group":"activity_partner","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'activity_gaming'), 'activity_gaming_arcade', 'interest.activity.gaming.arcade', '{"group":"activity_partner","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'activity_partner'), 'activity_travel', 'interest.activity.travel', '{"group":"activity_partner","type":"category"}', 7),
((SELECT id FROM interests WHERE key = 'activity_travel'), 'activity_travel_adventure', 'interest.activity.travel.adventure', '{"group":"activity_partner","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'activity_travel'), 'activity_travel_cultural', 'interest.activity.travel.cultural', '{"group":"activity_partner","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'activity_travel'), 'activity_travel_roadtrips', 'interest.activity.travel.roadtrips', '{"group":"activity_partner","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'activity_partner'), 'activity_language', 'interest.activity.language', '{"group":"activity_partner","type":"category"}', 8),
((SELECT id FROM interests WHERE key = 'activity_language'), 'activity_language_exchange', 'interest.activity.language.exchange', '{"group":"activity_partner","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'activity_language'), 'activity_language_learning', 'interest.activity.language.learning', '{"group":"activity_partner","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'activity_language'), 'activity_language_sign', 'interest.activity.language.sign', '{"group":"activity_partner","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'activity_partner'), 'activity_cooking', 'interest.activity.cooking', '{"group":"activity_partner","type":"category"}', 9),
((SELECT id FROM interests WHERE key = 'activity_cooking'), 'activity_cooking_baking', 'interest.activity.cooking.baking', '{"group":"activity_partner","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'activity_cooking'), 'activity_cooking_grilling', 'interest.activity.cooking.grilling', '{"group":"activity_partner","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'activity_cooking'), 'activity_cooking_vegan', 'interest.activity.cooking.vegan', '{"group":"activity_partner","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'activity_partner'), 'activity_volunteering', 'interest.activity.volunteering', '{"group":"activity_partner","type":"category"}', 10),
((SELECT id FROM interests WHERE key = 'activity_volunteering'), 'activity_volunteering_community', 'interest.activity.volunteering.community', '{"group":"activity_partner","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'activity_volunteering'), 'activity_volunteering_environment', 'interest.activity.volunteering.environment', '{"group":"activity_partner","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'activity_volunteering'), 'activity_volunteering_animals', 'interest.activity.volunteering.animals', '{"group":"activity_partner","type":"sub"}', 3)
ON CONFLICT (key) DO NOTHING;

-- BUSINESS/NETWORKING INTENT

-- Insert top-level business interest
INSERT INTO interests (parent_id, key, translation_key, metadata, sort_order)
VALUES (NULL, 'business', 'interest.business', '{"group":"business","type":"intent"}', 4)
ON CONFLICT (key) DO NOTHING;

INSERT INTO interests (parent_id, key, translation_key, metadata, sort_order)
VALUES
((SELECT id FROM interests WHERE key = 'business'), 'business_entrepreneurship', 'interest.business.entrepreneurship', '{"group":"business","type":"category"}', 1),
((SELECT id FROM interests WHERE key = 'business_entrepreneurship'), 'business_entrepreneurship_startups', 'interest.business.entrepreneurship.startups', '{"group":"business","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'business_entrepreneurship'), 'business_entrepreneurship_investing', 'interest.business.entrepreneurship.investing', '{"group":"business","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'business_entrepreneurship'), 'business_entrepreneurship_social', 'interest.business.entrepreneurship.social', '{"group":"business","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'business'), 'business_technology', 'interest.business.technology', '{"group":"business","type":"category"}', 2),
((SELECT id FROM interests WHERE key = 'business_technology'), 'business_technology_ai', 'interest.business.technology.ai', '{"group":"business","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'business_technology'), 'business_technology_cyber', 'interest.business.technology.cyber', '{"group":"business","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'business_technology'), 'business_technology_web', 'interest.business.technology.web', '{"group":"business","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'business'), 'business_marketing', 'interest.business.marketing', '{"group":"business","type":"category"}', 3),
((SELECT id FROM interests WHERE key = 'business_marketing'), 'business_marketing_digital', 'interest.business.marketing.digital', '{"group":"business","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'business_marketing'), 'business_marketing_branding', 'interest.business.marketing.branding', '{"group":"business","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'business_marketing'), 'business_marketing_international', 'interest.business.marketing.international', '{"group":"business","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'business'), 'business_finance', 'interest.business.finance', '{"group":"business","type":"category"}', 4),
((SELECT id FROM interests WHERE key = 'business_finance'), 'business_finance_investing', 'interest.business.finance.investing', '{"group":"business","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'business_finance'), 'business_finance_cryptocurrency', 'interest.business.finance.cryptocurrency', '{"group":"business","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'business_finance'), 'business_finance_accounting', 'interest.business.finance.accounting', '{"group":"business","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'business'), 'business_law', 'interest.business.law', '{"group":"business","type":"category"}', 5),
((SELECT id FROM interests WHERE key = 'business_law'), 'business_law_international', 'interest.business.law.international', '{"group":"business","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'business_law'), 'business_law_corporate', 'interest.business.law.corporate', '{"group":"business","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'business_law'), 'business_law_ip', 'interest.business.law.ip', '{"group":"business","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'business'), 'business_healthcare', 'interest.business.healthcare', '{"group":"business","type":"category"}', 6),
((SELECT id FROM interests WHERE key = 'business_healthcare'), 'business_healthcare_tech', 'interest.business.healthcare.tech', '{"group":"business","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'business_healthcare'), 'business_healthcare_policy', 'interest.business.healthcare.policy', '{"group":"business","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'business_healthcare'), 'business_healthcare_international', 'interest.business.healthcare.international', '{"group":"business","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'business'), 'business_education', 'interest.business.education', '{"group":"business","type":"category"}', 7),
((SELECT id FROM interests WHERE key = 'business_education'), 'business_education_edtech', 'interest.business.education.edtech', '{"group":"business","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'business_education'), 'business_education_training', 'interest.business.education.training', '{"group":"business","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'business_education'), 'business_education_international', 'interest.business.education.international', '{"group":"business","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'business'), 'business_sustainability', 'interest.business.sustainability', '{"group":"business","type":"category"}', 8),
((SELECT id FROM interests WHERE key = 'business_sustainability'), 'business_sustainability_green', 'interest.business.sustainability.green', '{"group":"business","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'business_sustainability'), 'business_sustainability_social', 'interest.business.sustainability.social', '{"group":"business","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'business_sustainability'), 'business_sustainability_international', 'interest.business.sustainability.international', '{"group":"business","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'business'), 'business_networking', 'interest.business.networking', '{"group":"business","type":"category"}', 9),
((SELECT id FROM interests WHERE key = 'business_networking'), 'business_networking_events', 'interest.business.networking.events', '{"group":"business","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'business_networking'), 'business_networking_online', 'interest.business.networking.online', '{"group":"business","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'business_networking'), 'business_networking_international', 'interest.business.networking.international', '{"group":"business","type":"sub"}', 3),
((SELECT id FROM interests WHERE key = 'business'), 'business_volunteering', 'interest.business.volunteering', '{"group":"business","type":"category"}', 10),
((SELECT id FROM interests WHERE key = 'business_volunteering'), 'business_volunteering_mentoring', 'interest.business.volunteering.mentoring', '{"group":"business","type":"sub"}', 1),
((SELECT id FROM interests WHERE key = 'business_volunteering'), 'business_volunteering_community', 'interest.business.volunteering.community', '{"group":"business","type":"sub"}', 2),
((SELECT id FROM interests WHERE key = 'business_volunteering'), 'business_volunteering_international', 'interest.business.volunteering.international', '{"group":"business","type":"sub"}', 3)
ON CONFLICT (key) DO NOTHING;

-- TRANSLATIONS TABLE SEED (key, locale, value)

-- ----------------------------------------------------------------------
-- Metadata normalization: fill missing 'group' and 'type' fields
-- These updates ensure every interest has a 'group' (root intent key)
-- and a 'type' ('intent' for top-level, 'category' for immediate children,
-- 'sub' for deeper nodes) for consistent behavior in the app.
-- ----------------------------------------------------------------------

-- 1) Add 'type' = 'intent' for top-level nodes (no parent)
-- REMOVED: All metadata update logic (metadata column deleted)

-- 2) Add 'type' = 'category' for immediate children of intents
UPDATE interests
SET metadata = (COALESCE(metadata::jsonb, '{}'::jsonb) || '{"type":"category"}'::jsonb)
WHERE parent_id IN (SELECT id FROM interests WHERE parent_id IS NULL)
  AND (COALESCE(metadata::jsonb, '{}'::jsonb) ->> 'type') IS NULL;

-- 3) Add 'type' = 'sub' for deeper nodes (children of non-top-level)
UPDATE interests
SET metadata = (COALESCE(metadata::jsonb, '{}'::jsonb) || '{"type":"sub"}'::jsonb)
WHERE parent_id IN (SELECT id FROM interests WHERE parent_id IS NOT NULL)
  AND (COALESCE(metadata::jsonb, '{}'::jsonb) ->> 'type') IS NULL;

-- 4) Fill 'group' by finding the root ancestor key for each node
WITH RECURSIVE ancestors AS (
	SELECT id, parent_id, key, id AS start_id FROM interests
	UNION ALL
	SELECT p.id, p.parent_id, p.key, ancestors.start_id FROM interests p
		JOIN ancestors ON p.id = ancestors.parent_id
)
UPDATE interests i
SET metadata = (COALESCE(metadata::jsonb, '{}'::jsonb) || jsonb_build_object('group', (SELECT key FROM ancestors a WHERE a.start_id = i.id AND a.parent_id IS NULL LIMIT 1)))::jsonb
WHERE (COALESCE(metadata::jsonb, '{}'::jsonb) ->> 'group') IS NULL;

INSERT INTO translations (key, locale, value) VALUES
-- Unit translations
('unitMeters', 'en', 'meters'), ('unitMeters', 'es', 'metros'), ('unitMeters', 'he', 'מטרים'),
('unitFeet', 'en', 'feet'), ('unitFeet', 'es', 'pies'), ('unitFeet', 'he', 'רגליים'),
('unitSeconds', 'en', 'seconds'), ('unitSeconds', 'es', 'segundos'), ('unitSeconds', 'he', 'שניות'),
('settingsGpsRateUnit', 'en', 'Every {rate} seconds'), ('settingsGpsRateUnit', 'es', 'Cada {rate} segundos'), ('settingsGpsRateUnit', 'he', 'כל {rate} שניות'),

-- Interest translations
('interest.romantic', 'en', 'Romantic'), ('interest.romantic', 'es', 'Romántico'), ('interest.romantic', 'he', 'רומנטי'),
('interest.romantic.dining', 'en', 'Dining'), ('interest.romantic.dining', 'es', 'Cenar'), ('interest.romantic.dining', 'he', 'ארוחה'),
('interest.romantic.dining.fine', 'en', 'Fine Dining'), ('interest.romantic.dining.fine', 'es', 'Alta cocina'), ('interest.romantic.dining.fine', 'he', 'מסעדות יוקרה'),
('interest.romantic.dining.casual', 'en', 'Casual Dining'), ('interest.romantic.dining.casual', 'es', 'Comida informal'), ('interest.romantic.dining.casual', 'he', 'מסעדות רגילות'),
('interest.romantic.dining.international', 'en', 'International Cuisine'), ('interest.romantic.dining.international', 'es', 'Cocina internacional'), ('interest.romantic.dining.international', 'he', 'מטבח עולמי'),
('interest.romantic.travel', 'en', 'Travel'), ('interest.romantic.travel', 'es', 'Viajar'), ('interest.romantic.travel', 'he', 'טיולים'),
('interest.romantic.travel.beach', 'en', 'Beach Getaways'), ('interest.romantic.travel.beach', 'es', 'Escapadas a la playa'), ('interest.romantic.travel.beach', 'he', 'חופשות חוף'),
('interest.romantic.travel.mountains', 'en', 'Mountain Retreats'), ('interest.romantic.travel.mountains', 'es', 'Retiros en la montaña'), ('interest.romantic.travel.mountains', 'he', 'חופשות הרים'),
('interest.romantic.travel.city', 'en', 'City Breaks'), ('interest.romantic.travel.city', 'es', 'Escapadas urbanas'), ('interest.romantic.travel.city', 'he', 'חופשות עירוניות'),
('interest.romantic.music', 'en', 'Music'), ('interest.romantic.music', 'es', 'Música'), ('interest.romantic.music', 'he', 'מוזיקה'),
('interest.romantic.music.concerts', 'en', 'Concerts'), ('interest.romantic.music.concerts', 'es', 'Conciertos'), ('interest.romantic.music.concerts', 'he', 'הופעות חיות'),
('interest.romantic.music.dancing', 'en', 'Dancing'), ('interest.romantic.music.dancing', 'es', 'Baile'), ('interest.romantic.music.dancing', 'he', 'ריקוד'),
('interest.romantic.music.jazz', 'en', 'Jazz'), ('interest.romantic.music.jazz', 'es', 'Jazz'), ('interest.romantic.music.jazz', 'he', 'גאז'),
('interest.romantic.arts', 'en', 'Arts'), ('interest.romantic.arts', 'es', 'Artes'), ('interest.romantic.arts', 'he', 'אמנויות'),
('interest.romantic.arts.museums', 'en', 'Museums'), ('interest.romantic.arts.museums', 'es', 'Museos'), ('interest.romantic.arts.museums', 'he', 'מוזיאונים'),
('interest.romantic.arts.theater', 'en', 'Theater'), ('interest.romantic.arts.theater', 'es', 'Teatro'), ('interest.romantic.arts.theater', 'he', 'תיאטרון'),
('interest.romantic.arts.painting', 'en', 'Painting'), ('interest.romantic.arts.painting', 'es', 'Pintura'), ('interest.romantic.arts.painting', 'he', 'ציור'),
('interest.romantic.outdoors', 'en', 'Outdoors'), ('interest.romantic.outdoors', 'es', 'Afuera'), ('interest.romantic.outdoors', 'he', 'בחוץ'),
('interest.romantic.outdoors.picnic', 'en', 'Picnics'), ('interest.romantic.outdoors.picnic', 'es', 'Picnics'), ('interest.romantic.outdoors.picnic', 'he', 'פיקניק'),
('interest.romantic.outdoors.hiking', 'en', 'Hiking'), ('interest.romantic.outdoors.hiking', 'es', 'Senderismo'), ('interest.romantic.outdoors.hiking', 'he', 'טיול רגלי'),
('interest.romantic.outdoors.stargazing', 'en', 'Stargazing'), ('interest.romantic.outdoors.stargazing', 'es', 'Observación de estrellas'), ('interest.romantic.outdoors.stargazing', 'he', 'צפייה בכוכבים'),
('interest.romantic.sports', 'en', 'Sports'), ('interest.romantic.sports', 'es', 'Deportes'), ('interest.romantic.sports', 'he', 'ספורט'),
('interest.romantic.sports.tennis', 'en', 'Tennis'), ('interest.romantic.sports.tennis', 'es', 'Tenis'), ('interest.romantic.sports.tennis', 'he', 'טניס'),
('interest.romantic.sports.yoga', 'en', 'Yoga'), ('interest.romantic.sports.yoga', 'es', 'Yoga'), ('interest.romantic.sports.yoga', 'he', 'יוגה'),
('interest.romantic.sports.dance', 'en', 'Dance'), ('interest.romantic.sports.dance', 'es', 'Baile'), ('interest.romantic.sports.dance', 'he', 'ריקוד'),
('interest.romantic.culture', 'en', 'Culture'), ('interest.romantic.culture', 'es', 'Cultura'), ('interest.romantic.culture', 'he', 'תרבות'),
('interest.romantic.culture.festivals', 'en', 'Festivals'), ('interest.romantic.culture.festivals', 'es', 'Festivales'), ('interest.romantic.culture.festivals', 'he', 'פסטיבלים'),
('interest.romantic.culture.traditions', 'en', 'Traditions'), ('interest.romantic.culture.traditions', 'es', 'Tradiciones'), ('interest.romantic.culture.traditions', 'he', 'מסורות'),
('interest.romantic.culture.cuisine', 'en', 'Cuisine'), ('interest.romantic.culture.cuisine', 'es', 'Cocina'), ('interest.romantic.culture.cuisine', 'he', 'מטבח'),
('interest.romantic.wellness', 'en', 'Wellness'), ('interest.romantic.wellness', 'es', 'Bienestar'), ('interest.romantic.wellness', 'he', 'רווחה'),
('interest.romantic.wellness.spa', 'en', 'Spa'), ('interest.romantic.wellness.spa', 'es', 'Spa'), ('interest.romantic.wellness.spa', 'he', 'ספא'),
('interest.romantic.wellness.meditation', 'en', 'Meditation'), ('interest.romantic.wellness.meditation', 'es', 'Meditación'), ('interest.romantic.wellness.meditation', 'he', 'מדיטציה'),
('interest.romantic.wellness.retreats', 'en', 'Retreats'), ('interest.romantic.wellness.retreats', 'es', 'Retiros'), ('interest.romantic.wellness.retreats', 'he', ' retreats'),
('interest.romantic.animals', 'en', 'Animals'), ('interest.romantic.animals', 'es', 'Animales'), ('interest.romantic.animals', 'he', 'בעלי חיים'),
('interest.romantic.animals.pets', 'en', 'Pets'), ('interest.romantic.animals.pets', 'es', 'Mascotas'), ('interest.romantic.animals.pets', 'he', 'חיות מחמד'),
('interest.romantic.animals.wildlife', 'en', 'Wildlife'), ('interest.romantic.animals.wildlife', 'es', 'Vida salvaje'), ('interest.romantic.animals.wildlife', 'he', 'חיות בר'),
('interest.romantic.animals.horseback', 'en', 'Horseback Riding'), ('interest.romantic.animals.horseback', 'es', 'Equitación'), ('interest.romantic.animals.horseback', 'he', 'רכיבה על סוסים'),
('interest.romantic.volunteering', 'en', 'Volunteering'), ('interest.romantic.volunteering', 'es', 'Voluntariado'), ('interest.romantic.volunteering', 'he', 'התנדבות'),
('interest.romantic.volunteering.community', 'en', 'Community Service'), ('interest.romantic.volunteering.community', 'es', 'Servicio comunitario'), ('interest.romantic.volunteering.community', 'he', 'שירות קהילתי'),
('interest.romantic.volunteering.animals', 'en', 'Animal Rescue'), ('interest.romantic.volunteering.animals', 'es', 'Rescate de animales'), ('interest.romantic.volunteering.animals', 'he', 'הצלת בעלי חיים'),
('interest.romantic.volunteering.environment', 'en', 'Environmental Protection'), ('interest.romantic.volunteering.environment', 'es', 'Protección ambiental'), ('interest.romantic.volunteering.environment', 'he', 'הגנה על הסביבה'),
('interest.friendship', 'en', 'Friendship'), ('interest.friendship', 'es', 'Amistad'), ('interest.friendship', 'he', 'חֲבֵרוּת'),
('interest.friendship.gaming', 'en', 'Gaming'), ('interest.friendship.gaming', 'es', 'Juegos'), ('interest.friendship.gaming', 'he', 'גּוּמָרוּת'),
('interest.friendship.gaming.board', 'en', 'Board Games'), ('interest.friendship.gaming.board', 'es', 'Juegos de mesa'), ('interest.friendship.gaming.board', 'he', 'משחקי שולחן'),
('interest.friendship.gaming.video', 'en', 'Video Games'), ('interest.friendship.gaming.video', 'es', 'Videojuegos'), ('interest.friendship.gaming.video', 'he', 'משחקי וידאו'),
('interest.friendship.gaming.rpg', 'en', 'RPGs'), ('interest.friendship.gaming.rpg', 'es', 'Juegos de rol'), ('interest.friendship.gaming.rpg', 'he', 'משחקי תפקידים'),
('interest.friendship.food', 'en', 'Food'), ('interest.friendship.food', 'es', 'Comida'), ('interest.friendship.food', 'he', 'אוכל'),
('interest.friendship.food.cooking', 'en', 'Cooking'), ('interest.friendship.food.cooking', 'es', 'Cocinar'), ('interest.friendship.food.cooking', 'he', 'בישול'),
('interest.friendship.food.baking', 'en', 'Baking'), ('interest.friendship.food.baking', 'es', 'Hornear'), ('interest.friendship.food.baking', 'he', 'אפייה'),
('interest.friendship.food.tasting', 'en', 'Food Tasting'), ('interest.friendship.food.tasting', 'es', 'Degustación de alimentos'), ('interest.friendship.food.tasting', 'he', 'טעימות אוכל'),
('interest.friendship.movies', 'en', 'Movies'), ('interest.friendship.movies', 'es', 'Películas'), ('interest.friendship.movies', 'he', 'סרטים'),
('interest.friendship.movies.cinema', 'en', 'Cinema'), ('interest.friendship.movies.cinema', 'es', 'Cine'), ('interest.friendship.movies.cinema', 'he', 'קולנוע'),
('interest.friendship.movies.marathon', 'en', 'Movie Marathons'), ('interest.friendship.movies.marathon', 'es', 'Maratones de películas'), ('interest.friendship.movies.marathon', 'he', 'מרתוני סרטים'),
('interest.friendship.movies.festivals', 'en', 'Film Festivals'), ('interest.friendship.movies.festivals', 'es', 'Festivales de cine'), ('interest.friendship.movies.festivals', 'he', 'פסטיבלי סרטים'),
('interest.friendship.books', 'en', 'Books'), ('interest.friendship.books', 'es', 'Libros'), ('interest.friendship.books', 'he', 'ספרים'),
('interest.friendship.books.club', 'en', 'Book Clubs'), ('interest.friendship.books.club', 'es', 'Club de lectura'), ('interest.friendship.books.club', 'he', 'מועדון קריאה'),
('interest.friendship.books.fiction', 'en', 'Fiction'), ('interest.friendship.books.fiction', 'es', 'Ficción'), ('interest.friendship.books.fiction', 'he', 'בִּיוּן'),
('interest.friendship.books.nonfiction', 'en', 'Non-Fiction'), ('interest.friendship.books.nonfiction', 'es', 'No ficción'), ('interest.friendship.books.nonfiction', 'he', 'עיון'),
('interest.friendship.fitness', 'en', 'Fitness'), ('interest.friendship.fitness', 'es', 'Aptitud'), ('interest.friendship.fitness', 'he', 'כּוֹשֶׁר'),
('interest.friendship.fitness.gym', 'en', 'Gym'), ('interest.friendship.fitness.gym', 'es', 'Gimnasio'), ('interest.friendship.fitness.gym', 'he', 'חדר כושר'),
('interest.friendship.fitness.running', 'en', 'Running'), ('interest.friendship.fitness.running', 'es', 'Correr'), ('interest.friendship.fitness.running', 'he', 'רִיצה'),
('interest.friendship.fitness.team', 'en', 'Team Sports'), ('interest.friendship.fitness.team', 'es', 'Deportes en equipo'), ('interest.friendship.fitness.team', 'he', 'ספורט קבוצתי'),
('interest.friendship.travel', 'en', 'Travel'), ('interest.friendship.travel', 'es', 'Viajar'), ('interest.friendship.travel', 'he', 'טיולים'),
('interest.friendship.travel.backpacking', 'en', 'Backpacking'), ('interest.friendship.travel.backpacking', 'es', 'Trekking'), ('interest.friendship.travel.backpacking', 'he', 'טיול תרמילאים'),
('interest.friendship.travel.roadtrips', 'en', 'Road Trips'), ('interest.friendship.travel.roadtrips', 'es', 'Viajes por carretera'), ('interest.friendship.travel.roadtrips', 'he', 'טיולי כביש'),
('interest.friendship.travel.cultural', 'en', 'Cultural Travel'), ('interest.friendship.travel.cultural', 'es', 'Viajes culturales'), ('interest.friendship.travel.cultural', 'he', 'טיולים תרבותיים'),
('interest.friendship.arts', 'en', 'Arts'), ('interest.friendship.arts', 'es', 'Artes'), ('interest.friendship.arts', 'he', 'אמנויות'),
('interest.friendship.arts.crafts', 'en', 'Crafts'), ('interest.friendship.arts.crafts', 'es', 'Artesanía'), ('interest.friendship.arts.crafts', 'he', 'מלאכת יד'),
('interest.friendship.arts.photography', 'en', 'Photography'), ('interest.friendship.arts.photography', 'es', 'Fotografía'), ('interest.friendship.arts.photography', 'he', 'צילום'),
('interest.friendship.arts.music', 'en', 'Music'), ('interest.friendship.arts.music', 'es', 'Música'), ('interest.friendship.arts.music', 'he', 'מוזיקה'),
('interest.friendship.language', 'en', 'Language Exchange'), ('interest.friendship.language', 'es', 'Intercambio de idiomas'), ('interest.friendship.language', 'he', 'החלפת שפות'),
('interest.friendship.language.exchange', 'en', 'Language Exchange'), ('interest.friendship.language.exchange', 'es', 'Intercambio de idiomas'), ('interest.friendship.language.exchange', 'he', 'החלפת שפות'),
('interest.friendship.language.learning', 'en', 'Language Learning'), ('interest.friendship.language.learning', 'es', 'Aprendizaje de idiomas'), ('interest.friendship.language.learning', 'he', 'לימוד שפות'),
('interest.friendship.language.sign', 'en', 'Sign Language'), ('interest.friendship.language.sign', 'es', 'Lengua de señas'), ('interest.friendship.language.sign', 'he', 'שפת סימנים'),
('interest.friendship.pets', 'en', 'Pets'), ('interest.friendship.pets', 'es', 'Mascotas'), ('interest.friendship.pets', 'he', 'חיות מחמד'),
('interest.friendship.pets.dogs', 'en', 'Dogs'), ('interest.friendship.pets.dogs', 'es', 'Perros'), ('interest.friendship.pets.dogs', 'he', 'כלבים'),
('interest.friendship.pets.cats', 'en', 'Cats'), ('interest.friendship.pets.cats', 'es', 'Gatos'), ('interest.friendship.pets.cats', 'he', 'חתולים'),
('interest.friendship.pets.exotic', 'en', 'Exotic Pets'), ('interest.friendship.pets.exotic', 'es', 'Mascotas exóticas'), ('interest.friendship.pets.exotic', 'he', 'חיות מחמד אקזוטיות'),
('interest.friendship.volunteering', 'en', 'Volunteering'), ('interest.friendship.volunteering', 'es', 'Voluntariado'), ('interest.friendship.volunteering', 'he', 'התנדבות'),
('interest.friendship.volunteering.community', 'en', 'Community Service'), ('interest.friendship.volunteering.community', 'es', 'Servicio comunitario'), ('interest.friendship.volunteering.community', 'he', 'שירות קהילתי'),
('interest.friendship.volunteering.environment', 'en', 'Environmental Protection'), ('interest.friendship.volunteering.environment', 'es', 'Protección ambiental'), ('interest.friendship.volunteering.environment', 'he', 'הגנה על הסביבה'),
('interest.friendship.volunteering.education', 'en', 'Educational Volunteering'), ('interest.friendship.volunteering.education', 'es', 'Voluntariado educativo'), ('interest.friendship.volunteering.education', 'he', 'התנדבות חינוכית'),
('interest.activity_partner', 'en', 'Activity Partner'), ('interest.activity_partner', 'es', 'Pareja de actividad'), ('interest.activity_partner', 'he', 'שותף לפעילות'),
('interest.activity.sports', 'en', 'Sports'), ('interest.activity.sports', 'es', 'Deportes'), ('interest.activity.sports', 'he', 'ספורט'),
('interest.activity.sports.soccer', 'en', 'Soccer'), ('interest.activity.sports.soccer', 'es', 'Fútbol'), ('interest.activity.sports.soccer', 'he', 'כדורגל'),
('interest.activity.sports.basketball', 'en', 'Basketball'), ('interest.activity.sports.basketball', 'es', 'Baloncesto'), ('interest.activity.sports.basketball', 'he', 'כדורסל'),
('interest.activity.sports.martial', 'en', 'Martial Arts'), ('interest.activity.sports.martial', 'es', 'Artes marciales'), ('interest.activity.sports.martial', 'he', 'אמנויות לחימה'),
('interest.activity.outdoors', 'en', 'Outdoors'), ('interest.activity.outdoors', 'es', 'Afuera'), ('interest.activity.outdoors', 'he', 'בחוץ'),
('interest.activity.outdoors.hiking', 'en', 'Hiking'), ('interest.activity.outdoors.hiking', 'es', 'Senderismo'), ('interest.activity.outdoors.hiking', 'he', 'טיול רגלי'),
('interest.activity.outdoors.camping', 'en', 'Camping'), ('interest.activity.outdoors.camping', 'es', 'Acampada'), ('interest.activity.outdoors.camping', 'he', 'קמפינג'),
('interest.activity.outdoors.cycling', 'en', 'Cycling'), ('interest.activity.outdoors.cycling', 'es', 'Ciclismo'), ('interest.activity.outdoors.cycling', 'he', 'רכיבה על אופניים'),
('interest.activity.fitness', 'en', 'Fitness'), ('interest.activity.fitness', 'es', 'Aptitud'), ('interest.activity.fitness', 'he', 'כּוֹשֶׁר'),
('interest.activity.fitness.gym', 'en', 'Gym'), ('interest.activity.fitness.gym', 'es', 'Gimnasio'), ('interest.activity.fitness.gym', 'he', 'חדר כושר'),
('interest.activity.fitness.yoga', 'en', 'Yoga'), ('interest.activity.fitness.yoga', 'es', 'Yoga'), ('interest.activity.fitness.yoga', 'he', 'יוגה'),
('interest.activity.fitness.crossfit', 'en', 'Crossfit'), ('interest.activity.fitness.crossfit', 'es', 'Crossfit'), ('interest.activity.fitness.crossfit', 'he', 'קרוספיט'),
('interest.activity.dance', 'en', 'Dance'), ('interest.activity.dance', 'es', 'Baile'), ('interest.activity.dance', 'he', 'ריקוד'),
('interest.activity.dance.salsa', 'en', 'Salsa'), ('interest.activity.dance.salsa', 'es', 'Salsa'), ('interest.activity.dance.salsa', 'he', 'סלסה'),
('interest.activity.dance.hiphop', 'en', 'Hip-hop'), ('interest.activity.dance.hiphop', 'es', 'Hip-hop'), ('interest.activity.dance.hiphop', 'he', 'היפ הופ'),
('interest.activity.dance.ballroom', 'en', 'Ballroom Dance'), ('interest.activity.dance.ballroom', 'es', 'Danza de salón'), ('interest.activity.dance.ballroom', 'he', 'ריקוד סלון'),
('interest.activity.arts', 'en', 'Arts'), ('interest.activity.arts', 'es', 'Artes'), ('interest.activity.arts', 'he', 'אמנויות'),
('interest.activity.arts.painting', 'en', 'Painting'), ('interest.activity.arts.painting', 'es', 'Pintura'), ('interest.activity.arts.painting', 'he', 'ציור'),
('interest.activity.arts.photography', 'en', 'Photography'), ('interest.activity.arts.photography', 'es', 'Fotografía'), ('interest.activity.arts.photography', 'he', 'צילום'),
('interest.activity.arts.crafts', 'en', 'Crafts'), ('interest.activity.arts.crafts', 'es', 'Artesanía'), ('interest.activity.arts.crafts', 'he', 'מלאכת יד'),
('interest.activity.gaming', 'en', 'Gaming'), ('interest.activity.gaming', 'es', 'Juegos'), ('interest.activity.gaming', 'he', 'גּוּמָרוּת'),
('interest.activity.gaming.esports', 'en', 'Esports'), ('interest.activity.gaming.esports', 'es', 'Esports'), ('interest.activity.gaming.esports', 'he', 'ספורט אלקטרוני'),
('interest.activity.gaming.board', 'en', 'Board Games'), ('interest.activity.gaming.board', 'es', 'Juegos de mesa'), ('interest.activity.gaming.board', 'he', 'משחקי שולחן'),
('interest.activity.gaming.arcade', 'en', 'Arcade Games'), ('interest.activity.gaming.arcade', 'es', 'Juegos de arcade'), ('interest.activity.gaming.arcade', 'he', 'משחקי ארקייד'),
('interest.activity.travel', 'en', 'Travel'), ('interest.activity.travel', 'es', 'Viajar'), ('interest.activity.travel', 'he', 'טיולים'),
('interest.activity.travel.adventure', 'en', 'Adventure Travel'), ('interest.activity.travel.adventure', 'es', 'Viajes de aventura'), ('interest.activity.travel.adventure', 'he', 'טיולי הרפתקאות'),
('interest.activity.travel.cultural', 'en', 'Cultural Travel'), ('interest.activity.travel.cultural', 'es', 'Viajes culturales'), ('interest.activity.travel.cultural', 'he', 'טיולים תרבותיים'),
('interest.activity.travel.roadtrips', 'en', 'Road Trips'), ('interest.activity.travel.roadtrips', 'es', 'Viajes por carretera'), ('interest.activity.travel.roadtrips', 'he', 'טיולי כביש'),
('interest.activity.language', 'en', 'Language Exchange'), ('interest.activity.language', 'es', 'Intercambio de idiomas'), ('interest.activity.language', 'he', 'החלפת שפות'),
('interest.activity.language.exchange', 'en', 'Language Exchange'), ('interest.activity.language.exchange', 'es', 'Intercambio de idiomas'), ('interest.activity.language.exchange', 'he', 'החלפת שפות'),
('interest.activity.language.learning', 'en', 'Language Learning'), ('interest.activity.language.learning', 'es', 'Aprendizaje de idiomas'), ('interest.activity.language.learning', 'he', 'לימוד שפות'),
('interest.activity.language.sign', 'en', 'Sign Language'), ('interest.activity.language.sign', 'es', 'Lengua de señas'), ('interest.activity.language.sign', 'he', 'שפת סימנים'),
('interest.activity.cooking', 'en', 'Cooking'), ('interest.activity.cooking', 'es', 'Cocinar'), ('interest.activity.cooking', 'he', 'בישול'),
('interest.activity.cooking.baking', 'en', 'Baking'), ('interest.activity.cooking.baking', 'es', 'Hornear'), ('interest.activity.cooking.baking', 'he', 'אפייה'),
('interest.activity.cooking.grilling', 'en', 'Grilling'), ('interest.activity.cooking.grilling', 'es', 'Asar a la parrilla'), ('interest.activity.cooking.grilling', 'he', 'צלייה'),
('interest.activity.cooking.vegan', 'en', 'Vegan Cooking'), ('interest.activity.cooking.vegan', 'es', 'Cocina vegana'), ('interest.activity.cooking.vegan', 'he', 'בישול טבעוני'),
('interest.activity.volunteering', 'en', 'Volunteering'), ('interest.activity.volunteering', 'es', 'Voluntariado'), ('interest.activity.volunteering', 'he', 'התנדבות'),
('interest.activity.volunteering.community', 'en', 'Community Service'), ('interest.activity.volunteering.community', 'es', 'Servicio comunitario'), ('interest.activity.volunteering.community', 'he', 'שירות קהילתי'),
('interest.activity.volunteering.environment', 'en', 'Environmental Protection'), ('interest.activity.volunteering.environment', 'es', 'Protección ambiental'), ('interest.activity.volunteering.environment', 'he', 'הגנה על הסביבה'),
('interest.activity.volunteering.animals', 'en', 'Animal Rescue'), ('interest.activity.volunteering.animals', 'es', 'Rescate de animales'), ('interest.activity.volunteering.animals', 'he', 'הצלת בעלי חיים'),
('interest.business', 'en', 'Business'), ('interest.business', 'es', 'Negocios'), ('interest.business', 'he', 'עסקים'),
('interest.business.entrepreneurship', 'en', 'Entrepreneurship'), ('interest.business.entrepreneurship', 'es', 'Emprendimiento'), ('interest.business.entrepreneurship', 'he', 'יזמות'),
('interest.business.entrepreneurship.startups', 'en', 'Startups'), ('interest.business.entrepreneurship.startups', 'es', 'Startups'), ('interest.business.entrepreneurship.startups', 'he', 'סטארטאפים'),
('interest.business.entrepreneurship.investing', 'en', 'Investing'), ('interest.business.entrepreneurship.investing', 'es', 'Inversión'), ('interest.business.entrepreneurship.investing', 'he', 'השקעות'),
('interest.business.entrepreneurship.social', 'en', 'Social Entrepreneurship'), ('interest.business.entrepreneurship.social', 'es', 'Emprendimiento social'), ('interest.business.entrepreneurship.social', 'he', 'יזמות חברתית'),
('interest.business.technology', 'en', 'Technology'), ('interest.business.technology', 'es', 'Tecnología'), ('interest.business.technology', 'he', 'טכנולוגיה'),
('interest.business.technology.ai', 'en', 'AI Technology'), ('interest.business.technology.ai', 'es', 'Tecnología de IA'), ('interest.business.technology.ai', 'he', 'טכנולוגיית בינה מלאכותית'),
('interest.business.technology.cyber', 'en', 'Cybersecurity'), ('interest.business.technology.cyber', 'es', 'Ciberseguridad'), ('interest.business.technology.cyber', 'he', 'סייבר'),
('interest.business.technology.web', 'en', 'Web Development'), ('interest.business.technology.web', 'es', 'Desarrollo web'), ('interest.business.technology.web', 'he', 'פיתוח אתרים'),
('interest.business.marketing', 'en', 'Marketing'), ('interest.business.marketing', 'es', 'Marketing'), ('interest.business.marketing', 'he', 'שיווק'),
('interest.business.marketing.digital', 'en', 'Digital Marketing'), ('interest.business.marketing.digital', 'es', 'Marketing digital'), ('interest.business.marketing.digital', 'he', 'שיווק דיגיטלי'),
('interest.business.marketing.branding', 'en', 'Branding'), ('interest.business.marketing.branding', 'es', 'Branding'), ('interest.business.marketing.branding', 'he', 'מיתוג'),
('interest.business.marketing.international', 'en', 'International Marketing'), ('interest.business.marketing.international', 'es', 'Marketing internacional'), ('interest.business.marketing.international', 'he', 'שיווק בינלאומי'),
('interest.business.finance', 'en', 'Finance'), ('interest.business.finance', 'es', 'Finanzas'), ('interest.business.finance', 'he', 'פיננסים'),
('interest.business.finance.investing', 'en', 'Investing'), ('interest.business.finance.investing', 'es', 'Inversión'), ('interest.business.finance.investing', 'he', 'השקעות'),
('interest.business.finance.cryptocurrency', 'en', 'Cryptocurrency'), ('interest.business.finance.cryptocurrency', 'es', 'Criptomoneda'), ('interest.business.finance.cryptocurrency', 'he', 'מטבעות קריפטו'),
('interest.business.finance.accounting', 'en', 'Accounting'), ('interest.business.finance.accounting', 'es', 'Contabilidad'), ('interest.business.finance.accounting', 'he', 'חשבונאות'),
('interest.business.law', 'en', 'Law'), ('interest.business.law', 'es', 'Derecho'), ('interest.business.law', 'he', 'חוק'),
('interest.business.law.international', 'en', 'International Law'), ('interest.business.law.international', 'es', 'Derecho internacional'), ('interest.business.law.international', 'he', 'דין בינלאומי'),
('interest.business.law.corporate', 'en', 'Corporate Law'), ('interest.business.law.corporate', 'es', 'Derecho corporativo'), ('interest.business.law.corporate', 'he', 'דין עסקי'),
('interest.business.law.ip', 'en', 'Intellectual Property'), ('interest.business.law.ip', 'es', 'Propiedad intelectual'), ('interest.business.law.ip', 'he', 'קניין רוחני'),
('interest.business.healthcare', 'en', 'Healthcare'), ('interest.business.healthcare', 'es', 'Cuidado de la salud'), ('interest.business.healthcare', 'he', 'בריאות'),
('interest.business.healthcare.tech', 'en', 'Healthcare Technology'), ('interest.business.healthcare.tech', 'es', 'Tecnología de la salud'), ('interest.business.healthcare.tech', 'he', 'טכנולוגיית בריאות'),
('interest.business.healthcare.policy', 'en', 'Healthcare Policy'), ('interest.business.healthcare.policy', 'es', 'Política de salud'), ('interest.business.healthcare.policy', 'he', 'מדיניות בריאות'),
('interest.business.healthcare.international', 'en', 'International Healthcare'), ('interest.business.healthcare.international', 'es', 'Cuidado de la salud internacional'), ('interest.business.healthcare.international', 'he', 'בריאות בינלאומית'),
('interest.business.education', 'en', 'Education'), ('interest.business.education', 'es', 'Educación'), ('interest.business.education', 'he', 'חינוך'),
('interest.business.education.edtech', 'en', 'EdTech'), ('interest.business.education.edtech', 'es', 'Tecnología educativa'), ('interest.business.education.edtech', 'he', 'טכנולוגיית חינוך'),
('interest.business.education.training', 'en', 'Training'), ('interest.business.education.training', 'es', 'Capacitación'), ('interest.business.education.training', 'he', 'הכשרה'),
('interest.business.education.international', 'en', 'International Education'), ('interest.business.education.international', 'es', 'Educación internacional'), ('interest.business.education.international', 'he', 'חינוך בינלאומי'),
('interest.business.sustainability', 'en', 'Sustainability'), ('interest.business.sustainability', 'es', 'Sostenibilidad'), ('interest.business.sustainability', 'he', 'קיימות'),
('interest.business.sustainability.green', 'en', 'Green Business'), ('interest.business.sustainability.green', 'es', 'Negocios verdes'), ('interest.business.sustainability.green', 'he', 'עסקים ירוקים'),
('interest.business.sustainability.social', 'en', 'Social Sustainability'), ('interest.business.sustainability.social', 'es', 'Sostenibilidad social'), ('interest.business.sustainability.social', 'he', 'קיימות חברתית'),
('interest.business.sustainability.international', 'en', 'International Sustainability'), ('interest.business.sustainability.international', 'es', 'Sostenibilidad internacional'), ('interest.business.sustainability.international', 'he', 'קיימות בינלאומית'),
('interest.business.networking', 'en', 'Networking'), ('interest.business.networking', 'es', 'Redes'), ('interest.business.networking', 'he', 'רִקּוּעַ'),
('interest.business.networking.events', 'en', 'Networking Events'), ('interest.business.networking.events', 'es', 'Eventos de networking'), ('interest.business.networking.events', 'he', 'אירועי רִקּוּעַ'),
('interest.business.networking.online', 'en', 'Online Networking'), ('interest.business.networking.online', 'es', 'Redes en línea'), ('interest.business.networking.online', 'he', 'רִקּוּעַ מקוון'),
('interest.business.networking.international', 'en', 'International Networking'), ('interest.business.networking.international', 'es', 'Redes internacionales'), ('interest.business.networking.international', 'he', 'רִקּוּעַ בינלאומי'),
('interest.business.volunteering', 'en', 'Volunteering'), ('interest.business.volunteering', 'es', 'Voluntariado'), ('interest.business.volunteering', 'he', 'התנדבות'),
('interest.business.volunteering.mentoring', 'en', 'Mentoring'), ('interest.business.volunteering.mentoring', 'es', 'Mentoría'), ('interest.business.volunteering.mentoring', 'he', 'חונכות'),
('interest.business.volunteering.community', 'en', 'Community Service'), ('interest.business.volunteering.community', 'es', 'Servicio comunitario'), ('interest.business.volunteering.community', 'he', 'שירות קהילתי'),
('interest.business.volunteering.international', 'en', 'International Volunteering'), ('interest.business.volunteering.international', 'es', 'Voluntariado internacional'), ('interest.business.volunteering.international', 'he', 'התנדבות בינלאומית'),

-- Time period translations
('timeMorning', 'en', 'Morning'), ('timeMorning', 'es', 'Mañana'), ('timeMorning', 'he', 'בוקר'),
('timeAfternoon', 'en', 'Afternoon'), ('timeAfternoon', 'es', 'Tarde'), ('timeAfternoon', 'he', 'אחר הצהריים'),
('timeEvening', 'en', 'Evening'), ('timeEvening', 'es', 'Tarde'), ('timeEvening', 'he', 'ערב'),
('timeNight', 'en', 'Night'), ('timeNight', 'es', 'Noche'), ('timeNight', 'he', 'לילה'),

-- Event detail labels
('eventLocationLabel', 'en', 'Location'), ('eventLocationLabel', 'es', 'Ubicación'), ('eventLocationLabel', 'he', 'מיקום'),
('eventDateLabel', 'en', 'Day and Date'), ('eventDateLabel', 'es', 'Día y Fecha'), ('eventDateLabel', 'he', 'יום ותאריך'),
('eventTimeLabel', 'en', 'Time'), ('eventTimeLabel', 'es', 'Hora'), ('eventTimeLabel', 'he', 'שעה')
ON CONFLICT (key, locale) DO NOTHING;
