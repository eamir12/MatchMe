BEGIN;

INSERT INTO translations (key, value, locale) VALUES
  ('securityCenterMetricSensitiveActions', 'Sensitive actions', 'en'),
  ('securityCenterMetricSensitiveActionsVerified', 'Ready', 'en'),
  ('securityCenterMetricSensitiveActionsPending', 'Needs verification', 'en'),
  ('securityCenterAuthenticatorCtaVerify', 'Verify now', 'en')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO translations (key, value, locale) VALUES
  ('securityCenterMetricSensitiveActions', 'Acciones sensibles', 'es'),
  ('securityCenterMetricSensitiveActionsVerified', 'Listo', 'es'),
  ('securityCenterMetricSensitiveActionsPending', 'Necesita verificacion', 'es'),
  ('securityCenterAuthenticatorCtaVerify', 'Verificar ahora', 'es')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

INSERT INTO translations (key, value, locale) VALUES
  ('securityCenterMetricSensitiveActions', 'פעולות רגישות', 'he'),
  ('securityCenterMetricSensitiveActionsVerified', 'מוכן', 'he'),
  ('securityCenterMetricSensitiveActionsPending', 'נדרש אימות', 'he'),
  ('securityCenterAuthenticatorCtaVerify', 'אמתו עכשיו', 'he')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = now();

COMMIT;
