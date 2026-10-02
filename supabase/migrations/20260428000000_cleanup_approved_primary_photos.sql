-- Clean up approved_primary_photos to only include photos that exist in the photos array
-- This fixes data inconsistencies where approved_primary_photos contains photos not in photos

BEGIN;

-- Function to clean up approved_primary_photos for a single user
CREATE OR REPLACE FUNCTION public.cleanup_user_approved_primary_photos(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_photos jsonb;
  v_approved jsonb;
  v_cleaned jsonb;
BEGIN
  SELECT photos, COALESCE(approved_primary_photos, '[]'::jsonb)
  INTO v_photos, v_approved
  FROM public.users
  WHERE id = p_user_id;

  IF v_photos IS NULL OR v_photos = '{}'::jsonb THEN
    -- If no photos, clear approved_primary_photos
    UPDATE public.users
    SET approved_primary_photos = '[]'::jsonb
    WHERE id = p_user_id;
    RETURN;
  END IF;

  -- Filter approved_primary_photos to only include photos that exist in photos
  SELECT jsonb_agg(elem)
  INTO v_cleaned
  FROM jsonb_array_elements(v_approved) elem
  WHERE v_photos @> jsonb_build_array(elem);

  IF v_cleaned IS NULL THEN
    v_cleaned := '[]'::jsonb;
  END IF;

  UPDATE public.users
  SET approved_primary_photos = v_cleaned
  WHERE id = p_user_id;
END;
$$;

-- Apply the cleanup to all users with inconsistent data
DO $$
DECLARE
  user_record RECORD;
BEGIN
  FOR user_record IN 
    SELECT id 
    FROM public.users 
    WHERE approved_primary_photos IS NOT NULL 
      AND approved_primary_photos != '[]'::jsonb
  LOOP
    PERFORM public.cleanup_user_approved_primary_photos(user_record.id);
  END LOOP;
END $$;

-- Drop the temporary function
DROP FUNCTION IF EXISTS public.cleanup_user_approved_primary_photos(uuid);

COMMIT;
