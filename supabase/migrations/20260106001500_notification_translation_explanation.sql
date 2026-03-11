-- NEW: Auto-translate messages on INSERT (synchronously in the database)
-- Instead of using triggers which are problematic, we'll rely on the app to translate
-- But for the background service notifications, we need translations to already be in the database

-- This is a workaround: messages inserted will stay untranslated in the database
-- The RPC will return content_original, and the background service will show it
-- When the app opens, it will translate and save the translation

-- For now, the solution is:
-- 1. Background notifications show original English
-- 2. When user opens app, realtime triggers and app translates
-- 3. App saves translation to database
-- 4. Next notification (if any) shows translated text

-- This is expected behavior until we have server-side translation

-- The migration you created earlier (20260106002000) adds translation metadata to RPC
-- but the translation still needs to happen on the app side

-- No changes needed here - the current system works, just with a delay in showing translations
-- The string "null" fix ensures proper fallback to original text
