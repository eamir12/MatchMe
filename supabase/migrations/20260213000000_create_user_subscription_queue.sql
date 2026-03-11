BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'subscription_tier'
  ) THEN
    ALTER TABLE public.users ADD COLUMN subscription_tier TEXT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'subscription_expires_at'
  ) THEN
    ALTER TABLE public.users ADD COLUMN subscription_expires_at TIMESTAMPTZ;
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS public.user_subscription_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  tier varchar(50) NOT NULL,
  status varchar(20) NOT NULL DEFAULT 'pending',
  starts_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  payment_provider varchar(20),
  transaction_id text,
  purchase_metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  activated_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text
);

CREATE INDEX IF NOT EXISTS idx_user_subscription_queue_user_id ON public.user_subscription_queue(user_id);
CREATE INDEX IF NOT EXISTS idx_user_subscription_queue_status ON public.user_subscription_queue(status);
CREATE INDEX IF NOT EXISTS idx_user_subscription_queue_starts_at ON public.user_subscription_queue(starts_at);
CREATE INDEX IF NOT EXISTS idx_user_subscription_queue_expires_at ON public.user_subscription_queue(expires_at);
CREATE INDEX IF NOT EXISTS idx_user_subscription_queue_user_status ON public.user_subscription_queue(user_id, status);

ALTER TABLE public.user_subscription_queue ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own subscription queue" ON public.user_subscription_queue;
CREATE POLICY "Users can view their own subscription queue"
  ON public.user_subscription_queue
  FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert their own subscription queue entries" ON public.user_subscription_queue;
CREATE POLICY "Users can insert their own subscription queue entries"
  ON public.user_subscription_queue
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION public.normalize_user_subscription_queue(p_user_id uuid DEFAULT auth.uid())
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_now timestamptz := now();
  v_current_tier text;
  v_current_expires_at timestamptz;
  v_next record;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  IF v_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  UPDATE public.user_subscription_queue
  SET status = 'completed',
      updated_at = v_now
  WHERE user_id = v_user_id
    AND status = 'active'
    AND expires_at <= v_now;

  SELECT u.subscription_tier, u.subscription_expires_at
  INTO v_current_tier, v_current_expires_at
  FROM public.users u
  WHERE u.id = v_user_id
  FOR UPDATE;

  IF v_current_tier IS NULL OR btrim(v_current_tier) = '' THEN
    v_current_tier := 'free';
  END IF;

  IF v_current_tier <> 'free'
     AND v_current_expires_at IS NOT NULL
     AND v_current_expires_at > v_now THEN
    RETURN;
  END IF;

  SELECT sq.*
  INTO v_next
  FROM public.user_subscription_queue sq
  WHERE sq.user_id = v_user_id
    AND sq.status = 'pending'
    AND sq.starts_at <= v_now
  ORDER BY sq.starts_at ASC
  LIMIT 1;

  IF FOUND THEN
    UPDATE public.user_subscription_queue
    SET status = 'active',
        activated_at = COALESCE(activated_at, v_now),
        updated_at = v_now
    WHERE id = v_next.id;

    UPDATE public.users
    SET subscription_tier = v_next.tier,
        subscription_expires_at = v_next.expires_at,
        updated_at = v_now
    WHERE id = v_user_id;
  ELSE
    UPDATE public.users
    SET subscription_tier = 'free',
        subscription_expires_at = NULL,
        updated_at = v_now
    WHERE id = v_user_id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.add_subscription_to_queue(
  p_user_id uuid,
  p_tier varchar,
  p_duration_seconds integer,
  p_payment_provider varchar DEFAULT 'manual',
  p_transaction_id text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  queue_entry_id uuid,
  starts_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_starts_at timestamptz;
  v_expires_at timestamptz;
  v_current_expires_at timestamptz;
  v_last_queued_expires_at timestamptz;
  v_queue_id uuid;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'missing user_id';
  END IF;

  IF v_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_user_id::text));

  PERFORM public.normalize_user_subscription_queue(v_user_id);

  SELECT u.subscription_expires_at
  INTO v_current_expires_at
  FROM public.users u
  WHERE u.id = v_user_id;

  SELECT MAX(sq.expires_at)
  INTO v_last_queued_expires_at
  FROM public.user_subscription_queue sq
  WHERE sq.user_id = v_user_id
    AND sq.status IN ('pending', 'active')
    AND sq.expires_at > now();

  v_starts_at := now();
  IF v_current_expires_at IS NOT NULL AND v_current_expires_at > v_starts_at THEN
    v_starts_at := v_current_expires_at;
  END IF;
  IF v_last_queued_expires_at IS NOT NULL AND v_last_queued_expires_at > v_starts_at THEN
    v_starts_at := v_last_queued_expires_at;
  END IF;

  v_expires_at := v_starts_at + (GREATEST(COALESCE(p_duration_seconds, 0), 0) || ' seconds')::interval;

  INSERT INTO public.user_subscription_queue (
    user_id,
    tier,
    status,
    starts_at,
    expires_at,
    payment_provider,
    transaction_id,
    purchase_metadata,
    created_at,
    updated_at
  ) VALUES (
    v_user_id,
    p_tier,
    'pending',
    v_starts_at,
    v_expires_at,
    p_payment_provider,
    p_transaction_id,
    COALESCE(p_metadata, '{}'::jsonb),
    now(),
    now()
  )
  RETURNING id INTO v_queue_id;

  PERFORM public.normalize_user_subscription_queue(v_user_id);

  RETURN QUERY SELECT v_queue_id, v_starts_at, v_expires_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_next_queued_subscription(p_user_id uuid DEFAULT auth.uid())
