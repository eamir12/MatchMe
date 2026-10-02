-- Add translations for new ad placement features
-- Created: 2026-04-22

-- English translations
INSERT INTO translations (locale, key, value, created_at) VALUES
  ('en', 'adminSponsoredAdsPlacements', 'Placements', NOW()),
  ('en', 'adminSponsoredAdsPlacementHome', 'Home', NOW()),
  ('en', 'adminSponsoredAdsPlacementMatches', 'Matches', NOW()),
  ('en', 'adminSponsoredAdsPlacementChats', 'Chats', NOW()),
  ('en', 'adminSponsoredAdsPlacementEvents', 'Events', NOW()),
  ('en', 'adminSponsoredAdsFormActions', 'Actions', NOW()),
  ('en', 'adminSponsoredAdsValidationContentRequired', 'Please provide at least one field: headline, body, CTA, sponsor name, or image', NOW()),
  ('en', 'adminSponsoredAdsValidationPlacementRequired', 'Please select at least one placement', NOW()),
  ('en', 'adminSponsoredAdsValidationDestinationUrlRequired', 'Please enter a destination URL', NOW())
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Spanish translations
INSERT INTO translations (locale, key, value, created_at) VALUES
  ('es', 'adminSponsoredAdsPlacements', 'Ubicaciones', NOW()),
  ('es', 'adminSponsoredAdsPlacementHome', 'Inicio', NOW()),
  ('es', 'adminSponsoredAdsPlacementMatches', 'Matches', NOW()),
  ('es', 'adminSponsoredAdsPlacementChats', 'Chats', NOW()),
  ('es', 'adminSponsoredAdsPlacementEvents', 'Eventos', NOW()),
  ('es', 'adminSponsoredAdsFormActions', 'Acciones', NOW()),
  ('es', 'adminSponsoredAdsValidationContentRequired', 'Por favor proporcione al menos un campo: titular, cuerpo, CTA, nombre del patrocinador o imagen', NOW()),
  ('es', 'adminSponsoredAdsValidationPlacementRequired', 'Por favor seleccione al menos una ubicación', NOW()),
  ('es', 'adminSponsoredAdsValidationDestinationUrlRequired', 'Por favor ingrese una URL de destino', NOW())
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

-- Hebrew translations
INSERT INTO translations (locale, key, value, created_at) VALUES
  ('he', 'adminSponsoredAdsPlacements', 'מיקומים', NOW()),
  ('he', 'adminSponsoredAdsPlacementHome', 'בית', NOW()),
  ('he', 'adminSponsoredAdsPlacementMatches', 'התאמות', NOW()),
  ('he', 'adminSponsoredAdsPlacementChats', 'צ''אטים', NOW()),
  ('he', 'adminSponsoredAdsPlacementEvents', 'אירועים', NOW()),
  ('he', 'adminSponsoredAdsFormActions', 'פעולות', NOW()),
  ('he', 'adminSponsoredAdsValidationContentRequired', 'אנא הזן לפחות שדה אחד: כותרת, תוכן, קריאה לפעולה, שם נותן החסות או תמונה', NOW()),
  ('he', 'adminSponsoredAdsValidationPlacementRequired', 'אנא בחר לפחות מיקום אחד', NOW()),
  ('he', 'adminSponsoredAdsValidationDestinationUrlRequired', 'אנא הזן כתובת URL ליעד', NOW())
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
