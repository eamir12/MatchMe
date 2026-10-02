# Currency Rate Refresh Setup

This project refreshes cached exchange rates inside `supabase/functions/cron-jobs/index.ts`.

## Provider Secrets

Choose one provider in `app_config`, then set the matching Edge Function secret(s).

### Open Exchange Rates

Required:

- `OPENEXCHANGERATES_APP_ID`

Optional:

- `OPENEXCHANGERATES_BASE_URL`
  - Default: `https://openexchangerates.org/api/`

### CurrencyFreaks

Required:

- `CURRENCYFREAKS_API_KEY`

Optional:

- `CURRENCYFREAKS_BASE_URL`
  - Default: `https://api.currencyfreaks.com/v2.0/`

### AbstractAPI

Required:

- `ABSTRACTAPI_API_KEY`

Optional:

- `ABSTRACTAPI_EXCHANGE_RATES_URL`
  - Default: `https://exchange-rates.abstractapi.com/v1/live/`

## Default Runtime Config

The migration `20260415190000_currency_rate_refresh_config_and_batch_upsert.sql`
adds these `app_config` keys:

- `billing.currency.refresh_enabled`
- `billing.currency.refresh_interval_minutes`
- `billing.currency.refresh_timeout_ms`
- `billing.currency.refresh_provider`
- `billing.currency.refresh_base_currency`

## Enable It

After the provider secret is set, choose the provider and enable the job with:

```sql
UPDATE public.app_config
SET config_value = '"openexchangerates"'::jsonb
WHERE config_key = 'billing.currency.refresh_provider';

UPDATE public.app_config
SET config_value = 'true'::jsonb
WHERE config_key = 'billing.currency.refresh_enabled';
```

Supported provider values:

- `openexchangerates`
- `currencyfreaks`
- `abstractapi`

## Optional Tuning

Example: refresh every 3 hours with a 15 second timeout.

```sql
UPDATE public.app_config
SET config_value = '180'::jsonb
WHERE config_key = 'billing.currency.refresh_interval_minutes';

UPDATE public.app_config
SET config_value = '15000'::jsonb
WHERE config_key = 'billing.currency.refresh_timeout_ms';
```

## Notes

- The current client conversion flow expects `USD` as the cached base currency.
- The scheduler supports `Open Exchange Rates`, `CurrencyFreaks`, and `AbstractAPI`.
- The cron task skips refresh when disabled, when the provider secret is missing, or when rates are still fresh enough.
- Rates are bulk-upserted through `public.upsert_currency_exchange_rates_batch(...)`.
