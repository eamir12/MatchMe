-- Add translations for new ad placement features
-- Created: 2026-04-22

-- English translations
INSERT INTO translations (locale, key, value, section, created_at) VALUES
  ('en', 'adminSponsoredAdsPlacements', 'Placements', 'admin_sponsored_ads', NOW()),
  ('en', 'adminSponsoredAdsPlacementChatsInline', 'Chats', 'admin_sponsored_ads', NOW()),
  ('en', 'adminSponsoredAdsPlacementEventsInline', 'Events', 'admin_sponsored_ads', NOW()),
  ('en', 'adminSponsoredAdsFormActions', 'Actions', 'admin_sponsored_ads', NOW()),
  ('en', 'adminSponsoredAdsValidationContentRequired', 'Please provide at least one field: headline, body, CTA, sponsor name, or image', 'admin_sponsored_ads', NOW()),
  ('en', 'adminSponsoredAdsValidationPlacementRequired', 'Please select at least one placement', 'admin_sponsored_ads', NOW()),
  ('en', 'adminSponsoredAdsValidationDestinationUrlRequired', 'Please enter a destination URL', 'admin_sponsored_ads', NOW())
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  section = EXCLUDED.section,
  updated_at = NOW();

-- Spanish translations
INSERT INTO translations (locale, key, value, section, created_at) VALUES
  ('es', 'adminSponsoredAdsPlacements', 'Ubicaciones', 'admin_sponsored_ads', NOW()),
  ('es', 'adminSponsoredAdsPlacementChatsInline', 'Chats', 'admin_sponsored_ads', NOW()),
  ('es', 'adminSponsoredAdsPlacementEventsInline', 'Eventos', 'admin_sponsored_ads', NOW()),
  ('es', 'adminSponsoredAdsFormActions', 'Acciones', 'admin_sponsored_ads', NOW()),
  ('es', 'adminSponsoredAdsValidationContentRequired', 'Por favor proporcione al menos un campo: titular, cuerpo, CTA, nombre del patrocinador o imagen', 'admin_sponsored_ads', NOW()),
  ('es', 'adminSponsoredAdsValidationPlacementRequired', 'Por favor seleccione al menos una ubicación', 'admin_sponsored_ads', NOW()),
  ('es', 'adminSponsoredAdsValidationDestinationUrlRequired', 'Por favor ingrese una URL de destino', 'admin_sponsored_ads', NOW())
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  section = EXCLUDED.section,
  updated_at = NOW();

-- Hebrew translations
INSERT INTO translations (locale, key, value, section, created_at) VALUES
  ('he', 'adminSponsoredAdsPlacements', 'מיקומים', 'admin_sponsored_ads', NOW()),
  ('he', 'adminSponsoredAdsPlacementChatsInline', 'צ''אטים', 'admin_sponsored_ads', NOW()),
  ('he', 'adminSponsoredAdsPlacementEventsInline', 'אירועים', 'admin_sponsored_ads', NOW()),
  ('he', 'adminSponsoredAdsFormActions', 'פעולות', 'admin_sponsored_ads', NOW()),
  ('he', 'adminSponsoredAdsValidationContentRequired', 'אנא הזן לפחות שדה אחד: כותרת, תוכן, קריאה לפעולה, שם נותן החסות או תמונה', 'admin_sponsored_ads', NOW()),
  ('he', 'adminSponsoredAdsValidationPlacementRequired', 'אנא בחר לפחות מיקום אחד', 'admin_sponsored_ads', NOW()),
  ('he', 'adminSponsoredAdsValidationDestinationUrlRequired', 'אנא הזן כתובת URL ליעד', 'admin_sponsored_ads', NOW())
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  section = EXCLUDED.section,
  updated_at = NOW();
