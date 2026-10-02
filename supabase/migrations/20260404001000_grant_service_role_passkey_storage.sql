GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.passkey_challenges
TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.passkey_credentials
TO service_role;

DROP POLICY IF EXISTS "service_role can manage passkey_challenges"
ON public.passkey_challenges;

CREATE POLICY "service_role can manage passkey_challenges"
ON public.passkey_challenges
FOR ALL
TO service_role
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

DROP POLICY IF EXISTS "service_role can manage passkey_credentials"
ON public.passkey_credentials;

CREATE POLICY "service_role can manage passkey_credentials"
ON public.passkey_credentials
FOR ALL
TO service_role
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');
