-- Enable realtime on tables the MatchMe app needs to react to admin changes.
-- User verification, subscription tiers/plans, intents/interests, and translations.

BEGIN;

-- Users table: needed for verification status, is_verified changes
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'users'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.users;
  END IF;
END $$;

-- Subscription tiers/plans: needed for live price/feature changes
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'subscription_tiers'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.subscription_tiers;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'subscription_plans'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.subscription_plans;
  END IF;
END $$;

-- Intents & interests: needed for live option changes
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'intents'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.intents;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'interests'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.interests;
  END IF;
END $$;

-- Translations: needed for live text changes
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'translations'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.translations;
  END IF;
END $$;

-- Ad campaigns & creatives: needed for live ad changes
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'ad_campaigns'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ad_campaigns;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'ad_creatives'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ad_creatives;
  END IF;
END $$;

COMMIT;
