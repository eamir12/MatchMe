# Windows WNS push notifications (MSIX + Supabase)

Windows desktop clients receive chat/pinned/admin pushes through **WNS**
(Windows Push Notification Service) with the same "delivered while the app is
closed" guarantee Android/iOS get from FCM/APNs. This works end-to-end once the
app is packaged as **MSIX with package identity**, because
`PushNotificationChannelManager` refuses to mint channel URIs for unpackaged
processes.

```
MSIX client (Windows)                      Supabase
─────────────────────                      ────────
createPushChannel ──► WNS channel URI
        │
        └─► SharedPreferences('wns_channel_uri')
                │ next session upsert (registerSession → upsert_user_session)
                ▼
        user_session(platform='windows').metadata.wns_channel_uri
                                                     │
 push-message / cron-jobs ── ERP (FCM) ──────────────┤
        └── sendWnsToast(_shared/wns.ts) ◄───────────┘
              POST https://<pod>.notify.windows.com/...
                │
                ▼
        Windows Action Center toast (launch=matchme://chat/<matchId>)
                │ click / cold start
                ▼
        runner command line ── getInitialLaunchPayload ──► _processDeepLink
```

## Components

| Piece | File | Notes |
| --- | --- | --- |
| WNS transport | `supabase/functions/_shared/wns.ts` | Entra token grant (client credentials, cached in `wns_token_cache`, ~24h TTL) + toast XML + `X-WNS-SuppressPopup` silent mode + 401 one-shot retry + `expired` on 410. |
| Direct sends | `supabase/functions/push-message/index.ts` | All four send sites dispatch FCM **and** WNS (match, translated_message, message retraction, legacy web-hook). |
| Queue retries | `supabase/functions/cron-jobs/index.ts` | Drainer discriminates rows by `isWnsChannelUri`; 410 → prune via RPC. Chat/expiry harvests enqueue WNS rows with `platform='windows'`. |
| Session storage | `supabase/migrations/20262132000000_wns_push_channel_support.sql` | `wns_token_cache` table, `clear_user_session_wns_channel` RPC, `upsert_user_session` supersession (sanitize + cross-user channel steal). |
| Native channel | `windows/runner/push_channel.{h,cpp}` | Method channel `matchme/windows_push`: `createPushChannel` (8s native timeout) and `getInitialLaunchPayload` (command-line `matchme://` URI). Registered in `flutter_window.cpp` next to `LocationChannel`. |
| Dart service | `lib/services/windows_push_channel_service.dart` | Caches the URI, exposes `ensureChannel()` / `getInitialLaunchPayload()`. Marks `NOT_AVAILABLE` as terminal for the process (unpackaged dev builds). |
| Session wiring | `lib/services/session_service.dart` | `collectSessionInfo` attaches `wns_channel_uri` + `wns_channel_uri_updated_at` for `platformText == 'windows'`; `clearLocalWnsChannel` for logout/account delete. |
| Bootstrap hook | `lib/main.dart` | `_registerWindowsWnsChannel()` (fire-and-forget, after Supabase init) and Windows cold-start URI feeding `_processDeepLink`. |
| Packaging | `pubspec.yaml` (`msix_config`) | Add `msix` dev dependency; `identity_name`/`publisher` must match Partner Center. |

## Avatar and duplicate-delivery limits

WNS currently sends text-only toast XML. A WNS-delivered toast cannot read the
device-local avatar cache, and adding a remotely fetchable photo URL would
violate the app's local-cache-only privacy policy. Windows local notifications
can include a cached avatar while the app is running, but WNS and local toasts
do not share a notification identity, so simultaneous delivery can still leave
two entries. WNS `tag`/`group` collapses retries of the same remote toast only;
it is not an exactly-once guarantee.

## What must happen outside this repo (prerequisites)

### Partner Center (done — MatchMeApp product created)

Product identity recorded (Partner Center → Apps and games → MatchMeApp →
Product management → Product identity):

| Partner Center value | Where it went |
| --- | --- |
| Package/Identity/Name `EAmir.MatchMeApp` | `pubspec.yaml` → `msix_config.identity_name` |
| Package/Identity/Publisher `CN=D489A069-197E-4A4C-A149-FCF350D3685A` | `pubspec.yaml` → `msix_config.publisher` |
| PublisherDisplayName `EAmir` | `pubspec.yaml` → `msix_config.publisher_display_name` |
| PFN `EAmir.MatchMeApp_580403ahehwbc` | (informational; implied AUMID `EAmir.MatchMeApp!App`; becomes the subject of the PFN→AppId mapping email, below) |
| Package SID `S-1-15-2-2753874336-4176348852-3817874931-2202969770-2275579429-1616534927-2925576800` | (informational — the legacy Package-SID token flow is dead for newly-provisioned products; grouping now happens through the PFN→AppId mapping instead) |
| Store ID `9NBFKPSQV6FZ` | (informational) |

