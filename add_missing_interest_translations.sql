-- Missing interest/hobby translations for English, Spanish, and Hebrew
-- These keys exist in the code defaults but were missing from the DB translations table

-- English
INSERT INTO translations (locale, key, value) VALUES ('en', 'saas', 'SaaS') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'fintech', 'Fintech') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'arts_and_crafts', 'Arts & Crafts') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'ashtanga', 'Ashtanga') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'bachata', 'Bachata') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'baking', 'Baking') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'consulting', 'Consulting') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'cooking', 'Cooking') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'crossfit', 'Crossfit') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'entrepreneurship', 'Entrepreneurship') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'entrepreneurship_cat', 'Entrepreneurship') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'jewelry_making', 'Jewelry Making') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'technology', 'Technology') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'technology_cat', 'Technology') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'tech_meetups', 'Tech Meetups') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'coding_bootcamps', 'Coding Bootcamps') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'yoga', 'Yoga') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'amusement_park', 'Amusement Park') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'business_events', 'Business Events') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('en', 'conferences', 'Conferences') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Spanish
INSERT INTO translations (locale, key, value) VALUES ('es', 'saas', 'SaaS') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'fintech', 'Fintech') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'arts_and_crafts', 'Artes y manualidades') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'ashtanga', 'Ashtanga') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'bachata', 'Bachata') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'baking', 'Hornear') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'consulting', 'Consultoría') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'cooking', 'Cocinar') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'crossfit', 'Crossfit') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'entrepreneurship', 'Emprendimiento') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'entrepreneurship_cat', 'Emprendimiento') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'jewelry_making', 'Fabricación de joyas') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'technology', 'Tecnología') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'technology_cat', 'Tecnología') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'tech_meetups', 'Encuentros tecnológicos') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'coding_bootcamps', 'Bootcamps de programación') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'yoga', 'Yoga') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'amusement_park', 'Parque de diversiones') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'business_events', 'Eventos de negocios') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('es', 'conferences', 'Conferencias') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

-- Hebrew
INSERT INTO translations (locale, key, value) VALUES ('he', 'saas', 'SaaS') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'fintech', 'פינטק') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'arts_and_crafts', 'אומנות ויצירה') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'ashtanga', 'אשטנגה') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'bachata', 'באצ׳טה') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'baking', 'אפייה') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'consulting', 'ייעוץ') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'cooking', 'בישול') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'crossfit', 'קרוספיט') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'entrepreneurship', 'יזמות') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'entrepreneurship_cat', 'יזמות') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'jewelry_making', 'צורפות ותכשיטנות') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'technology', 'טכנולוגיה') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'technology_cat', 'טכנולוגיה') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'tech_meetups', 'מפגשי טכנולוגיה') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'coding_bootcamps', 'בוטקאמפים לתכנות') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'yoga', 'יוגה') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'amusement_park', 'פארק שעשועים') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'business_events', 'אירועים עסקיים') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO translations (locale, key, value) VALUES ('he', 'conferences', 'כנסים') ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
