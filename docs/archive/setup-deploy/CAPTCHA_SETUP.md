# CAPTCHA Setup

This app now uses Cloudflare Turnstile for:

- Account registration
- Password login after 3 failed password attempts for the same email on the device

## App config

Set the Turnstile site key in `assets/.env` or via `--dart-define`:

```env
TURNSTILE_SITE_KEY=your_turnstile_site_key
```

## Server config

Set the secret as a Supabase Edge Function secret:

```bash
supabase secrets set TURNSTILE_SECRET_KEY=your_turnstile_secret_key
```

For local development with Cloudflare's current Turnstile test keys:

```bash
supabase secrets set TURNSTILE_SECRET_KEY=1x0000000000000000000000000000000AA
```

Deploy the verifier function:

```bash
supabase functions deploy verify-turnstile
```

## Notes

- Signup always requires a CAPTCHA.
- Password login starts requiring a CAPTCHA after 3 failed attempts for the same email on that device.
- A successful password login resets the local failed-attempt counter for that email.
- Keep Supabase Auth CAPTCHA disabled for password auth, otherwise Supabase will require a CAPTCHA on every password login attempt.
