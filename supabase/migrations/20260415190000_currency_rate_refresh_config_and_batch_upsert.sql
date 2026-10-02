INSERT INTO public.app_config (
  config_key,
  config_value,
  config_type,
  category,
  description,
  is_user_configurable,
  min_value,
  max_value
) VALUES
  (
    'billing.currency.refresh_enabled',
    'false'::jsonb,
    'boolean',
    'billing',
    'Enable scheduled backend refresh of cached currency exchange rates.',
    false,
    null,
    null
  ),
  (
    'billing.currency.refresh_interval_minutes',
    '360'::jsonb,
    'number',
    'billing',
    'Minimum minutes between successful exchange-rate refreshes.',
    false,
    15,
    1440
  ),
  (
    'billing.currency.refresh_timeout_ms',
    '15000'::jsonb,
    'number',
    'billing',
    'HTTP timeout in milliseconds for the exchange-rate provider request.',
    false,
    3000,
    60000
  ),
  (
    'billing.currency.refresh_provider',
    '"openexchangerates"'::jsonb,
    'string',
    'billing',
    'Exchange-rate provider used by the scheduled refresh job. Supported values: openexchangerates, currencyfreaks, abstractapi.',
    false,
    null,
    null
  ),
  (
    'billing.currency.refresh_base_currency',
    '"USD"'::jsonb,
    'string',
    'billing',
    'Base currency used for cached exchange rates. The current client conversion flow expects USD.',
    false,
    null,
    null
  )
ON CONFLICT (config_key) DO UPDATE
SET
  config_value = EXCLUDED.config_value,
  config_type = EXCLUDED.config_type,
  category = EXCLUDED.category,
  description = EXCLUDED.description,
  is_user_configurable = EXCLUDED.is_user_configurable,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value;

CREATE OR REPLACE FUNCTION public.upsert_currency_exchange_rates_batch(
  p_base_currency text,
  p_rates jsonb,
  p_source text DEFAULT NULL,
  p_fetched_at timestamptz DEFAULT now()
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_base_currency text := upper(btrim(COALESCE(p_base_currency, '')));
  v_source text := NULLIF(btrim(COALESCE(p_source, '')), '');
  v_fetched_at timestamptz := COALESCE(p_fetched_at, now());
  v_row record;
  v_rate numeric;
  v_count integer := 0;
BEGIN
  IF v_base_currency !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'Invalid base currency: %', p_base_currency;
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'object' THEN
    RAISE EXCEPTION 'p_rates must be a JSON object';
  END IF;

  INSERT INTO public.currency_exchange_rates (
    base_currency,
    quote_currency,
    rate,
    source,
    fetched_at
  )
  VALUES (
    v_base_currency,
    v_base_currency,
    1,
    v_source,
    v_fetched_at
  )
  ON CONFLICT (base_currency, quote_currency) DO UPDATE
  SET
    rate = EXCLUDED.rate,
    source = EXCLUDED.source,
    fetched_at = EXCLUDED.fetched_at,
    updated_at = now();

  FOR v_row IN
    SELECT key, value
    FROM jsonb_each_text(p_rates)
  LOOP
    BEGIN
      IF upper(btrim(v_row.key)) !~ '^[A-Z]{3}$' THEN
        CONTINUE;
      END IF;

      v_rate := NULLIF(btrim(v_row.value), '')::numeric;
      IF v_rate IS NULL OR v_rate <= 0 THEN
        CONTINUE;
      END IF;

      INSERT INTO public.currency_exchange_rates (
        base_currency,
        quote_currency,
        rate,
        source,
        fetched_at
      )
      VALUES (
        v_base_currency,
        upper(btrim(v_row.key)),
        v_rate,
        v_source,
        v_fetched_at
      )
      ON CONFLICT (base_currency, quote_currency) DO UPDATE
      SET
        rate = EXCLUDED.rate,
        source = EXCLUDED.source,
        fetched_at = EXCLUDED.fetched_at,
        updated_at = now();

      v_count := v_count + 1;
    EXCEPTION
      WHEN invalid_text_representation THEN
        CONTINUE;
    END;
  END LOOP;

  RETURN v_count + 1;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_currency_exchange_rates_batch(
  text,
  jsonb,
  text,
  timestamptz
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.upsert_currency_exchange_rates_batch(
  text,
  jsonb,
  text,
  timestamptz
) TO service_role;