RETURNS TABLE (
  queue_id uuid,
  tier varchar,
  starts_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  IF v_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN QUERY
  SELECT sq.id, sq.tier, sq.starts_at, sq.expires_at
  FROM public.user_subscription_queue sq
  WHERE sq.user_id = v_user_id
    AND sq.status = 'pending'
    AND sq.starts_at > now()
  ORDER BY sq.starts_at ASC
  LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_queued_subscription(
  p_queue_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  SELECT user_id INTO v_user_id
  FROM public.user_subscription_queue
  WHERE id = p_queue_id;

  IF v_user_id IS NULL THEN
    RETURN FALSE;
  END IF;

  IF v_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  UPDATE public.user_subscription_queue
  SET status = 'cancelled',
      cancelled_at = now(),
      cancellation_reason = p_reason,
      updated_at = now()
  WHERE id = p_queue_id
    AND status = 'pending';

  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_subscription_timeline(p_user_id uuid DEFAULT auth.uid())
RETURNS TABLE (
  entry_type varchar,
  tier varchar,
  status varchar,
  starts_at timestamptz,
  expires_at timestamptz,
  payment_provider varchar
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_current_tier text;
  v_current_expires_at timestamptz;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  IF v_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  SELECT subscription_tier, subscription_expires_at
  INTO v_current_tier, v_current_expires_at
  FROM public.users
  WHERE id = v_user_id;

  IF v_current_tier IS NOT NULL AND v_current_tier <> 'free' AND v_current_expires_at IS NOT NULL THEN
    RETURN QUERY
    SELECT
      'current'::varchar,
      v_current_tier::varchar,
      'active'::varchar,
      now()::timestamptz,
      v_current_expires_at::timestamptz,
      NULL::varchar;
  END IF;

  RETURN QUERY
  SELECT
    'queued'::varchar,
    sq.tier,
    sq.status,
    sq.starts_at,
    sq.expires_at,
    sq.payment_provider
  FROM public.user_subscription_queue sq
  WHERE sq.user_id = v_user_id
    AND sq.status IN ('pending', 'active')
  ORDER BY sq.starts_at ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_and_normalize_user_subscription(p_user_id uuid DEFAULT auth.uid())
RETURNS TABLE (
  previous_tier varchar,
  new_tier varchar,
  normalized boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_before text;
  v_after text;
  v_before_exp timestamptz;
  v_after_exp timestamptz;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  IF v_user_id IS DISTINCT FROM auth.uid()
     AND COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  SELECT subscription_tier, subscription_expires_at
  INTO v_before, v_before_exp
  FROM public.users
  WHERE id = v_user_id;

  PERFORM public.normalize_user_subscription_queue(v_user_id);

  SELECT subscription_tier, subscription_expires_at
  INTO v_after, v_after_exp
  FROM public.users
  WHERE id = v_user_id;

  RETURN QUERY SELECT
    v_before::varchar,
    v_after::varchar,
    (v_before IS DISTINCT FROM v_after) OR (v_before_exp IS DISTINCT FROM v_after_exp);
END;
$$;

CREATE OR REPLACE FUNCTION public.trigger_subscription_normalization()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT u.id AS user_id
    FROM public.users u
    LEFT JOIN public.user_subscription_queue sq
      ON sq.user_id = u.id
      AND sq.status = 'pending'
      AND sq.starts_at <= now()
    WHERE (u.subscription_tier IS NOT NULL AND u.subscription_tier <> 'free' AND u.subscription_expires_at IS NOT NULL AND u.subscription_expires_at <= now())
       OR sq.id IS NOT NULL
  LOOP
    PERFORM public.normalize_user_subscription_queue(r.user_id);
  END LOOP;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE OR REPLACE FUNCTION public.scheduled_subscription_normalization()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.trigger_subscription_normalization();
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'subscription-normalization') THEN
      PERFORM cron.schedule(
        'subscription-normalization',
        '*/5 * * * *',
        'SELECT public.scheduled_subscription_normalization()'
      );
    END IF;
  END IF;
END$$;

GRANT EXECUTE ON FUNCTION public.add_subscription_to_queue(uuid, varchar, integer, varchar, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_next_queued_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_queued_subscription(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_subscription_timeline(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_and_normalize_user_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_user_subscription_queue(uuid) TO authenticated;

COMMIT;

