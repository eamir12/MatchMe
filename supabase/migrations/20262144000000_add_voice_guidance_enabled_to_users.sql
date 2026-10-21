-- Migration: Store the voice guidance preference on the users row.
--
-- The preference used to live only in SharedPreferences, so muting voice
-- guidance on one device left the other device still talking. It is an
-- account-level preference: whether the platform can actually speak is a
-- separate concern, handled in VoiceGuidanceService (a device without a
-- usable TTS voice simply never speaks).
--
-- `public.users` is in the supabase_realtime publication, and the app has a
-- single subscription to the signed-in user's own row
-- (lib/services/my_user_realtime_service.dart), so the change reaches the
-- other devices in realtime.
--
-- Rollback: ALTER TABLE public.users DROP COLUMN voice_guidance_enabled;
BEGIN;

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS voice_guidance_enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.users.voice_guidance_enabled IS
  'Whether the account wants spoken guidance (on-device TTS). Synced across devices.';

COMMIT;
