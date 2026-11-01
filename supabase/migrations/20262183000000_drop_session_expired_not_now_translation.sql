-- Remove the retired "Not now" choice from the session-expired gate:
-- the dead-session gate is now a full-screen blocking screen whose only
-- action is an explicit sign-out to the login screen.

BEGIN;

DELETE FROM translations WHERE key = 'sessionExpiredNotNow';

COMMIT;
