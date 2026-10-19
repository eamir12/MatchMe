// supabase/functions/_shared/wns.ts
// Windows push (WNS) transport: OAuth app token + raw toast dispatch.
//
// Windows desktop builds have no FCM transport (push-message filters its
// session targets to ios/android/web), so the MSIX-packaged client registers
// a WNS channel URI (metadata wns_channel_uri on its platform='windows'
// user_session row) and every server-side sender dispatches toasts through
// this helper — Windows clients get the same "guaranteed delivery while the
// app is closed" property Android/iOS get from FCM/APNs.
//
// Credentials: MSA client-credentials grant bound to the Partner Center
// "Package SID" (WNS_CLIENT_ID) + "Application Secret" (WNS_CLIENT_SECRET).
// The token is cached in one wns_token_cache row (24h TTL, refreshed with
// 2 minutes of slack), because edge invocations are stateless.

import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// Legacy MSA flow: Partner Center Package SID + secret at login.live.com.
// login.live.com now answers 400 "Client credential flows against
// login.live.com are no longer supported. New clients should use
// login.microsoftonline.com instead." for newly-provisioned products, so the
// default path is the Microsoft Entra v2.0 client-credentials flow with the
// app registration Partner Center links on the product's Push notifications
// page (see https://learn.microsoft.com/... push-quickstart):
//   POST https://login.microsoftonline.com/{tenantID}/oauth2/v2.0/token
//   grant_type=client_credentials
//   client_id=<Application (client) ID>
//   client_secret=<secret>
//   scope=https://wns.windows.com/.default
const LEGACY_MSA_TOKEN_URL = "https://login.live.com/accesstoken.srf";
const ENTRA_TOKEN_URL_TEMPLATE =
  "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token";
const WNS_ENTRA_SCOPE = "https://wns.windows.com/.default";
const CLIENT_ID_GUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOAST_GROUP = "matchme";

// WNS channel URIs are https URLs on *.notify.windows.com pods (db3/db5/...).
// FCM tokens are opaque base64 strings, so the https prefix plus domain is an
// unambiguous discriminator for queue rows / token lists that mix both.
export function isWnsChannelUri(uri: string): boolean {
  const s = String(uri ?? "").trim();
  return /^https:\/\//i.test(s) && s.toLowerCase().includes(".notify.windows.com");
}

// Toast activation payload. The MSIX package declares the `matchme` protocol;
// clicking the toast launches the exe with this URI on the command line, the
// runner exposes it to Dart, and it flows into the same deep-link router
// (_processDeepLink) the mobile platforms use for notification taps.
export function wnsLaunchUri(matchId: unknown): string | undefined {
  const id = String(matchId ?? "").trim();
  if (!id) return undefined;
  return `matchme://chat/${encodeURIComponent(id)}`;
}