The Windows local-toast AUMID in `lib/services/mobile_local_notification_service.dart`
was updated to `EAmir.MatchMeApp!App` to match the packaged identity; keep it in
sync if the package identity ever changes.

### Remaining Microsoft steps

> **2026-10-19 status recap.** The Partner Center "Push notifications →
> App Registration portal" flow proved unusable for new products: it provisions
> an MSA-shadow registration (lives outside your tenant, Authentication blade
> fails to load, audience locked to "Personal Microsoft account users"), which
> cannot mint client-credential tokens — `login.live.com/accesstoken.srf`
> rejects new clients ("no longer supported") and the WNS resource app rejects
> the `/consumers` authority (`AADSTS9002332`). The WNS sends therefore pair
> through the **Windows App SDK push identity model**: a normal multi-tenant
> Entra registration + its service principal + an emailed PFN→AppId mapping.
> (Official doc: *"We do NOT support using Windows App SDK push notifications
> with Microsoft Partner Center"*, `apps/develop/notifications/push-notifications/
> push-quickstart.md`.)

1. **Entra app registration.** Reuse the app the Microsoft login already uses
   ("MatchMe", audience "All Microsoft account users" — org-capable, which is
   what the WNS resource requires). Do **not** create a Partner-Center-style
   MSA registration; it cannot authenticate.
   - **Application (client) ID** `3f5aa18f-ec86-4602-9f2a-d6841ce63166` →
     Supabase secret `WNS_CLIENT_ID`
   - **Directory (tenant) ID** `9504b7bf-a721-4f33-ab3a-c6f868a423ed` →
     Supabase secret `WNS_TENANT_ID`
   - Client secret Value → Supabase secret `WNS_CLIENT_SECRET` (shown once;
     rotate on a schedule)
2. **Service principal + `wns.connect` authorization** (Graph PowerShell,
   tenant admin): create the SP for the WNS resource
   `04436913-cf0d-4d2a-9cc6-2ffe7f1d3d1c` ("Windows Notification Service"),
   then assign its `wns.connect` app role
   (`2b0781fd-fd34-4a97-a950-a510bf11993e`) to the app's own SP:
   ```powershell
   Connect-MgGraph -TenantId "<tenant guid>" -Scopes "Application.ReadWrite.All"
   $wns = New-MgServicePrincipal -AppId "04436913-cf0d-4d2a-9cc6-2ffe7f1d3d1c"
   $me  = New-MgServicePrincipal -AppId "3f5aa18f-ec86-4602-9f2a-d6841ce63166"
   New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $me.Id -PrincipalId $me.Id `
     -ResourceId $wns.Id -AppRoleId "2b0781fd-fd34-4a97-a950-a510bf11993e"
   ```
   Missing pieces surface as: no resource SP → `AADSTS700016` at grant; no
   `wns.connect` → WNS `403` (empty body, empty `X-WNS-NotificationStatus`).
3. **PFN→AppId/SP-ObjectId mapping** — the step that fixed the remaining `403`
   *"token does not match the credentials of the app that requested the
   channel"*. There is no portal UI: email **Win_App_SDK_Push@microsoft.com**,
   subject `Windows App SDK Push Notifications Mapping Request`, body:
   ```
   PFN: EAmir.MatchMeApp_580403ahehwbc
   AppId: 3f5aa18f-ec86-4602-9f2a-d6841ce63166
   ObjectId: c14b002b-bc61-4a98-93d4-4b58e78f33a2   # Id of the Step-2 SP (Get-MgServicePrincipal)
   ```
   Processed on a **weekly batch**; Microsoft replies when completed. Until it
   lands, every send returns `403` with empty body/headers. Old tokens stay
   valid — no cache flush is required after the mapping (no claims change).
4. **Supabase secrets (final values):**
   ```
   supabase secrets set WNS_CLIENT_ID="3f5aa18f-ec86-4602-9f2a-d6841ce63166"
   supabase secrets set WNS_TENANT_ID="9504b7bf-a721-4f33-ab3a-c6f868a423ed"
   supabase secrets set WNS_CLIENT_SECRET=<Client secret value>
   ```
   (`_shared/wns.ts` uses `login.microsoftonline.com/{WNS_TENANT_ID}/oauth2/v2.0/token`
   with `scope=https://wns.windows.com/.default`; the legacy Package-SID /
   login.live.com flow remains implemented for old-style clients.) Wrong
   values surface as `[wns] token grant failed status=… body=…` in function
   logs. `AbortSignal.timeout` in `sendWnsToast` is milliseconds — don't
   pass small values.
5. Deploy the changes:
   ```
   supabase db push                      # 20262132000000_wns_push_channel_support.sql
   supabase functions deploy push-message
   supabase functions deploy cron-jobs
   ```
4. MSIX build + signing. For Store distribution the identity in
   `msix_config` already matches; for **sideload/direct installs** the signing
   cert subject must equal `CN=D489A069-197E-4A4C-A149-FCF350D3685A` (the
   manifest Publisher). Self-signed dev cert for local testing:
   ```powershell
   $pwd = ConvertTo-SecureString -String "<password>" -Force -AsPlainText
   $cert = New-SelfSignedCertificate -Type Custom `
     -Subject "CN=D489A069-197E-4A4C-A149-FCF350D3685A" `
     -KeyUsage DigitalSignature -FriendlyName "MatchMe dev" `
     -CertStoreLocation "Cert:\CurrentUser\My" -NotAfter (Get-Date).AddYears(1)
   $cert | Export-PfxCertificate -FilePath .\matchme-dev.pfx -Password $pwd
   ```
   Then build + install:
   ```
   dart run msix:create --certificate-path .\matchme-dev.pfx --certificate-password <password> --install-certificate
   ```
   The generated package declares the `matchme://` protocol activation,
   so toast clicks cold-start the exe with the URI on the command line.
   For Store distribution, submit the built MSIX in Partner Center instead —
   Microsoft signs it and per-user/SID service validation stays intact.

## Runtime behavior details

* **Channel refresh**: the client requests a fresh channel on **every app
  start** (cheap ~100 ms call, WNS rotates URIs). The server prunes missing
  channels when the dispatcher observes 410 (`clear_user_session_wns_channel`)
  and the upsert "steals" a channel registered by another user, mirroring the
  existing FCM token rules.
* **Silent vs alerting**: WNS toasts mirror the FCM decision computed at the
  send site — alert pushes raise a banner; silent ones are sent with
  `X-WNS-SuppressPopup: true` so they only appear in Action Center.
* **Collapse**: toast `tag=match_<matchId>` + `group=matchme` replicates the
  FCM `collapseKey`/notification-tag stacking behavior (unreads collapse per
  match, retractions replace reasons silently).
* **Routing**: the toast `launch` attribute is `matchme://chat/<matchId>`.
  Clicking it (or cold-starting from a click) reaches `_processDeepLink`
  exactly like an app_links deep link on mobile.
* **Queue retries**: WNS rows reuse the `fcm_token` column for the channel URI
  with `platform='windows'`; the drainer's discrimination is `https://` +
  `.notify.windows.com`, so nothing else in the queue needs to change.

## Known deltas (by design, not bugs)

* **Retraction toast** uses the neutral placeholder title `MatchMe` / body `…`
  because edge functions cannot localize per-recipient copy yet; the Android/
  iOS path removes the real notification instead. Localized copy is a
  follow-up.
* **WNS channel expiry while the app never restarts**: clients that stay
  running >30 days without a restart keep a stale URI (they'd get no hibernated
  push until the next relaunch re-registers). The FCM path does not have this
  constraint; a periodic re-request can be added later if this matters in
  practice.
* **Interactive toast buttons** (reply/mark-read) require
  `PushNotificationManager` toast action handlers; not implemented here.

## Verifying on a machine

1. Install the signed MSIX (`matchme.exe` with package identity).
2. DebugView (Sysinternals) shows `[PushChannel] PushChannel registered` and
   channel creation logs.
3. Log in; check the session registered with a WNS URI:
   ```sql
   select platform, metadata->>'wns_channel_uri', metadata->>'wns_channel_uri_updated_at'
   from user_session
   where platform = 'windows' and revoked = false
   order by metadata->>'wns_channel_uri_updated_at' desc;
   ```
4. Send a chat message to that account from another device with the Windows
   app closed → a Windows toast appears; clicking it opens the chat.
5. If nothing arrives: `[wns]` lines in the push-message / cron-jobs logs give
   the WNS HTTP status (`401` → credentials, `410` → pruned channel, `404/400`
   → malformed URI, `403` with empty body → token app not yet paired with the
   channel's PFN — check the mapping email from the prerequisites landed).
