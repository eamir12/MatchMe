# Documentation Archive

**Archived:** 28 September 2026
**Contents:** 165 point-in-time documents moved out of the repository root.

---

## Read this first

These are **historical records of work that was done**, not current documentation. Most are AI-generated fix summaries, test guides and implementation notes written on a single day about a single problem.

**They are not guaranteed to be accurate.** Several describe code that has since changed — the notification preference system was rewritten to a matrix, the matching model gained `co_motion` and retroactive matching, the match window gained per-participant extensions, and the app now ships only en/es/he. A document that was correct in April may contradict the code today.

**Verify anything here against the source before acting on it.** File names like `FINAL_`, `COMPLETE_`, `READY_` and `SUMMARY_OF_` indicate the author's belief that a task finished *at the time*. It is not a statement about the present.

Nothing was deleted. If you need something here, it is all still in the repository.

---

## Why the root was cleaned

The repository root had 174 markdown files, the oldest from December 2025. Several were actively misleading:

- `CURRENT_STATUS.md` (18 April 2026) — four months stale
- `NOTIFICATION_SETTINGS_IMPLEMENTATION.md` (February) — predates the notification matrix rewrite
- Three separate `FINAL_TEST_GUIDE.md` / `FINAL_TEST_INSTRUCTIONS.md` / `EXACT_TEST_COMMANDS.md` files
- Two different `TRANSLATION_*` audit documents describing different architectures

A new contributor opening the repository had no way to tell which were live. Current documentation now lives in the root; everything else is here.

---

## Current documentation (kept in the repository root)

| Document | Purpose |
|---|---|
| `UI_UX_RECOMMENDATIONS_INDEX.md` | **Start here.** What is settled, built, and still only a recommendation |
| `UI_UX_TEMPORAL_MODEL_AND_GREENFIELD_PLAN.md` | Authoritative: the two-lane match model, rebuild plan, priorities, build status |
| `UI_UX_DEEP_DIVE_AND_REDESIGN.md` | The 324-file code audit and design-debt measurements; visual recommendations |
| `PRIVACY_PRESERVING_DESIGN_CONSTRAINTS.md` | Verified privacy architecture, the one open storage issue, three-language enforcement |
| `APP_CONFIG_README.md` | Live reference for `app_config` |
| `APP_CONFIG_QUICK_REFERENCE.md` | Live quick reference |
| `EMAIL_SETUP_GUIDE.md` | Referenced by error text in `sensitive-action-email-code` |
| `DEPLOYMENT_CHECKLIST.md` | Referenced from build configuration |
| `ADMIN_BROADCAST_DUPLICATE_NOTIFICATION_FIX.md` | Referenced from Dart source |

---

## Archive contents

| Folder | Files | What is in here |
|---|---:|---|
| `security/` | 18 | RLS, Supabase Security Advisor remediation, security audits, auth hardening |
| `auth-passkeys/` | 18 | Passkey rollout, sign-in, session persistence, development mode |
| `offline-sync/` | 17 | Offline-first architecture, Hive caching, sync retry loops, local storage |
| `translation-i18n/` | 15 | Translation system audits, server-side setup, RTL, race conditions |
| `ads-promo/` | 10 | Ad serving standardisation, promo codes |
| `location-gps/` | 8 | Google Maps, GPS accuracy, online map, geolocation fixes |
| `matching-events/` | 8 | Matching engine, event matching, shared interests, onboarding parity |
| `ui-styling/` | 7 | Card styling, theme, section borders, style standardisation |
| `chat-messaging/` | 6 | E2E chat encryption plans and implementations, reactions |
| `setup-deploy/` | 6 | Setup guides and deployment steps (DeepL, Azure, CAPTCHA, providers) |
| `email-otp/` | 3 | Email change, OTP code validation, Resend |
| `notifications/` | 3 | Notification settings implementation, broadcast fixes |
| `calendar/` | 2 | Outlook calendar integration |
| `admin-tools/` | 1 | Admin function audit |
| `superseded-uiux/` | 1 | The 25 September UI/UX proposal, superseded |
| `fix-summaries-and-notes/` | 42 | Uncategorised one-off fix summaries, test guides, diagnostics |

---

## If you are looking for something specific

The most likely candidates, by subject:

| Subject | Where |
|---|---|
| Why a match expired / window behaviour | `../UI_UX_TEMPORAL_MODEL_AND_GREENFIELD_PLAN.md` §2 — the 24h window is **intentional** |
| Match window and extension mechanics | `chat-messaging/`, `notifications/` |
| Notification preferences | `notifications/`, `offline-sync/` — but verify against `lib/providers/user_preferences_provider.dart` |
| The matching algorithm | `matching-events/` — the engine itself is in `supabase/migrations/`, which is authoritative |
| Location and privacy | `../PRIVACY_PRESERVING_DESIGN_CONSTRAINTS.md` is current; `location-gps/` is history |
| Encrypted chat | `chat-messaging/` — verify against `lib/services/chat_key_service.dart` |
| Database schema | **Not here.** `supabase/migrations/` is the only authoritative source |
| Translations | `translation-i18n/` is history; the live keys are the `translations` table |

---

## Convention for future documents

Do not add point-in-time fix summaries to the repository root. If a change needs a document, put it in the root only if it describes **current setup, configuration, or architecture** that someone would need to work on the project. Otherwise, record the rationale in the commit message and, if it must persist, write it to `docs/` with a clear scope — not to the root.
