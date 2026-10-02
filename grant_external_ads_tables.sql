-- ============================================================================
-- Grant permissions on external ads tables
-- ============================================================================

-- Grant all on ad_networks table
GRANT ALL ON TABLE public.ad_networks TO authenticated;
GRANT ALL ON TABLE public.ad_networks TO anon;

-- Grant all on ad_revenue_events table
GRANT ALL ON TABLE public.ad_revenue_events TO authenticated;
GRANT ALL ON TABLE public.ad_revenue_events TO anon;

-- Also check and grant on any other external_ad related tables
DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOR tbl IN 
    SELECT table_name::text FROM information_schema.tables 
    WHERE table_schema = 'public' 
    AND table_name LIKE '%ad%' OR table_name LIKE '%external%'
  LOOP
    EXECUTE format('GRANT ALL ON TABLE public.%I TO authenticated', tbl);
    EXECUTE format('GRANT ALL ON TABLE public.%I TO anon', tbl);
    RAISE NOTICE 'Granted: %', tbl;
  END LOOP;
END $$;

-- Verify
SELECT table_name FROM information_schema.tables 
WHERE table_schema = 'public' 
AND (table_name LIKE '%ad%' OR table_name LIKE '%external%')
AND table_type = 'BASE TABLE';