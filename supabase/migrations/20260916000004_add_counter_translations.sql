-- Incremental: counter strings for live typed/max display.
-- 00002 already contains these for fresh installs; this covers DBs that
-- already ran 00002 before the counter keys were added. Idempotent.
INSERT INTO public.translations (locale, key, value) VALUES
('en', 'adminBroadcastsCounter', '{chars} / {maxChars} chars • {bytes} / {maxBytes} bytes'),
('en', 'adminBroadcastsCounterShort', '{chars} / {max} chars'),
('es', 'adminBroadcastsCounter', '{chars} / {maxChars} caracteres • {bytes} / {maxBytes} bytes'),
('es', 'adminBroadcastsCounterShort', '{chars} / {max} caracteres'),
('he', 'adminBroadcastsCounter', '{chars} / {maxChars} תווים • {bytes} / {maxBytes} בתים'),
('he', 'adminBroadcastsCounterShort', '{chars} / {max} תווים')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;
