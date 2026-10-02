-- Add translations for profile wizard validation messages
-- Keys: profileWizardSubIntentMin, profileWizardSubIntentMax, profileWizardInterestMin,
--        profileWizardInterestMaxPerCategory, profileWizardInterestMaxCategoriesSocial,
--        profileWizardInterestMaxCategoriesBusiness, profileWizardCategorySubInterestExceeded,
--        profileSelectAtLeastOneInterest

INSERT INTO public.translations (key, locale, value) VALUES

-- Sub-intent minimum
('profileWizardSubIntentMin', 'en', '{intent} requires at least {min} sub-intent'),
('profileWizardSubIntentMin', 'es', '{intent} requiere al menos {min} sub-intención'),
('profileWizardSubIntentMin', 'he', '{intent} דורש לפחות {min} תת-כוונה'),

-- Sub-intent maximum
('profileWizardSubIntentMax', 'en', '{intent} allows at most {max} sub-intents'),
('profileWizardSubIntentMax', 'es', '{intent} permite como máximo {max} sub-intenciones'),
('profileWizardSubIntentMax', 'he', '{intent} מאפשר לכל היותר {max} תת-כוונות'),

-- Interest minimum
('profileWizardInterestMin', 'en', '{intent} requires at least {min} interest'),
('profileWizardInterestMin', 'es', '{intent} requiere al menos {min} interés'),
('profileWizardInterestMin', 'he', '{intent} דורש לפחות {min} תחום עניין'),

-- Max sub-interests per category
('profileWizardInterestMaxPerCategory', 'en', 'Maximum {max} sub-interests per category'),
('profileWizardInterestMaxPerCategory', 'es', 'Máximo {max} sub-intereses por categoría'),
('profileWizardInterestMaxPerCategory', 'he', 'מקסימום {max} תת-תחומי עניין לקטגוריה'),

-- Max social interest categories
('profileWizardInterestMaxCategoriesSocial', 'en', 'You can select up to {limit} social interests.'),
('profileWizardInterestMaxCategoriesSocial', 'es', 'Puedes seleccionar hasta {limit} intereses sociales.'),
('profileWizardInterestMaxCategoriesSocial', 'he', 'ניתן לבחור עד {limit} תחומי עניין חברתיים.'),

-- Max business interest categories
('profileWizardInterestMaxCategoriesBusiness', 'en', 'You can select up to {limit} business/networking interests.'),
('profileWizardInterestMaxCategoriesBusiness', 'es', 'Puedes seleccionar hasta {limit} intereses de negocios/networking.'),
('profileWizardInterestMaxCategoriesBusiness', 'he', 'ניתן לבחור עד {limit} תחומי עניין עסקיים/נטוורקינג.'),

-- Category exceeded max sub-interests
('profileWizardCategorySubInterestExceeded', 'en', 'Category "{category}" exceeds maximum {max} sub-interests'),
('profileWizardCategorySubInterestExceeded', 'es', 'La categoría "{category}" supera el máximo de {max} sub-intereses'),
('profileWizardCategorySubInterestExceeded', 'he', 'הקטגוריה "{category}" חורגת מהמקסימום {max} תת-תחומי עניין'),

-- Also add the missing interest selection key
('profileSelectAtLeastOneInterest', 'en', 'Please select at least one interest'),
('profileSelectAtLeastOneInterest', 'es', 'Por favor selecciona al menos un interés'),
('profileSelectAtLeastOneInterest', 'he', 'אנא בחר לפחות תחום עניין אחד')

ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;
