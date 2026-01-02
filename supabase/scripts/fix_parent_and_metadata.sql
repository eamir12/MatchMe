-- fix_parent_and_metadata.sql
-- Fix parent_id for items inserted without parent and normalize metadata
-- Run this against your database (use service role or psql with DATABASE_URL)

BEGIN;

-- 1) Set parent_id to the best matching existing parent (longest matching prefix)
WITH candidates AS (
  SELECT i.id AS kid_id, p.id AS parent_id, p.key AS parent_key
  FROM interests i
  JOIN interests p ON i.key LIKE p.key || '\_%'
  WHERE i.parent_id IS NULL AND i.key <> p.key
), best AS (
  SELECT kid_id, parent_id, parent_key,
    row_number() OVER (PARTITION BY kid_id ORDER BY length(parent_key) DESC) rn
  FROM candidates
)
UPDATE interests i
SET parent_id = b.parent_id
FROM best b
WHERE i.id = b.kid_id AND b.rn = 1;

-- 2) Ensure children have type 'sub'
UPDATE interests
SET metadata = (COALESCE(metadata::jsonb, '{}'::jsonb) || '{"type":"sub"}'::jsonb)
WHERE parent_id IS NOT NULL
  AND (COALESCE(metadata::jsonb, '{}'::jsonb) ->> 'type') IS DISTINCT FROM 'sub';

-- 3) Re-run normalization to ensure group/type fields are correct
-- Top-level intents
UPDATE interests
SET metadata = (COALESCE(metadata::jsonb, '{}'::jsonb) || '{"type":"intent"}'::jsonb)
WHERE parent_id IS NULL
  AND (COALESCE(metadata::jsonb, '{}'::jsonb) ->> 'type') IS NULL;

-- Immediate children => category
UPDATE interests
SET metadata = (COALESCE(metadata::jsonb, '{}'::jsonb) || '{"type":"category"}'::jsonb)
WHERE parent_id IN (SELECT id FROM interests WHERE parent_id IS NULL)
  AND (COALESCE(metadata::jsonb, '{}'::jsonb) ->> 'type') IS NULL;

-- Deeper children => sub
UPDATE interests
SET metadata = (COALESCE(metadata::jsonb, '{}'::jsonb) || '{"type":"sub"}'::jsonb)
WHERE parent_id IN (SELECT id FROM interests WHERE parent_id IS NOT NULL)
  AND (COALESCE(metadata::jsonb, '{}'::jsonb) ->> 'type') IS NULL;

-- Recompute group by root ancestor
WITH RECURSIVE ancestors AS (
  SELECT id, parent_id, key, id AS start_id FROM interests
  UNION ALL
  SELECT p.id, p.parent_id, p.key, ancestors.start_id FROM interests p
    JOIN ancestors ON p.id = ancestors.parent_id
)
UPDATE interests i
SET metadata = (COALESCE(metadata::jsonb, '{}'::jsonb) || jsonb_build_object('group', (SELECT key FROM ancestors a WHERE a.start_id = i.id AND a.parent_id IS NULL LIMIT 1)))::jsonb
WHERE (COALESCE(metadata::jsonb, '{}'::jsonb) ->> 'group') IS NULL
   OR (COALESCE(metadata::jsonb, '{}'::jsonb) ->> 'group') <> (SELECT key FROM ancestors a WHERE a.start_id = i.id AND a.parent_id IS NULL LIMIT 1);

COMMIT;