function xmlEscape(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

export interface WnsToastOptions {
  channelUri: string;
  title: string;
  body: string;
  launch?: string;
  // Collapse key: WNS replaces the prior Action Center entry with the same
  // tag+group instead of stacking, matching FCM collapseKey semantics.
  tag?: string;
  group?: string;
  // X-WNS-SuppressPopup: drop straight into Action Center without a banner.
  // This is the Windows equivalent of FCM's silent (data-only) push.
  suppressPopup?: boolean;
  timeoutMs?: number;
}

export interface WnsSendResult {
  ok: boolean;
  status: number;
  detail: unknown;
  // Mirror of `detail`.FCM results (sendFcmV1) expose the response payload as
  // `body`, and several dispatch sites log `result.body` on the shared FCM/WNS
  // branch, so WNS results carry the same field.
  body: unknown;
  // 410 Gone — the channel registration no longer exists (app reinstalled /
  // channel expired >30 days). Callers prune it like FCM UNREGISTERED.
  expired?: boolean;
}

export function buildToastXml(opts: {
  title: string;
  body: string;
  launch?: string;
  tag?: string;
  group?: string;
}): string {
  const attrs: string[] = [];
  const launch = String(opts.launch ?? "").trim();
  if (launch) attrs.push(`launch="${xmlEscape(launch)}"`);
  const tag = String(opts.tag ?? "").trim();
  if (tag) attrs.push(`tag="${xmlEscape(tag)}"`);
  const group = String(opts.group ?? TOAST_GROUP).trim();
  if (group) attrs.push(`group="${xmlEscape(group)}"`);
  const attrString = attrs.length > 0 ? ` ${attrs.join(" ")}` : "";
  const texts = [
    String(opts.title ?? "").trim() ? `<text>${xmlEscape(opts.title.trim())}</text>` : "",
    String(opts.body ?? "").trim() ? `<text>${xmlEscape(opts.body.trim())}</text>` : "",
  ]
    .filter(Boolean)
    .join("");
  return `<?xml version="1.0"?><toast${attrString}><visual><binding template="ToastGeneric">${texts}</binding></visual></toast>`;
}

interface WnsCacheRow {
  access_token?: unknown;
  expires_at?: unknown;
}

// Fetches an app-only token and caches it (single row, id=1). `force` skips
// the cache read — used when a 401 indicates the cached token was
// revoked/expired early (changed secret, token rotation).
//
// Two credential styles are accepted in WNS_CLIENT_ID:
//  - Entra app registration (default, required for new Partner Center
//    products): a GUID = Application (client) ID + WNS_TENANT_ID =
//    Directory (tenant) ID. Flow: login.microsoftonline.com
//    client_credentials with scope https://wns.windows.com/.default.
//  - Legacy Package SID (`S-1-15-2-…`, optionally with the `ms-app://`
//    prefix Partner Center used to print): login.live.com app-only flow.
//    Partner Center displays the SID without the prefix; normalize so both
//    forms work the way login.live.com expects.
function normalizeWnsClientId(clientId: string): string {
  const s = clientId.trim();
  if (/^s-1-15-2-/i.test(s)) return `ms-app://${s}`;
  return s;
}

function isLegacyPackageSid(clientId: string): boolean {
  return /^(ms-app:\/\/)?s-1-15-2-/i.test(clientId);
}

export async function getWnsAccessToken(
  adminClient: SupabaseClient<any, "public", "public", any, any>,
  { force = false }: { force?: boolean } = {},
): Promise<string | null> {
  const clientId = (Deno.env.get("WNS_CLIENT_ID") ?? "").trim();
  const clientSecret = (Deno.env.get("WNS_CLIENT_SECRET") ?? "").trim();
  const tenantId = (Deno.env.get("WNS_TENANT_ID") ?? "").trim();
  const legacy = isLegacyPackageSid(clientId);

  if (!clientId || !clientSecret) {
    console.log(
      "[wns] missing WNS_CLIENT_ID / WNS_CLIENT_SECRET (expect the Entra Application (client) ID GUID + WNS_TENANT_ID, or a legacy Package SID)",
    );
    return null;
  }
  if (!legacy && !CLIENT_ID_GUID_RE.test(clientId)) {
    console.log(
      `[wns] WNS_CLIENT_ID is not an Entra client-id GUID (${clientId} — copy 'Application (client) ID' from the app registration)`,
    );
    return null;
  }
  if (!legacy && !tenantId) {
    console.log(
      "[wns] WNS_TENANT_ID is missing (copy 'Directory (tenant) ID' from the app registration)",
    );
    return null;
  }

  const tokenUrl = legacy
    ? LEGACY_MSA_TOKEN_URL
    : ENTRA_TOKEN_URL_TEMPLATE.replace("{tenant}", tenantId || "common");
  const effectiveClientId = legacy ? normalizeWnsClientId(clientId) : clientId;
  const scope = legacy ? "notify.windows.com" : WNS_ENTRA_SCOPE;

  if (!force) {
    try {
      const { data } = await adminClient
        .from("wns_token_cache")
        .select("access_token, expires_at")
        .eq("id", 1)
        .maybeSingle();
      const row = data as WnsCacheRow | null;
      const cached = String(row?.access_token ?? "").trim();
      const expiresAt = Date.parse(String(row?.expires_at ?? ""));
      if (cached && Number.isFinite(expiresAt) && expiresAt > Date.now() + 60_000) {
        return cached;
      }
    } catch (_) {
      // Cache table missing/unavailable: fall through to a fresh grant.
    }
  }

  try {
    const resp = await fetch(tokenUrl, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: effectiveClientId,
        client_secret: clientSecret,
        scope,
      }).toString(),
    });
    if (!resp.ok) {
      let errBody = "";
      try {
        errBody = (await resp.text()).slice(0, 300);
      } catch (_) {}
      console.log(`[wns] token grant failed status=${resp.status} body=${errBody}`);
      return null;
    }
    const payload = (await resp.json()) as { access_token?: unknown; expires_in?: unknown };
    const token = String(payload.access_token ?? "").trim();
    if (!token) {
      console.log("[wns] token grant returned no access_token");
      return null;
    }
    const expiresInSec = Number(payload.expires_in ?? 90_000);
    const safeTtl = Number.isFinite(expiresInSec) ? Math.max(120, expiresInSec - 120) : 86_400;
    const expiresAt = new Date(Date.now() + safeTtl * 1000).toISOString();
    try {
      await adminClient.from("wns_token_cache").upsert({
        id: 1,
        access_token: token,
        expires_at: expiresAt,
        updated_at: new Date().toISOString(),
      });
    } catch (e) {
      // Non-fatal: missing cache table only costs extra token grants.
      console.log(`[wns] token cache write failed: ${e}`);
    }
    return token;
  } catch (e) {
    console.log(`[wns] token grant threw: ${e}`);
    return null;
  }
}

