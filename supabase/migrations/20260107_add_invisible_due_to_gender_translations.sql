-- Migration: Add gendered variants for invisibleDueTo and andInvisible
-- Adds: invisibleDueTo_male, invisibleDueTo_female, invisibleDueTo_non_binary
-- and: andInvisible_male, andInvisible_female, andInvisible_non_binary

-- 1) Copy invisibleDueTo variants from the existing invisibleDueTo rows (one per locale)
INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), t.locale, 'invisibleDueTo_male', t.value, now(), now()
FROM translations t
WHERE t.key = 'invisibleDueTo'
  AND NOT EXISTS (
    SELECT 1 FROM translations t2 WHERE t2.key = 'invisibleDueTo_male' AND t2.locale = t.locale
  );

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), t.locale, 'invisibleDueTo_female', t.value, now(), now()
FROM translations t
WHERE t.key = 'invisibleDueTo'
  AND NOT EXISTS (
    SELECT 1 FROM translations t2 WHERE t2.key = 'invisibleDueTo_female' AND t2.locale = t.locale
  );

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), t.locale, 'invisibleDueTo_non_binary', t.value, now(), now()
FROM translations t
WHERE t.key = 'invisibleDueTo'
  AND NOT EXISTS (
    SELECT 1 FROM translations t2 WHERE t2.key = 'invisibleDueTo_non_binary' AND t2.locale = t.locale
  );

-- 2) Add andInvisible variants (fallbacking to a simple 'and Invisible' default per locale where invisibleDueTo exists)
INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), t.locale, 'andInvisible_male', 'and Invisible', now(), now()
FROM translations t
WHERE t.key = 'invisibleDueTo'
  AND NOT EXISTS (
    SELECT 1 FROM translations t2 WHERE t2.key = 'andInvisible_male' AND t2.locale = t.locale
  );

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), t.locale, 'andInvisible_female', 'and Invisible', now(), now()
FROM translations t
WHERE t.key = 'invisibleDueTo'
  AND NOT EXISTS (
    SELECT 1 FROM translations t2 WHERE t2.key = 'andInvisible_female' AND t2.locale = t.locale
  );

INSERT INTO translations (id, locale, key, value, created_at, updated_at)
SELECT gen_random_uuid(), t.locale, 'andInvisible_non_binary', 'and Invisible', now(), now()
FROM translations t
WHERE t.key = 'invisibleDueTo'
  AND NOT EXISTS (
    SELECT 1 FROM translations t2 WHERE t2.key = 'andInvisible_non_binary' AND t2.locale = t.locale
  );

-- If you prefer more carefully translated values, update these rows in the Supabase dashboard after running this migration.
