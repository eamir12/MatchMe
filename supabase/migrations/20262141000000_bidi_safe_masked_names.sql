-- Migration: make masked display names bidi-safe.
--
-- A masked name ends in a period ("John S."). A period is a neutral
-- character: inside a right-to-left paragraph it resolves to the paragraph
-- direction and lands on the wrong side of the name, so an English name in a
-- Hebrew UI reads "S. John" instead of "John S.". Every notification the
-- database builds (new match, match extension, ...) glues a masked name onto
-- a sentence, so the name is marked here with the direction of its own
-- script and the period stays glued to the initial in every tray title,
-- inbox row and notification body.
--
-- The marks are invisible formatting characters (U+200E / U+200F). The client
-- strips them before masking a name again (see lib/utils/string_extensions.dart)
-- and renders the name in its own script (see displayTextLayout), so nothing
-- user-visible changes except the side the period sits on.
--
-- CREATE OR REPLACE FUNCTION is idempotent.

BEGIN;

CREATE OR REPLACE FUNCTION public.mask_full_name(full_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  parts TEXT[];
  first_part TEXT;
  last_part TEXT;
  masked TEXT;
  rtl BOOLEAN;
BEGIN
  -- Drop the bidi controls a previous call may have added, so re-masking an
  -- already-masked name ("John S.") returns it unchanged.
  full_name := translate(
    full_name,
    chr(8206) || chr(8207) || chr(8234) || chr(8235) || chr(8236) ||
      chr(8237) || chr(8238) || chr(8294) || chr(8295) || chr(8296) || chr(8297),
    ''
  );

  IF full_name IS NULL OR trim(full_name) = '' THEN
    RETURN 'Unknown User';
  END IF;

  parts := regexp_split_to_array(trim(full_name), '\s+');
  first_part := parts[1];

  IF array_length(parts, 1) > 1 THEN
    last_part := parts[array_length(parts, 1)];
    IF last_part IS NOT NULL AND last_part <> first_part THEN
      masked := first_part || ' ' || upper(left(last_part, 1)) || '.';
    ELSE
      masked := first_part;
    END IF;
  ELSE
    masked := first_part;
  END IF;

  -- The script of the name decides the mark: a Latin name gets the
  -- left-to-right mark, a Hebrew/Arabic name the right-to-left one.
  -- The class is built from chr() so it does not depend on the regex
  -- flavour: Hebrew (U+0590-U+05FF) and Arabic (U+0600-U+06FF).
  rtl := (first_part ~
    ('[' || chr(1424) || '-' || chr(1535) || chr(1536) || '-' || chr(1799) || ']'));

  IF rtl THEN
    RETURN chr(8207) || masked || chr(8207);
  END IF;
  RETURN chr(8206) || masked || chr(8206);
END;
$$;

GRANT EXECUTE ON FUNCTION public.mask_full_name(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mask_full_name(TEXT) TO anon;

COMMIT;
