INSERT INTO translations (locale, key, value, created_at) VALUES
  ('en', 'generalAll', 'All', NOW()),
  ('es', 'generalAll', 'Todos', NOW()),
  ('he', 'generalAll', 'הכל', NOW())
ON CONFLICT (locale, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = NOW();
