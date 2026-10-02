INSERT INTO translations (locale, key, value, created_at, updated_at)
VALUES
  ('en', 'settingsCurrencyPreference', 'Currency', NOW(), NOW()),
  ('es', 'settingsCurrencyPreference', 'Moneda', NOW(), NOW()),
  ('he', 'settingsCurrencyPreference', 'מטבע', NOW(), NOW()),

  ('en', 'settingsCurrencyPreferenceDesc', 'Used for subscription prices and supported checkout flows.', NOW(), NOW()),
  ('es', 'settingsCurrencyPreferenceDesc', 'Se usa para los precios de suscripción y para los flujos de pago compatibles.', NOW(), NOW()),
  ('he', 'settingsCurrencyPreferenceDesc', 'משמש למחירי המנויים ולתהליכי תשלום נתמכים.', NOW(), NOW()),

  ('en', 'currencySuggestedByRegion', 'Suggested from your region. You can change it anytime.', NOW(), NOW()),
  ('es', 'currencySuggestedByRegion', 'Sugerida según tu región. Puedes cambiarla en cualquier momento.', NOW(), NOW()),
  ('he', 'currencySuggestedByRegion', 'המטבע הוצע לפי האזור שלך. אפשר לשנות אותו בכל עת.', NOW(), NOW()),

  ('en', 'paywallPreferredCurrencyLabel', 'Preferred currency', NOW(), NOW()),
  ('es', 'paywallPreferredCurrencyLabel', 'Moneda preferida', NOW(), NOW()),
  ('he', 'paywallPreferredCurrencyLabel', 'מטבע מועדף', NOW(), NOW()),

  ('en', 'paywallCurrencyEstimateFallback', 'Converted prices are estimated from cached exchange rates.', NOW(), NOW()),
  ('es', 'paywallCurrencyEstimateFallback', 'Los precios convertidos son una estimación basada en tasas de cambio en caché.', NOW(), NOW()),
  ('he', 'paywallCurrencyEstimateFallback', 'המחירים המומרים הם הערכה המבוססת על שערי חליפין שמורים במטמון.', NOW(), NOW()),

  ('en', 'currencyPickerTitle', 'Choose currency', NOW(), NOW()),
  ('es', 'currencyPickerTitle', 'Elegir moneda', NOW(), NOW()),
  ('he', 'currencyPickerTitle', 'בחירת מטבע', NOW(), NOW()),

  ('en', 'currencySearchHint', 'Search by symbol, code, or currency name', NOW(), NOW()),
  ('es', 'currencySearchHint', 'Buscar por símbolo, código o nombre de moneda', NOW(), NOW()),
  ('he', 'currencySearchHint', 'חיפוש לפי סמל, קוד או שם המטבע', NOW(), NOW()),

  ('en', 'currencyRecentSection', 'Recent', NOW(), NOW()),
  ('es', 'currencyRecentSection', 'Recientes', NOW(), NOW()),
  ('he', 'currencyRecentSection', 'אחרונים', NOW(), NOW()),

  ('en', 'currencyTopSection', 'Top currencies', NOW(), NOW()),
  ('es', 'currencyTopSection', 'Monedas principales', NOW(), NOW()),
  ('he', 'currencyTopSection', 'מטבעות מובילים', NOW(), NOW()),

  ('en', 'currencyAllSection', 'All currencies', NOW(), NOW()),
  ('es', 'currencyAllSection', 'Todas las monedas', NOW(), NOW()),
  ('he', 'currencyAllSection', 'כל המטבעות', NOW(), NOW()),

  ('en', 'currencyNoResults', 'No currencies match your search.', NOW(), NOW()),
  ('es', 'currencyNoResults', 'Ninguna moneda coincide con tu búsqueda.', NOW(), NOW()),
  ('he', 'currencyNoResults', 'לא נמצאו מטבעות התואמים לחיפוש שלך.', NOW(), NOW())
ON CONFLICT (locale, key) DO UPDATE
SET
  value = EXCLUDED.value,
  updated_at = NOW();
