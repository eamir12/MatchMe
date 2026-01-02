-- Migration: Create mask_full_name function
-- Returns first name and last initial (e.g. "Jane S.") or just first name when no last name available

CREATE OR REPLACE FUNCTION public.mask_full_name(full_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  parts TEXT[];
  first_part TEXT;
  last_part TEXT;
BEGIN
  IF full_name IS NULL OR trim(full_name) = '' THEN
    RETURN 'Unknown User';
  END IF;

  parts := regexp_split_to_array(trim(full_name), '\s+');
  first_part := parts[1];

  IF array_length(parts, 1) > 1 THEN
    last_part := parts[array_length(parts, 1)];
    IF last_part IS NOT NULL AND last_part <> first_part THEN
      RETURN first_part || ' ' || upper(left(last_part, 1)) || '.';
    END IF;
  END IF;

  RETURN first_part;
END;
$$;

-- Grant execute to authenticated and anon so functions and RPCs can call it when appropriate
GRANT EXECUTE ON FUNCTION public.mask_full_name(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mask_full_name(TEXT) TO anon;
