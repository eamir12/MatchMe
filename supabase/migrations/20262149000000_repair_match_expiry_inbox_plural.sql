-- Migration: repair the match-expiry rows already in the notification inbox.
-- Date: 2026-10-21
-- Purpose:
--   * The inbox stores the RENDERED text of a notification, so the rows the
--     cron wrote before the plural fix keep the old wording ("1 minutes
--     left"). The count is still in `data.remaining_seconds`, so the text
--     can be re-rendered from the translation table.
--   * Only rows whose title no longer matches the current translation are
--     touched: a row written by the fixed cron already carries the right
--     wording and is left exactly as it is.
--   * The minutes are recomputed exactly like the cron does
--     (max(1, ceil(remaining_seconds / 60))) and the language is normalised
--     the same way (normalizeSupportedLocale in
--     supabase/functions/cron-jobs/index.ts), so a repaired row reads
--     exactly like a freshly written one.
--
-- NOTE: the cron that writes these rows lives in an edge function. It has to
-- be deployed for NEW rows to be right:
--
--   supabase functions deploy cron-jobs

BEGIN;

WITH renderable AS (
  SELECT
    n.id,
    GREATEST(1, CEIL((n.data ->> 'remaining_seconds')::numeric / 60))::int AS minutes,
    CASE
      WHEN lower(coalesce(u.preferred_language, '')) LIKE 'he%' THEN 'he'
      WHEN lower(coalesce(u.preferred_language, '')) LIKE 'es%' THEN 'es'
      ELSE 'en'
    END AS locale,
    n.data ->> 'other_user_id' AS other_user_id
  FROM public.user_notifications n
  JOIN public.users u ON u.id = n.user_id
  WHERE n.type = 'match_expiry'
    AND n.deleted_at IS NULL
    AND n.data ? 'remaining_seconds'
),
rendered AS (
  SELECT
    r.id,
    replace(t_title.value, '{count}', r.minutes::text) AS title,
    replace(
      replace(t_body.value, '{count}', r.minutes::text),
      '{otherUserName}',
      coalesce(
        nullif(public.mask_full_name(other.name), 'Unknown User'),
        'Someone'
      )
    ) AS body
  FROM renderable r
  LEFT JOIN public.users other
    ON other.id = nullif(r.other_user_id, '')::uuid
  JOIN public.translations t_title
    ON t_title.locale = r.locale
   AND t_title.value IS NOT NULL
   AND t_title.value <> ''
   AND t_title.key = CASE
         WHEN r.locale = 'he' AND r.minutes = 2 THEN 'matchExpiryTitle_two'
         WHEN r.minutes = 1 THEN 'matchExpiryTitle_one'
         ELSE 'matchExpiryTitle'
       END
  JOIN public.translations t_body
    ON t_body.locale = r.locale
   AND t_body.value IS NOT NULL
   AND t_body.value <> ''
   AND t_body.key = CASE
         WHEN r.locale = 'he' AND r.minutes = 2 THEN 'matchExpiryBody_two'
         WHEN r.minutes = 1 THEN 'matchExpiryBody_one'
         ELSE 'matchExpiryBody'
       END
)
UPDATE public.user_notifications n
SET title = r.title,
    body = r.body
FROM rendered r
WHERE n.id = r.id
  AND n.title IS DISTINCT FROM r.title;

COMMIT;