// Sends one toast to one channel URI, refreshing the app token once on 401.
export async function sendWnsToast(
  adminClient: SupabaseClient<any, "public", "public", any, any>,
  opts: WnsToastOptions,
  { tokenRefreshed = false }: { tokenRefreshed?: boolean } = {},
): Promise<WnsSendResult> {
  const uri = String(opts.channelUri ?? "").trim();
  if (!uri || !isWnsChannelUri(uri)) {
    const detail = { error: "invalid wns channel uri" };
    return { ok: false, status: 0, detail, body: detail };
  }
  let accessToken = await getWnsAccessToken(adminClient, { force: tokenRefreshed });
  if (!accessToken) {
    const detail = { error: "wns token unavailable" };
    return { ok: false, status: 0, detail, body: detail };
  }

  const xml = buildToastXml({
    title: opts.title,
    body: opts.body,
    launch: opts.launch,
    tag: opts.tag,
    group: opts.group,
  });

  try {
    const resp = await fetch(uri, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "text/xml",
        "X-WNS-Type": "wns/toast",
        ...(opts.suppressPopup ? { "X-WNS-SuppressPopup": "true" } : {}),
      },
      body: xml,
      signal: AbortSignal.timeout(Math.max(5_000, opts.timeoutMs ?? 15_000)),
    });
    const wnsStatus = (resp.headers.get("X-WNS-NotificationStatus") ?? "").toLowerCase();

    // 401 = token rejected: one retry with a forced fresh grant.
    if (resp.status === 401 && !tokenRefreshed) {
      console.log("[wns] 401 received, retrying once with fresh token");
      return sendWnsToast(adminClient, opts, { tokenRefreshed: true });
    }

    let bodyText = "";
    try {
      bodyText = (await resp.text()).slice(0, 300);
    } catch (_) { /* WNS bodies are usually empty */ }

    // 200 + NotificationStatus "received" is the only positive delivery note;
    // 200 + "dropped" means WNS throttled/failed after accepting the request.
    const delivered = resp.status === 200 && (wnsStatus === "received" || wnsStatus === "queued");
    const detail = { wnsNotificationStatus: wnsStatus, body: bodyText };
    return {
      ok: delivered,
      status: resp.status,
      detail,
      body: detail,
      expired: resp.status === 410,
    };
  } catch (e) {
    const detail = { error: String(e) };
    return { ok: false, status: 0, detail, body: detail };
  }
}
