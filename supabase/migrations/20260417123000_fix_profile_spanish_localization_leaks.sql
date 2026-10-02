BEGIN;

-- Backfill profile-view translations used by profile and match profile screens.
INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'profileBirthday', 'Birthday'),
  ('es', 'profileBirthday', 'Cumpleanos'),
  ('he', 'profileBirthday', 'יום הולדת'),

  ('en', 'profileAbout', 'About'),
  ('es', 'profileAbout', 'Acerca de'),
  ('he', 'profileAbout', 'אודות'),

  ('en', 'profileEditIntentsTitle', 'Intentions'),
  ('es', 'profileEditIntentsTitle', 'Intenciones'),
  ('he', 'profileEditIntentsTitle', 'כוונות'),

  ('en', 'profileInterests', 'Interests'),
  ('es', 'profileInterests', 'Intereses'),
  ('he', 'profileInterests', 'תחומי עניין'),

  ('en', 'profileNoInterests', 'No interests selected'),
  ('es', 'profileNoInterests', 'No se seleccionaron intereses'),
  ('he', 'profileNoInterests', 'לא נבחרו תחומי עניין'),

  ('en', 'profileNotSet', 'Not set'),
  ('es', 'profileNotSet', 'No configurado'),
  ('he', 'profileNotSet', 'לא הוגדר'),

  ('en', 'matchProfileBio', 'About'),
  ('es', 'matchProfileBio', 'Acerca de'),
  ('he', 'matchProfileBio', 'אודות'),

  ('en', 'matchProfileSharedIntent', 'Shared Intentions'),
  ('es', 'matchProfileSharedIntent', 'Intenciones compartidas'),
  ('he', 'matchProfileSharedIntent', 'כוונות משותפות'),

  ('en', 'matchProfileSharedInterests', 'Shared Interests'),
  ('es', 'matchProfileSharedInterests', 'Intereses compartidos'),
  ('he', 'matchProfileSharedInterests', 'תחומי עניין משותפים'),

  ('en', 'profileAgeLabel', 'Age'),
  ('es', 'profileAgeLabel', 'Edad'),
  ('he', 'profileAgeLabel', 'גיל'),

  ('en', 'profileGender', 'Gender'),
  ('es', 'profileGender', 'Genero'),
  ('he', 'profileGender', 'מגדר'),

  ('en', 'gender_male', 'Male'),
  ('es', 'gender_male', 'Hombre'),
  ('he', 'gender_male', 'גבר'),

  ('en', 'gender_female', 'Female'),
  ('es', 'gender_female', 'Mujer'),
  ('he', 'gender_female', 'אישה'),

  ('en', 'gender_non_binary', 'Non-binary'),
  ('es', 'gender_non_binary', 'No binario'),
  ('he', 'gender_non_binary', 'לא בינארי'),

  -- Verified bad Spanish row found during audit.
  ('en', 'settingsMfaDisabled', 'Disabled'),
  ('es', 'settingsMfaDisabled', 'Desactivado'),
  ('he', 'settingsMfaDisabled', 'כבוי')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Ensure app gender metadata stores translation keys, not localized labels.
UPDATE public.app_gender_options
SET display_name_key = CASE lower(trim(gender_key))
  WHEN 'male' THEN 'gender_male'
  WHEN 'female' THEN 'gender_female'
  WHEN 'non_binary' THEN 'gender_non_binary'
  WHEN 'nonbinary' THEN 'gender_non_binary'
  ELSE display_name_key
END
WHERE lower(trim(gender_key)) IN ('male', 'female', 'non_binary', 'nonbinary')
  AND COALESCE(display_name_key, '') IS DISTINCT FROM CASE lower(trim(gender_key))
    WHEN 'male' THEN 'gender_male'
    WHEN 'female' THEN 'gender_female'
    WHEN 'non_binary' THEN 'gender_non_binary'
    WHEN 'nonbinary' THEN 'gender_non_binary'
    ELSE COALESCE(display_name_key, '')
  END;

COMMIT;
