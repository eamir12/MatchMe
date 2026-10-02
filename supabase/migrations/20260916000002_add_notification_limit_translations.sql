-- Translations for notification limit strings (Admin UI + fallbacks).
-- Table: public.translations(locale, key, value). Idempotent upserts.

CREATE TABLE IF NOT EXISTS public.translations (
  locale TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (locale, key)
);

-- RLS: translations are public UI strings, readable by anon/authenticated.
-- Matches ensure_translations_policy.sql. Idempotent so linter is satisfied
-- and fresh projects get a locked-down table, not an open one.
ALTER TABLE public.translations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow public read access to translations" ON public.translations;
CREATE POLICY "Allow public read access to translations"
  ON public.translations FOR SELECT USING (true);
GRANT SELECT ON public.translations TO anon, authenticated, service_role;

INSERT INTO public.translations (locale, key, value) VALUES
-- English (mirrors matchme_admin _defaultTranslations)
('en', 'adminBroadcastsTitleTooLong', 'Max {max} chars ({actual})'),
('en', 'adminBroadcastsTitleTooManyBytes', 'Max {max} bytes ({actual})'),
('en', 'adminBroadcastsMessageTooLong', 'Max {max} chars ({actual})'),
('en', 'adminBroadcastsMessageTooManyBytes', 'Max {max} bytes ({actual})'),
('en', 'adminBroadcastsActionTextTooLong', 'Max {max} chars ({actual})'),
('en', 'adminBroadcastsLimitsHintTitle', 'Max {chars} chars / {bytes} bytes (FCM 4096B total)'),
('en', 'adminBroadcastsLimitsHintMessage', 'Max {chars} chars / {bytes} bytes'),
('en', 'adminBroadcastsLimitsHintActionText', 'Max {chars} chars'),
('en', 'adminBroadcastsAudienceOverCap', 'Audience {count} exceeds 20000 cap - narrow filters or split into chunks.'),
('en', 'adminBroadcastsAudienceLarge', 'Large audience ({count}) - sends in 2000/chunks, may take several minutes.'),
('en', 'adminBroadcastsCounter', '{chars} / {maxChars} chars • {bytes} / {maxBytes} bytes'),
('en', 'adminBroadcastsCounterShort', '{chars} / {max} chars'),
-- Spanish
('es', 'adminBroadcastsTitleTooLong', 'Máx. {max} caracteres ({actual})'),
('es', 'adminBroadcastsTitleTooManyBytes', 'Máx. {max} bytes ({actual})'),
('es', 'adminBroadcastsMessageTooLong', 'Máx. {max} caracteres ({actual})'),
('es', 'adminBroadcastsMessageTooManyBytes', 'Máx. {max} bytes ({actual})'),
('es', 'adminBroadcastsActionTextTooLong', 'Máx. {max} caracteres ({actual})'),
('es', 'adminBroadcastsLimitsHintTitle', 'Máx. {chars} caracteres / {bytes} bytes (FCM 4096B total)'),
('es', 'adminBroadcastsLimitsHintMessage', 'Máx. {chars} caracteres / {bytes} bytes'),
('es', 'adminBroadcastsLimitsHintActionText', 'Máx. {chars} caracteres'),
('es', 'adminBroadcastsAudienceOverCap', 'Audiencia {count} supera el límite de 20000: ajusta filtros o divide en partes.'),
('es', 'adminBroadcastsAudienceLarge', 'Audiencia grande ({count}): se envía en bloques de 2000, puede tardar varios minutos.'),
('es', 'adminBroadcastsCounter', '{chars} / {maxChars} caracteres • {bytes} / {maxBytes} bytes'),
('es', 'adminBroadcastsCounterShort', '{chars} / {max} caracteres'),
-- Hebrew
('he', 'adminBroadcastsTitleTooLong', 'מקסימום {max} תווים ({actual})'),
('he', 'adminBroadcastsTitleTooManyBytes', 'מקסימום {max} בתים ({actual})'),
('he', 'adminBroadcastsMessageTooLong', 'מקסימום {max} תווים ({actual})'),
('he', 'adminBroadcastsMessageTooManyBytes', 'מקסימום {max} בתים ({actual})'),
('he', 'adminBroadcastsActionTextTooLong', 'מקסימום {max} תווים ({actual})'),
('he', 'adminBroadcastsLimitsHintTitle', 'מקסימום {chars} תווים / {bytes} בתים (FCM 4096B סה״כ)'),
('he', 'adminBroadcastsLimitsHintMessage', 'מקסימום {chars} תווים / {bytes} בתים'),
('he', 'adminBroadcastsLimitsHintActionText', 'מקסימום {chars} תווים'),
('he', 'adminBroadcastsAudienceOverCap', 'קהל {count} חורג ממגבלת 20000 - צמצם מסננים או פצל לחלקים.'),
('he', 'adminBroadcastsAudienceLarge', 'קהל גדול ({count}) - נשלח בקבוצות של 2000, עשוי לקחת כמה דקות.'),
('he', 'adminBroadcastsCounter', '{chars} / {maxChars} תווים • {bytes} / {maxBytes} בתים'),
('he', 'adminBroadcastsCounterShort', '{chars} / {max} תווים')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
