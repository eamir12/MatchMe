BEGIN;

DELETE FROM public.notification_queue;

DELETE FROM public.admin_broadcast_deliveries;

DELETE FROM public.admin_broadcasts;

UPDATE public.user_session
SET metadata = (COALESCE(metadata, '{}'::jsonb) - 'fcm_token' - 'fcm_token_updated_at')
WHERE (metadata ? 'fcm_token') OR (metadata ? 'fcm_token_updated_at');

UPDATE public.user_session
SET revoked = true
WHERE revoked = false;

COMMIT;
