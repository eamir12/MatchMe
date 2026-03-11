BEGIN;

ALTER TABLE public.notification_queue
DROP CONSTRAINT IF EXISTS notification_queue_status_check;

ALTER TABLE public.notification_queue
DROP CONSTRAINT IF EXISTS notification_queue_status_check1;

ALTER TABLE public.notification_queue
ADD CONSTRAINT notification_queue_status_check
CHECK (status IN ('pending', 'processing', 'sent', 'failed'));

COMMIT;
