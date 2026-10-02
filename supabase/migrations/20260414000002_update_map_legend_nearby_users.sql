-- Update map legend translation from "online users" to "nearby users"
-- English, Spanish, and Hebrew

BEGIN;

INSERT INTO translations (key, locale, value) VALUES
('mapLegendOnlineUsersApprox', 'en', 'Nearby users')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

INSERT INTO translations (key, locale, value) VALUES
('mapLegendOnlineUsersApprox', 'es', 'Usuarios cercanos')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

INSERT INTO translations (key, locale, value) VALUES
('mapLegendOnlineUsersApprox', 'he', 'משתמשים בקרבת מקום')
ON CONFLICT (key, locale) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();

COMMIT;
