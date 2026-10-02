BEGIN;

-- ============================================================================
-- Insert missing translation keys detected during startup:
--   en: adConsentAccept, adConsentCompactDescription, adConsentDescription,
--       adConsentPrivacyLink, adConsentTitle, webAdTryPremium,
--       webAdUnlockFeatures, webAdLearnMore
--   es: ads_test_1776895829181_*, ads_test_1777449306261_*,
--       ads_test_1777449306262_sponsor
-- ============================================================================

INSERT INTO public.translations (locale, key, value) VALUES

  -- ========== webAd (en / es / he) ==========
  ('en', 'webAdTryPremium', 'Try Premium'),
  ('es', 'webAdTryPremium', 'Probar Premium'),
  ('he', 'webAdTryPremium', 'נסה פרימיום'),

  ('en', 'webAdUnlockFeatures', 'Unlock all features'),
  ('es', 'webAdUnlockFeatures', 'Desbloquea todas las funciones'),
  ('he', 'webAdUnlockFeatures', 'בטל נעילת כל התכונות'),

  ('en', 'webAdLearnMore', 'Learn more'),
  ('es', 'webAdLearnMore', 'Más información'),
  ('he', 'webAdLearnMore', 'למידע נוסף'),

  -- ========== adConsent (en / es / he) ==========
  ('en', 'adConsentAccept', 'Accept'),
  ('es', 'adConsentAccept', 'Aceptar'),
  ('he', 'adConsentAccept', 'אשר'),

  ('en', 'adConsentCompactDescription', 'We use cookies to personalize ads and analyze traffic.'),
  ('es', 'adConsentCompactDescription', 'Usamos cookies para personalizar anuncios y analizar el tráfico.'),
  ('he', 'adConsentCompactDescription', 'אנו משתמשים בעוגיות כדי להתאים אישית מודעות ולנתח תעבורה.'),

  ('en', 'adConsentDescription', 'We use cookies and similar technologies to personalize ads and analyze traffic. You can control your preferences below.'),
  ('es', 'adConsentDescription', 'Usamos cookies y tecnologías similares para personalizar anuncios y analizar el tráfico. Puedes controlar tus preferencias a continuación.'),
  ('he', 'adConsentDescription', 'אנו משתמשים בעוגיות ובטכנולוגיות דומות כדי להתאים אישית מודעות ולנתח תעבורה. תוכל לשלוט בהעדפותיך להלן.'),

  ('en', 'adConsentPrivacyLink', 'Learn more about our privacy policy'),
  ('es', 'adConsentPrivacyLink', 'Más información sobre nuestra política de privacidad'),
  ('he', 'adConsentPrivacyLink', 'מידע נוסף על מדיניות הפרטיות שלנו'),

  ('en', 'adConsentTitle', 'Ad Preferences'),
  ('es', 'adConsentTitle', 'Preferencias de anuncios'),
  ('he', 'adConsentTitle', 'העדפות מודעות'),

  -- ========== ads_test keys (en / es / he) ==========
  ('en', 'ads_test_1776895829181_body',  'This is a test body.'),
  ('es', 'ads_test_1776895829181_body',  'Este es un cuerpo de prueba.'),
  ('he', 'ads_test_1776895829181_body',  'זוהי גוף טקסט לבדיקה.'),

  ('en', 'ads_test_1776895829181_cta',   ''),
  ('es', 'ads_test_1776895829181_cta',   ''),
  ('he', 'ads_test_1776895829181_cta',   ''),

  ('en', 'ads_test_1776895829181_headline', 'Test headline'),
  ('es', 'ads_test_1776895829181_headline', 'Titular de prueba'),
  ('he', 'ads_test_1776895829181_headline', 'כותרת לבדיקה'),

  ('en', 'ads_test_1776895829181_sponsor',  ''),
  ('es', 'ads_test_1776895829181_sponsor',  ''),
  ('he', 'ads_test_1776895829181_sponsor',  ''),

  ('en', 'ads_test_1777449306261_body',  'test body'),
  ('es', 'ads_test_1777449306261_body',  'cuerpo de prueba'),
  ('he', 'ads_test_1777449306261_body',  'גוף טקסט לבדיקה'),

  ('en', 'ads_test_1777449306261_cta',   'test'),
  ('es', 'ads_test_1777449306261_cta',   'prueba'),
  ('he', 'ads_test_1777449306261_cta',   'בדיקה'),

  ('en', 'ads_test_1777449306261_headline', 'This is a test headline!'),
  ('es', 'ads_test_1777449306261_headline', '¡Este es un titular de prueba!'),
  ('he', 'ads_test_1777449306261_headline', 'זוהי כותרת לבדיקה!'),

  ('en', 'ads_test_1777449306262_sponsor', 'test'),
  ('es', 'ads_test_1777449306262_sponsor', 'prueba'),
  ('he', 'ads_test_1777449306262_sponsor', 'בדיקה')

ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
