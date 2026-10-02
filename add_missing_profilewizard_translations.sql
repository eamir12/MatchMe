-- Add missing translations for profile wizard bio validation, education, height, and match profile fallbacks
-- Languages: en (English), es (Spanish), he (Hebrew)

INSERT INTO translations (locale, key, value) VALUES
  -- Bio validation messages
  ('en', 'profileEditBioTooLong', 'Your bio is too long.'),
  ('es', 'profileEditBioTooLong', 'Tu biografía es demasiado larga.'),
  ('he', 'profileEditBioTooLong', 'הביוגרפיה ארוכה מדי.'),

  ('en', 'profileEditBioContainsLink', 'Your bio contains a link, which is not allowed.'),
  ('es', 'profileEditBioContainsLink', 'Tu biografía contiene un enlace, lo cual no está permitido.'),
  ('he', 'profileEditBioContainsLink', 'הביוגרפיה מכילה קישור, דבר שאינו מותר.'),

  ('en', 'profileEditBioContainsEmail', 'Your bio contains an email address, which is not allowed.'),
  ('es', 'profileEditBioContainsEmail', 'Tu biografía contiene un correo electrónico, lo cual no está permitido.'),
  ('he', 'profileEditBioContainsEmail', 'הביוגרפיה מכילה כתובת אימייל, דבר שאינו מותר.'),

  ('en', 'profileEditBioContainsPhone', 'Your bio contains a phone number, which is not allowed.'),
  ('es', 'profileEditBioContainsPhone', 'Tu biografía contiene un número de teléfono, lo cual no está permitido.'),
  ('he', 'profileEditBioContainsPhone', 'הביוגרפיה מכילה מספר טלפון, דבר שאינו מותר.'),

  ('en', 'profileEditBioContainsContact', 'Your bio contains contact info, which is not allowed.'),
  ('es', 'profileEditBioContainsContact', 'Tu biografía contiene información de contacto, lo cual no está permitido.'),
  ('he', 'profileEditBioContainsContact', 'הביוגרפיה מכילה פרטי קשר, דבר שאינו מותר.'),

  ('en', 'profileEditBioSpamOrPromotion', 'Your bio looks like spam or promotion.'),
  ('es', 'profileEditBioSpamOrPromotion', 'Tu biografía parece spam o promoción.'),
  ('he', 'profileEditBioSpamOrPromotion', 'הביוגרפיה נראית כמו ספאם או קידום.'),

  -- Height unit suffix
  ('en', 'profileHeightCm', 'centimeters'),
  ('es', 'profileHeightCm', 'centímetros'),
  ('he', 'profileHeightCm', 'סנטימטרים'),

  -- Education level labels
  ('en', 'educationHighSchool', 'High School'),
  ('es', 'educationHighSchool', 'Secundaria'),
  ('he', 'educationHighSchool', 'תיכון'),

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
  ('he', 'educationPhd', 'דוקטורט'),

  ('en', 'educationOther', 'Other'),
  ('es', 'educationOther', 'Otro'),
  ('he', 'educationOther', 'אחר'),

  -- Match profile fallback strings
  ('en', 'matchProfileNoBio', 'No bio provided.'),
  ('es', 'matchProfileNoBio', 'No se proporcionó biografía.'),
  ('he', 'matchProfileNoBio', 'לא סופקה ביוגרפיה.'),

  ('en', 'matchProfileNoLanguages', 'No languages listed'),
  ('es', 'matchProfileNoLanguages', 'No hay idiomas listados'),
  ('he', 'matchProfileNoLanguages', 'לא רשומות שפות')
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
