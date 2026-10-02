ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS preferred_currency text,
  ADD COLUMN IF NOT EXISTS recent_currencies text[] NOT NULL DEFAULT '{}'::text[];

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'users_preferred_currency_format_check'
  ) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_preferred_currency_format_check
      CHECK (
        preferred_currency IS NULL
        OR preferred_currency ~ '^[A-Z]{3}$'
      );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.is_valid_currency_code_array(p_codes text[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    p_codes IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM unnest(p_codes) AS item
      WHERE item IS NULL
         OR item !~ '^[A-Z]{3}$'
    );
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'users_recent_currencies_format_check'
  ) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_recent_currencies_format_check
      CHECK (public.is_valid_currency_code_array(recent_currencies));
  END IF;
END $$;

UPDATE public.users
SET recent_currencies = '{}'::text[]
WHERE recent_currencies IS NULL;

CREATE TABLE IF NOT EXISTS public.currency_exchange_rates (
  base_currency text NOT NULL,
  quote_currency text NOT NULL,
  rate numeric(20, 8) NOT NULL CHECK (rate > 0),
  source text,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (base_currency, quote_currency),
  CONSTRAINT currency_exchange_rates_base_code_check
    CHECK (base_currency ~ '^[A-Z]{3}$'),
  CONSTRAINT currency_exchange_rates_quote_code_check
    CHECK (quote_currency ~ '^[A-Z]{3}$')
);

ALTER TABLE public.currency_exchange_rates ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'currency_exchange_rates'
      AND policyname = 'currency_exchange_rates_select_authenticated'
  ) THEN
    CREATE POLICY currency_exchange_rates_select_authenticated
      ON public.currency_exchange_rates
      FOR SELECT
      TO authenticated
      USING (true);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS currency_exchange_rates_base_currency_idx
  ON public.currency_exchange_rates (base_currency, fetched_at DESC);

CREATE OR REPLACE FUNCTION public.set_currency_exchange_rates_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS currency_exchange_rates_set_updated_at
  ON public.currency_exchange_rates;

CREATE TRIGGER currency_exchange_rates_set_updated_at
BEFORE UPDATE ON public.currency_exchange_rates
FOR EACH ROW
EXECUTE FUNCTION public.set_currency_exchange_rates_updated_at();

CREATE OR REPLACE FUNCTION public.upsert_currency_exchange_rate(
  p_base_currency text,
  p_quote_currency text,
  p_rate numeric,
  p_source text DEFAULT NULL,
  p_fetched_at timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.currency_exchange_rates (
    base_currency,
    quote_currency,
    rate,
    source,
    fetched_at
  )
  VALUES (
    upper(btrim(p_base_currency)),
    upper(btrim(p_quote_currency)),
    p_rate,
    NULLIF(btrim(COALESCE(p_source, '')), ''),
    COALESCE(p_fetched_at, now())
  )
  ON CONFLICT (base_currency, quote_currency) DO UPDATE
  SET
    rate = EXCLUDED.rate,
    source = EXCLUDED.source,
    fetched_at = EXCLUDED.fetched_at,
    updated_at = now();
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_currency_exchange_rate(
  text,
  text,
  numeric,
  text,
  timestamptz
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.upsert_currency_exchange_rate(
  text,
  text,
  numeric,
  text,
  timestamptz
) TO service_role;
