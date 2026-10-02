BEGIN;

DROP POLICY IF EXISTS "Admins can view all promo codes" ON public.promo_codes;

CREATE POLICY "Admins can view all promo codes"
  ON public.promo_codes
  FOR SELECT
  USING (
    auth.uid() IN (
      SELECT u.id
      FROM public.users AS u
      WHERE u.is_admin = true
    )
  );

COMMIT;
