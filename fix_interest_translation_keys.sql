-- Fix interest translation_key values where the key equals the raw key
-- (e.g. 'saas') instead of the proper prefixed form (e.g. 'interest.saas').
-- This ensures the app looks up the correct translation key.

BEGIN;

UPDATE public.interests SET translation_key = 'interest.saas'
WHERE key = 'saas' AND translation_key != 'interest.saas';

UPDATE public.interests SET translation_key = 'interest.fintech'
WHERE key = 'fintech' AND translation_key != 'interest.fintech';

UPDATE public.interests SET translation_key = 'interest.tech_meetups'
WHERE key = 'tech_meetups' AND translation_key != 'interest.tech_meetups';

UPDATE public.interests SET translation_key = 'interest.coding_bootcamps'
WHERE key = 'coding_bootcamps' AND translation_key != 'interest.coding_bootcamps';

UPDATE public.interests SET translation_key = 'interest.open_source'
WHERE key = 'open_source' AND translation_key != 'interest.open_source';

UPDATE public.interests SET translation_key = 'interest.biotech'
WHERE key = 'biotech' AND translation_key != 'interest.biotech';

UPDATE public.interests SET translation_key = 'interest.cleantech'
WHERE key = 'cleantech' AND translation_key != 'interest.cleantech';

UPDATE public.interests SET translation_key = 'interest.seed_stage'
WHERE key = 'seed_stage' AND translation_key != 'interest.seed_stage';

UPDATE public.interests SET translation_key = 'interest.growth_equity'
WHERE key = 'growth_equity' AND translation_key != 'interest.growth_equity';

UPDATE public.interests SET translation_key = 'interest.angel_investing'
WHERE key = 'angel_investing' AND translation_key != 'interest.angel_investing';

UPDATE public.interests SET translation_key = 'interest.personal_finance'
WHERE key = 'personal_finance' AND translation_key != 'interest.personal_finance';

UPDATE public.interests SET translation_key = 'interest.investing'
WHERE key = 'investing' AND translation_key != 'interest.investing';

UPDATE public.interests SET translation_key = 'interest.stock_trading'
WHERE key = 'stock_trading' AND translation_key != 'interest.stock_trading';

UPDATE public.interests SET translation_key = 'interest.digital_marketing'
WHERE key = 'digital_marketing' AND translation_key != 'interest.digital_marketing';

UPDATE public.interests SET translation_key = 'interest.content_creation'
WHERE key = 'content_creation' AND translation_key != 'interest.content_creation';

UPDATE public.interests SET translation_key = 'interest.brand_strategy'
WHERE key = 'brand_strategy' AND translation_key != 'interest.brand_strategy';

UPDATE public.interests SET translation_key = 'interest.growth_hacking'
WHERE key = 'growth_hacking' AND translation_key != 'interest.growth_hacking';

-- Technology category
UPDATE public.interests SET translation_key = 'interest_category.technology'
WHERE key = 'technology_cat' AND translation_key != 'interest_category.technology';

-- Entrepreneurship category
UPDATE public.interests SET translation_key = 'interest_category.entrepreneurship'
WHERE key = 'entrepreneurship_cat' AND translation_key != 'interest_category.entrepreneurship';

-- Consulting category
UPDATE public.interests SET translation_key = 'interest_category.consulting'
WHERE key = 'consulting_cat' AND translation_key != 'interest_category.consulting';

-- Arts & Crafts category
UPDATE public.interests SET translation_key = 'interest_category.arts_and_crafts'
WHERE key = 'arts_and_crafts' AND translation_key != 'interest_category.arts_and_crafts';

-- Top-level specific interests
UPDATE public.interests SET translation_key = 'interest.cooking'
WHERE key = 'cooking' AND translation_key != 'interest.cooking';

UPDATE public.interests SET translation_key = 'interest.yoga'
WHERE key = 'yoga' AND translation_key != 'interest.yoga';

UPDATE public.interests SET translation_key = 'interest.consulting'
WHERE key = 'consulting' AND translation_key != 'interest.consulting';

UPDATE public.interests SET translation_key = 'interest.entrepreneurship'
WHERE key = 'entrepreneurship' AND translation_key != 'interest.entrepreneurship';

UPDATE public.interests SET translation_key = 'interest.technology'
WHERE key = 'technology' AND translation_key != 'interest.technology';

UPDATE public.interests SET translation_key = 'interest.crossfit'
WHERE key = 'crossfit' AND translation_key != 'interest.crossfit';

UPDATE public.interests SET translation_key = 'interest.jewelry_making'
WHERE key = 'jewelry_making' AND translation_key != 'interest.jewelry_making';

-- Sub-interests
UPDATE public.interests SET translation_key = 'interest.dancing.bachata'
WHERE key = 'bachata' AND translation_key != 'interest.dancing.bachata';

UPDATE public.interests SET translation_key = 'interest.cooking.baking'
WHERE key = 'baking' AND translation_key != 'interest.cooking.baking';

UPDATE public.interests SET translation_key = 'interest.yoga.ashtanga'
WHERE key = 'ashtanga' AND translation_key != 'interest.yoga.ashtanga';

UPDATE public.interests SET translation_key = 'interest.amusement_park'
WHERE key = 'amusement_park' AND translation_key != 'interest.amusement_park';

UPDATE public.interests SET translation_key = 'interest.conferences'
WHERE key = 'conferences' AND translation_key != 'interest.conferences';

UPDATE public.interests SET translation_key = 'interest.business_events'
WHERE key = 'business_events' AND translation_key != 'interest.business_events';

