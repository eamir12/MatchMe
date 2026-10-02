-- Persist the height unit selected in the profile wizard and standardize degree labels.
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS height_unit text NOT NULL DEFAULT 'cm';

ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_height_unit_check
  CHECK (height_unit IN ('cm', 'ft'));

UPDATE public.app_profile_options
SET profile_value = CASE option_key
      WHEN 'associate' THEN 'Associate Degree'
      WHEN 'bachelor' THEN 'Bachelor''s Degree'
      WHEN 'master' THEN 'Master''s Degree'
      WHEN 'phd' THEN 'Doctorate (PhD)'
      ELSE profile_value
    END
WHERE field_key = 'education'
  AND option_key IN ('associate', 'bachelor', 'master', 'phd');

UPDATE public.user_profiles
SET education = CASE education
      WHEN 'Associate' THEN 'Associate Degree'
      WHEN 'Bachelor' THEN 'Bachelor''s Degree'
      WHEN 'Master' THEN 'Master''s Degree'
      WHEN 'PhD' THEN 'Doctorate (PhD)'
      ELSE education
    END
WHERE education IN ('Associate', 'Bachelor', 'Master', 'PhD');

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'educationAssociate', 'Associate Degree'),
  ('es', 'educationAssociate', 'Título de asociado'),
  ('he', 'educationAssociate', 'תואר עמית'),
  ('en', 'educationBachelor', 'Bachelor''s Degree'),
  ('es', 'educationBachelor', 'Licenciatura'),
  ('he', 'educationBachelor', 'תואר ראשון'),
  ('en', 'educationMaster', 'Master''s Degree'),
  ('es', 'educationMaster', 'Maestría'),
  ('he', 'educationMaster', 'תואר שני'),
  ('en', 'educationPhd', 'Doctorate (PhD)'),
  ('es', 'educationPhd', 'Doctorado'),
  ('he', 'educationPhd', 'דוקטורט')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;