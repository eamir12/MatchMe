-- Migration: Add a dedicated spoken confirmation for enabling voice guidance.
-- Purpose: The unmute button previously spoke voiceGuidanceUnmuteTooltip
--   ("Turn voice guidance on"), which reads like an instruction rather than a
--   state change. The tooltip keeps that wording; the spoken confirmation now
--   uses its own key so the two can be reworded independently.
-- English fallback lives in lib/providers/locale_provider.dart.
-- Reference: 20260917120000_add_voice_guidance_translations.sql

BEGIN;

INSERT INTO public.translations (locale, key, value) VALUES
  ('en', 'voiceGuidanceEnabledConfirmation', 'Voice guidance is now on.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('es', 'voiceGuidanceEnabledConfirmation', 'La guía por voz ya está activada.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO public.translations (locale, key, value) VALUES
  ('he', 'voiceGuidanceEnabledConfirmation', 'ההדרכה הקולית פעילה כעת.')
ON CONFLICT (locale, key) DO UPDATE SET value = EXCLUDED.value;

COMMIT;
