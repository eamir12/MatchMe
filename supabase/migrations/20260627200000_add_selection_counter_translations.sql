-- Add translations for selection counters and min/max hints
-- Keys: profileSelectSubIntentsMinMax, profileCounterSelected

INSERT INTO public.translations (key, locale, value) VALUES

-- Sub-intent selection range hint
('profileSelectSubIntentsMinMax', 'en', 'Select {min} to {max} sub-intents'),
('profileSelectSubIntentsMinMax', 'es', 'Selecciona {min} a {max} sub-intenciones'),
('profileSelectSubIntentsMinMax', 'he', 'בחר {min} עד {max} תת-כוונות'),

-- Selection counter (used for sub-intents, categories, and sub-interests)
('profileCounterSelected', 'en', '{count} / {max} selected'),
('profileCounterSelected', 'es', '{count} / {max} seleccionados'),
('profileCounterSelected', 'he', '{count} / {max} נבחרו')

ON CONFLICT (key, locale) DO UPDATE SET value = EXCLUDED.value;
