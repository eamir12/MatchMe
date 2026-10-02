BEGIN;

GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.signup_fraud_signals
TO service_role;

DROP POLICY IF EXISTS "service_role can manage signup_fraud_signals"
ON public.signup_fraud_signals;

CREATE POLICY "service_role can manage signup_fraud_signals"
ON public.signup_fraud_signals
FOR ALL
TO service_role
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

COMMIT;
