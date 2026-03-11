-- Note: Server-side translation is implemented via Edge Function + realtime
-- When translation is needed, the app will call the Edge Function directly
-- The trigger approach caused issues so we rely on app-triggered translation instead

-- However, we'll keep a simple trigger that marks messages as needing translation
-- This allows the background service to optionally trigger translation via Edge Function

-- For now, translations happen app-side as before
-- The difference: app will call translate-message Edge Function which saves to DB
-- This allows notifications to see translations immediately

-- This migration is here for reference, but actual translation still happens app-side