-- Ensure missing translations exist for all locales
INSERT INTO public.translations (key, locale, value) VALUES
  ('interest.saas', 'en', 'SaaS'),
  ('interest.saas', 'es', 'SaaS'),
  ('interest.saas', 'he', 'SaaS'),
  ('interest.fintech', 'en', 'Fintech'),
  ('interest.fintech', 'es', 'Fintech'),
  ('interest.fintech', 'he', 'פינטק'),
  ('interest.tech_meetups', 'en', 'Tech Meetups'),
  ('interest.tech_meetups', 'es', 'Encuentros Tecnológicos'),
  ('interest.tech_meetups', 'he', 'מפגשי טכנולוגיה'),
  ('interest.coding_bootcamps', 'en', 'Coding Bootcamps'),
  ('interest.coding_bootcamps', 'es', 'Bootcamps de Programación'),
  ('interest.coding_bootcamps', 'he', 'בוטקאמפים לקידוד'),
  ('interest.open_source', 'en', 'Open Source'),
  ('interest.open_source', 'es', 'Código Abierto'),
  ('interest.open_source', 'he', 'קוד פתוח'),
  ('interest.biotech', 'en', 'Biotech'),
  ('interest.biotech', 'es', 'Biotecnología'),
  ('interest.biotech', 'he', 'ביוטק'),
  ('interest.cleantech', 'en', 'Cleantech'),
  ('interest.cleantech', 'es', 'Tecnología Limpia'),
  ('interest.cleantech', 'he', 'קלינטק'),
  ('interest.seed_stage', 'en', 'Seed Stage'),
  ('interest.growth_equity', 'en', 'Growth Equity'),
  ('interest.angel_investing', 'en', 'Angel Investing'),
  ('interest.personal_finance', 'en', 'Personal Finance'),
  ('interest.investing', 'en', 'Investing'),
  ('interest.stock_trading', 'en', 'Stock Trading'),
  ('interest.digital_marketing', 'en', 'Digital Marketing'),
  ('interest.content_creation', 'en', 'Content Creation'),
  ('interest.brand_strategy', 'en', 'Brand Strategy'),
  ('interest.growth_hacking', 'en', 'Growth Hacking'),
  ('interest_category.technology', 'en', 'Technology'),
  ('interest_category.technology', 'es', 'Tecnología'),
  ('interest_category.technology', 'he', 'טכנולוגיה'),
  ('interest_category.entrepreneurship', 'en', 'Entrepreneurship'),
  ('interest_category.entrepreneurship', 'es', 'Emprendimiento'),
  ('interest_category.entrepreneurship', 'he', 'יזמות'),
  ('interest_category.consulting', 'en', 'Consulting'),
  ('interest_category.consulting', 'es', 'Consultoría'),
  ('interest_category.consulting', 'he', 'ייעוץ'),
  ('interest_category.arts_and_crafts', 'en', 'Arts & Crafts'),
  ('interest_category.arts_and_crafts', 'es', 'Artes y Manualidades'),
  ('interest_category.arts_and_crafts', 'he', 'אומנויות ומלאכה'),
  ('interest.cooking', 'en', 'Cooking'),
  ('interest.cooking', 'es', 'Cocina'),
  ('interest.cooking', 'he', 'בישול'),
  ('interest.yoga', 'en', 'Yoga'),
  ('interest.yoga', 'es', 'Yoga'),
  ('interest.yoga', 'he', 'יוגה'),
  ('interest.consulting', 'en', 'Consulting'),
  ('interest.consulting', 'es', 'Consultoría'),
  ('interest.consulting', 'he', 'ייעוץ'),
  ('interest.entrepreneurship', 'en', 'Entrepreneurship'),
  ('interest.entrepreneurship', 'es', 'Emprendimiento'),
  ('interest.entrepreneurship', 'he', 'יזמות'),
  ('interest.technology', 'en', 'Technology'),
  ('interest.technology', 'es', 'Tecnología'),
  ('interest.technology', 'he', 'טכנולוגיה'),
  ('interest.crossfit', 'en', 'Crossfit'),
  ('interest.crossfit', 'es', 'Crossfit'),
  ('interest.crossfit', 'he', 'קרוספיט'),
  ('interest.jewelry_making', 'en', 'Jewelry Making'),
  ('interest.jewelry_making', 'es', 'Fabricación de Joyas'),
  ('interest.jewelry_making', 'he', 'ייצור תכשיטים'),
  ('interest.dancing.bachata', 'en', 'Bachata'),
  ('interest.dancing.bachata', 'es', 'Bachata'),
  ('interest.dancing.bachata', 'he', 'באצ׳טה'),
  ('interest.cooking.baking', 'en', 'Baking'),
  ('interest.cooking.baking', 'es', 'Hornear'),
  ('interest.cooking.baking', 'he', 'אפייה'),
  ('interest.yoga.ashtanga', 'en', 'Ashtanga'),
  ('interest.yoga.ashtanga', 'es', 'Ashtanga'),
  ('interest.yoga.ashtanga', 'he', 'אשטנגה'),
  ('interest.amusement_park', 'en', 'Amusement Park'),
  ('interest.amusement_park', 'es', 'Parque de Diversiones'),
  ('interest.amusement_park', 'he', 'פארק שעשועים'),
  ('interest.conferences', 'en', 'Conferences'),
  ('interest.conferences', 'es', 'Conferencias'),
  ('interest.conferences', 'he', 'כנסים'),
  ('interest.business_events', 'en', 'Business Events'),
  ('interest.business_events', 'es', 'Eventos de Negocios'),
  ('interest.business_events', 'he', 'אירועים עסקיים')
ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
