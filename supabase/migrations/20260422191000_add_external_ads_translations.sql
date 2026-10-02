BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  -- Consent Dialog
  ('en', 'externalAdsConsentTitle', 'Personalized Ads'),
  ('es', 'externalAdsConsentTitle', 'Anuncios Personalizados'),
  ('he', 'externalAdsConsentTitle', 'מודעות מותאמות אישית'),

  ('en', 'externalAdsConsentBody', 'We use ads to keep MatchMe free. You can choose whether to see personalized ads based on your interests or general ads.'),
  ('es', 'externalAdsConsentBody', 'Usamos anuncios para mantener MatchMe gratis. Puedes elegir si ver anuncios personalizados según tus intereses o anuncios generales.'),
  ('he', 'externalAdsConsentBody', 'אנו משתמשים בפרסומות כדי לשמור על MatchMe בחינם. אתה יכול לבחור אם לראות מודעות מותאמות אישית על סמך ההעניינים שלך או מודעות כלליות.'),

  ('en', 'externalAdsPersonalizedOption', 'Personalized ads (based on my interests)'),
  ('es', 'externalAdsPersonalizedOption', 'Anuncios personalizados (basados en mis intereses)'),
  ('he', 'externalAdsPersonalizedOption', 'מודעות מותאמות אישית (על סמך ההעניינים שלי)'),

  ('en', 'externalAdsNonPersonalizedOption', 'General ads (not based on my interests)'),
  ('es', 'externalAdsNonPersonalizedOption', 'Anuncios generales (no basados en mis intereses)'),
  ('he', 'externalAdsNonPersonalizedOption', 'מודעות כלליות (לא על סמך ההעניינים שלי)'),

  ('en', 'externalAdsPrivacyLink', 'Privacy Policy'),
  ('es', 'externalAdsPrivacyLink', 'Política de Privacidad'),
  ('he', 'externalAdsPrivacyLink', 'מדיניות הפרטיות'),

  ('en', 'externalAdsAcceptButton', 'Continue'),
  ('es', 'externalAdsAcceptButton', 'Continuar'),
  ('he', 'externalAdsAcceptButton', 'המשך'),

  -- Ad Settings
  ('en', 'externalAdsSettingsTitle', 'Ad Preferences'),
  ('es', 'externalAdsSettingsTitle', 'Preferencias de Anuncios'),
  ('he', 'externalAdsSettingsTitle', 'העדפות מודעות'),

  ('en', 'externalAdsSettingsDescription', 'Control how ads are shown to you'),
  ('es', 'externalAdsSettingsDescription', 'Controla cómo se te muestran los anuncios'),
  ('he', 'externalAdsSettingsDescription', 'שלוט בדרך שבה מוצגות לך מודעות'),

  ('en', 'externalAdsPersonalizedToggle', 'Allow personalized ads'),
  ('es', 'externalAdsPersonalizedToggle', 'Permitir anuncios personalizados'),
  ('he', 'externalAdsPersonalizedToggle', 'אפשר מודעות מותאמות אישית'),

  ('en', 'externalAdsNonPersonalizedToggle', 'Allow general ads'),
  ('es', 'externalAdsNonPersonalizedToggle', 'Permitir anuncios generales'),
  ('he', 'externalAdsNonPersonalizedToggle', 'אפשר מודעות כלליות'),

  ('en', 'externalAdsOptOutAll', 'Opt out of all ads'),
  ('es', 'externalAdsOptOutAll', 'Rechazar todos los anuncios'),
  ('he', 'externalAdsOptOutAll', 'הסר הסכמה לכל המודעות'),

  ('en', 'externalAdsOptOutWarning', 'You must allow at least one type of ad'),
  ('es', 'externalAdsOptOutWarning', 'Debes permitir al menos un tipo de anuncio'),
  ('he', 'externalAdsOptOutWarning', 'עליך לאפשר לפחות סוג אחד של מודעה'),

  ('en', 'externalAdsSaved', 'Ad preferences saved'),
  ('es', 'externalAdsSaved', 'Preferencias de anuncios guardadas'),
  ('he', 'externalAdsSaved', 'העדפות מודעות נשמרו'),

  ('en', 'externalAdsSaveFailed', 'Failed to save ad preferences'),
  ('es', 'externalAdsSaveFailed', 'Error al guardar las preferencias de anuncios'),
  ('he', 'externalAdsSaveFailed', 'הפעולה לשמירת העדפות המודעות נכשלה'),

  -- Admin Dashboard
  ('en', 'externalAdsAdminTitle', 'External Ad Networks'),
  ('es', 'externalAdsAdminTitle', 'Redes de Anuncios Externas'),
  ('he', 'externalAdsAdminTitle', 'רשתות מודעות חיצוניות'),

  ('en', 'externalAdsAdminDescription', 'Manage external ad networks and revenue'),
  ('es', 'externalAdsAdminDescription', 'Gestionar redes de anuncios externas e ingresos'),
  ('he', 'externalAdsAdminDescription', 'נהל רשתות מודעות חיצוניות והכנסות'),

  ('en', 'externalAdsNetworkList', 'Ad Networks'),
  ('es', 'externalAdsNetworkList', 'Redes de Anuncios'),
  ('he', 'externalAdsNetworkList', 'רשתות מודעות'),

  ('en', 'externalAdsAddNetwork', 'Add Network'),
  ('es', 'externalAdsAddNetwork', 'Agregar Red'),
  ('he', 'externalAdsAddNetwork', 'הוסף רשת'),

  ('en', 'externalAdsNetworkName', 'Network Name'),
  ('es', 'externalAdsNetworkName', 'Nombre de la Red'),
  ('he', 'externalAdsNetworkName', 'שם הרשת'),

  ('en', 'externalAdsNetworkProvider', 'Provider'),
  ('es', 'externalAdsNetworkProvider', 'Proveedor'),
  ('he', 'externalAdsNetworkProvider', 'ספק'),

  ('en', 'externalAdsNetworkPriority', 'Priority'),
  ('es', 'externalAdsNetworkPriority', 'Prioridad'),
  ('he', 'externalAdsNetworkPriority', 'עדיפות'),

  ('en', 'externalAdsNetworkEnabled', 'Enabled'),
  ('es', 'externalAdsNetworkEnabled', 'Habilitado'),
  ('he', 'externalAdsNetworkEnabled', 'מופעל'),

  ('en', 'externalAdsAdUnitList', 'Ad Units'),
  ('es', 'externalAdsAdUnitList', 'Unidades de Anuncios'),
  ('he', 'externalAdsAdUnitList', 'יחידות מודעות'),

  ('en', 'externalAdsAddAdUnit', 'Add Ad Unit'),
  ('es', 'externalAdsAddAdUnit', 'Agregar Unidad de Anuncio'),
  ('he', 'externalAdsAddAdUnit', 'הוסף יחידת מודעה'),

  ('en', 'externalAdsAdUnitId', 'Ad Unit ID'),
  ('es', 'externalAdsAdUnitId', 'ID de Unidad de Anuncio'),
  ('he', 'externalAdsAdUnitId', 'מזהה יחידת מודעה'),

  ('en', 'externalAdsAdFormat', 'Ad Format'),
  ('es', 'externalAdsAdFormat', 'Formato de Anuncio'),
  ('he', 'externalAdsAdFormat', 'פורמט מודעה'),

  ('en', 'externalAdsPlacement', 'Placement'),
  ('es', 'externalAdsPlacement', 'Ubicación'),
  ('he', 'externalAdsPlacement', 'מיקום'),

  ('en', 'externalAdsPlatform', 'Platform'),
  ('es', 'externalAdsPlatform', 'Plataforma'),
  ('he', 'externalAdsPlatform', 'פלטפורמה'),

  -- Revenue Analytics
  ('en', 'externalAdsRevenueTitle', 'Revenue Analytics'),
  ('es', 'externalAdsRevenueTitle', 'Análisis de Ingresos'),
  ('he', 'externalAdsRevenueTitle', 'ניתוח הכנסות'),

  ('en', 'externalAdsTotalRevenue', 'Total Revenue'),
  ('es', 'externalAdsTotalRevenue', 'Ingresos Totales'),
  ('he', 'externalAdsTotalRevenue', 'סך הכנסות'),

  ('en', 'externalAdsImpressions', 'Impressions'),
  ('es', 'externalAdsImpressions', 'Impresiones'),
  ('he', 'externalAdsImpressions', 'חשיפות'),

  ('en', 'externalAdsClicks', 'Clicks'),
  ('es', 'externalAdsClicks', 'Clics'),
  ('he', 'externalAdsClicks', 'קליקים'),

  ('en', 'externalAdsCPM', 'CPM (Cost Per Mille)'),
  ('es', 'externalAdsCPM', 'CPM (Costo por Mil)'),
  ('he', 'externalAdsCPM', 'CPM (עלות לאלף)'),

  ('en', 'externalAdsCPC', 'CPC (Cost Per Click)'),
  ('es', 'externalAdsCPC', 'CPC (Costo por Clic)'),
  ('he', 'externalAdsCPC', 'CPC (עלות לקליק)'),

  ('en', 'externalAdsCTR', 'CTR (Click-Through Rate)'),
  ('es', 'externalAdsCTR', 'CTR (Tasa de Clics)'),
  ('he', 'externalAdsCTR', 'CTR (שיעור קליקים)'),

  ('en', 'externalAdsRevenueByPlacement', 'Revenue by Placement'),
  ('es', 'externalAdsRevenueByPlacement', 'Ingresos por Ubicación'),
  ('he', 'externalAdsRevenueByPlacement', 'הכנסות לפי מיקום'),

  ('en', 'externalAdsRevenueByPlatform', 'Revenue by Platform'),
  ('es', 'externalAdsRevenueByPlatform', 'Ingresos por Plataforma'),
  ('he', 'externalAdsRevenueByPlatform', 'הכנסות לפי פלטפורמה'),

  ('en', 'externalAdsRevenueByNetwork', 'Revenue by Network'),
  ('es', 'externalAdsRevenueByNetwork', 'Ingresos por Red'),
  ('he', 'externalAdsRevenueByNetwork', 'הכנסות לפי רשת'),

  ('en', 'externalAdsDateRange', 'Date Range'),
  ('es', 'externalAdsDateRange', 'Rango de Fechas'),
  ('he', 'externalAdsDateRange', 'טווח תאריכים'),

  ('en', 'externalAdsToday', 'Today'),
  ('es', 'externalAdsToday', 'Hoy'),
  ('he', 'externalAdsToday', 'היום'),

  ('en', 'externalAdsThisWeek', 'This Week'),
  ('es', 'externalAdsThisWeek', 'Esta Semana'),
  ('he', 'externalAdsThisWeek', 'השבוע'),

  ('en', 'externalAdsThisMonth', 'This Month'),
  ('es', 'externalAdsThisMonth', 'Este Mes'),
  ('he', 'externalAdsThisMonth', 'החודש'),

  ('en', 'externalAdsAllTime', 'All Time'),
  ('es', 'externalAdsAllTime', 'Todo el Tiempo'),
  ('he', 'externalAdsAllTime', 'כל הזמן')

ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
