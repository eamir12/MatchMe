CREATE TABLE IF NOT EXISTS public.signup_fraud_signals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  user_id uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  email_hash text NOT NULL,
  platform text NOT NULL,
  device_id_hash text NULL,
  install_id_hash text NULL,
  ip_hash text NULL,
  ip_prefix_hash text NULL,
  user_agent_hash text NULL,
  device_model_hash text NULL,
  decision text NOT NULL CHECK (decision IN ('allowed', 'blocked')),
  reason_code text NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_signup_fraud_signals_created_at
ON public.signup_fraud_signals (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_signup_fraud_signals_device_id_hash
ON public.signup_fraud_signals (device_id_hash)
WHERE device_id_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_signup_fraud_signals_install_id_hash
ON public.signup_fraud_signals (install_id_hash)
WHERE install_id_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_signup_fraud_signals_ip_prefix_hash
ON public.signup_fraud_signals (ip_prefix_hash)
WHERE ip_prefix_hash IS NOT NULL;

ALTER TABLE public.signup_fraud_signals ENABLE ROW LEVEL SECURITY;
