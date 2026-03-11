INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'adminDashboardAIQuotaTitle', $$AI quotas$$),
  ('es', 'adminDashboardAIQuotaTitle', $$Cuotas de IA$$),
  ('he', 'adminDashboardAIQuotaTitle', $$מכסות AI$$),

  ('en', 'adminDashboardAIQuotaUpdatedAt', $$Updated$$),
  ('es', 'adminDashboardAIQuotaUpdatedAt', $$Actualizado$$),
  ('he', 'adminDashboardAIQuotaUpdatedAt', $$עודכן$$),

  ('en', 'adminDashboardAIQuotaEmpty', $$No quota data yet.$$),
  ('es', 'adminDashboardAIQuotaEmpty', $$Aún no hay datos de cuota.$$),
  ('he', 'adminDashboardAIQuotaEmpty', $$אין עדיין נתוני מכסה.$$),

  ('en', 'adminDashboardAIQuotaMetric', $$Metric$$),
  ('es', 'adminDashboardAIQuotaMetric', $$Métrica$$),
  ('he', 'adminDashboardAIQuotaMetric', $$מדד$$),

  ('en', 'adminDashboardAIQuotaWindow', $$Window$$),
  ('es', 'adminDashboardAIQuotaWindow', $$Ventana$$),
  ('he', 'adminDashboardAIQuotaWindow', $$חלון$$),

  ('en', 'adminDashboardAIQuotaUsed', $$Used$$),
  ('es', 'adminDashboardAIQuotaUsed', $$Usado$$),
  ('he', 'adminDashboardAIQuotaUsed', $$נוצל$$),

  ('en', 'adminDashboardAIQuotaLimit', $$Limit$$),
  ('es', 'adminDashboardAIQuotaLimit', $$Límite$$),
  ('he', 'adminDashboardAIQuotaLimit', $$מגבלה$$),

  ('en', 'adminDashboardAIQuotaPercent', $$%$$),
  ('es', 'adminDashboardAIQuotaPercent', $$%$$),
  ('he', 'adminDashboardAIQuotaPercent', $$%$$),

  ('en', 'adminDashboardAIQuotaStatus', $$Status$$),
  ('es', 'adminDashboardAIQuotaStatus', $$Estado$$),
  ('he', 'adminDashboardAIQuotaStatus', $$סטטוס$$),

  ('en', 'adminDashboardAIQuotaWindowBillingPeriod', $$Billing period$$),
  ('es', 'adminDashboardAIQuotaWindowBillingPeriod', $$Período de facturación$$),
  ('he', 'adminDashboardAIQuotaWindowBillingPeriod', $$תקופת חיוב$$),

  ('en', 'adminAiQuotaWarnTitle', $$AI quota warning$$),
  ('es', 'adminAiQuotaWarnTitle', $$Advertencia de cuota de IA$$),
  ('he', 'adminAiQuotaWarnTitle', $$אזהרת מכסת AI$$),

  ('en', 'adminAiQuotaCriticalTitle', $$AI quota critical$$),
  ('es', 'adminAiQuotaCriticalTitle', $$Cuota de IA crítica$$),
  ('he', 'adminAiQuotaCriticalTitle', $$מכסת AI קריטית$$),

  ('en', 'adminAiQuotaAlertBody', $${provider}: {used}/{limit} {unit} used ({percent}%)$$),
  ('es', 'adminAiQuotaAlertBody', $${provider}: {used}/{limit} {unit} usados ({percent}%)$$),
  ('he', 'adminAiQuotaAlertBody', $${provider}: נוצל {used}/{limit} {unit} ({percent}%)$$),

  ('en', 'adminAiQuotaAlertBodyNoLimit', $${provider}: {used} {unit} used$$),
  ('es', 'adminAiQuotaAlertBodyNoLimit', $${provider}: {used} {unit} usados$$),
  ('he', 'adminAiQuotaAlertBodyNoLimit', $${provider}: נוצל {used} {unit}$$),

  ('en', 'adminAiProviderDeepL', $$DeepL$$),
  ('es', 'adminAiProviderDeepL', $$DeepL$$),
  ('he', 'adminAiProviderDeepL', $$DeepL$$),

  ('en', 'adminAiProviderGemini', $$Gemini$$),
  ('es', 'adminAiProviderGemini', $$Gemini$$),
  ('he', 'adminAiProviderGemini', $$Gemini$$),

  ('en', 'adminAiQuotaStatusOk', $$OK$$),
  ('es', 'adminAiQuotaStatusOk', $$OK$$),
  ('he', 'adminAiQuotaStatusOk', $$תקין$$),

  ('en', 'adminAiQuotaStatusWarn', $$Warning$$),
  ('es', 'adminAiQuotaStatusWarn', $$Advertencia$$),
  ('he', 'adminAiQuotaStatusWarn', $$אזהרה$$),

  ('en', 'adminAiQuotaStatusCritical', $$Critical$$),
  ('es', 'adminAiQuotaStatusCritical', $$Crítico$$),
  ('he', 'adminAiQuotaStatusCritical', $$קריטי$$),

  ('en', 'adminAiQuotaStatusUnknown', $$Unknown$$),
  ('es', 'adminAiQuotaStatusUnknown', $$Desconocido$$),
  ('he', 'adminAiQuotaStatusUnknown', $$לא ידוע$$)
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

