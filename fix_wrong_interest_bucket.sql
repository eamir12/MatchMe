-- Move business-only interests from personal_interests to business_interests
-- This fixes data where entrepreneurship/skill_sharing ended up in the wrong bucket

DO $$
DECLARE
  rec record;
  v_personal jsonb;
  v_business jsonb;
  v_entrepreneurship jsonb;
  v_skill_sharing jsonb;
  v_moved_entre text;
  v_moved_skill text;
BEGIN
  FOR rec IN
    SELECT user_id, personal_interests, business_interests
    FROM public.user_profiles
    WHERE personal_interests ? 'entrepreneurship'
       OR personal_interests ? 'skill_sharing'
  LOOP
    v_personal := rec.personal_interests;
    v_business := COALESCE(rec.business_interests, '{}'::jsonb);

    v_moved_entre := '';
    v_moved_skill := '';

    -- Move entrepreneurship from personal to business
    IF v_personal ? 'entrepreneurship' THEN
      v_entrepreneurship := v_personal -> 'entrepreneurship';
      v_personal := v_personal - 'entrepreneurship';
      IF NOT v_business ? 'entrepreneurship' THEN
        v_business := jsonb_set(v_business, '{entrepreneurship}', v_entrepreneurship);
        v_moved_entre := 'entrepreneurship';
      ELSE
        -- Merge sub-interests
        v_business := jsonb_set(
          v_business,
          '{entrepreneurship}',
          (
            SELECT jsonb_agg(DISTINCT x)
            FROM (
              SELECT jsonb_array_elements_text(v_business -> 'entrepreneurship') AS x
              UNION
              SELECT jsonb_array_elements_text(v_entrepreneurship) AS x
            ) t
            WHERE x IS NOT NULL AND x <> ''
          )
        );
        v_moved_entre := 'entrepreneurship (merged)';
      END IF;
    END IF;

    -- Move skill_sharing from personal to business (if present)
    IF v_personal ? 'skill_sharing' THEN
      v_skill_sharing := v_personal -> 'skill_sharing';
      v_personal := v_personal - 'skill_sharing';
      IF NOT v_business ? 'skill_sharing' THEN
        v_business := jsonb_set(v_business, '{skill_sharing}', v_skill_sharing);
        v_moved_skill := 'skill_sharing';
      ELSE
        v_business := jsonb_set(
          v_business,
          '{skill_sharing}',
          (
            SELECT jsonb_agg(DISTINCT x)
            FROM (
              SELECT jsonb_array_elements_text(v_business -> 'skill_sharing') AS x
              UNION
              SELECT jsonb_array_elements_text(v_skill_sharing) AS x
            ) t
            WHERE x IS NOT NULL AND x <> ''
          )
        );
        v_moved_skill := 'skill_sharing (merged)';
      END IF;
    END IF;

    UPDATE public.user_profiles
    SET
      personal_interests = CASE WHEN v_personal = '{}'::jsonb THEN NULL ELSE v_personal END,
      business_interests = v_business,
      updated_at = now()
    WHERE user_id = rec.user_id;

    RAISE NOTICE 'User %: moved % %', rec.user_id, v_moved_entre, v_moved_skill;
  END LOOP;
END;
$$;
