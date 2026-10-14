import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";
import { bidiIsolate, enforceTitleBody, firstTokenName } from "../_shared/notification_limits.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

type Json = Record<string, unknown>;

function jsonResponse(body: Json, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function base64UrlEncodeBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  const base64 = btoa(binary);
  return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

// Mirrors public.mask_full_name(TEXT) from supabase/migrations.
// Returns "FirstName L." for multi-word names, "FirstName" for single-word names,
// or "Unknown User" when the input is empty/null. Input is trimmed.
function maskFullName(rawFullName: string | null | undefined): string {
  const trimmed = String(rawFullName ?? "").trim();
  if (!trimmed) return "Unknown User";
  const parts = trimmed.split(/\s+/).filter((p) => p.length > 0);
  if (parts.length === 0) return "Unknown User";
  const first = parts[0];
  if (parts.length === 1) return first;
  const last = parts[parts.length - 1];
  if (!last || last === first) return first;
  return `${first} ${last.charAt(0).toUpperCase()}.`;
}

// Resolves the human-readable sender name for a chat push notification.
// Primary path: call public.get_masked_sender_name(senderId), a SECURITY DEFINER
// RPC that bypasses RLS and returns the already-masked name from users.name.
// This is the same approach used by the existing `check_unread_notifications`
// RPC for the Android background service.
// The fallback below is best-effort only — it exists for the rare case where
// the RPC itself errors out (e.g. not yet migrated into the database).
async function resolveSenderName(
  client: ReturnType<typeof createClient>,
  params: { senderId: string; matchId: string; recipientId: string; requestId: string },
): Promise<string> {
  const { senderId, requestId } = params;

  // 1) Preferred: SECURITY DEFINER RPC that knows about all storage locations.
  try {
    const { data: rpcName, error: rpcErr } = await client.rpc(
      "get_masked_sender_name",
      { p_sender_id: senderId },
    );
    if (rpcErr) {
      console.log(`[push-message] sender_name_rpc_error id=${requestId}`, {
        senderId,
        error: String(rpcErr.message ?? rpcErr),
      });
    } else if (typeof rpcName === "string" && rpcName.trim().length > 0) {
      console.log(`[push-message] sender_name_rpc_hit id=${requestId}`, { senderId, name: rpcName });
      return rpcName;
    } else {
      console.log(`[push-message] sender_name_rpc_empty id=${requestId}`, { senderId });
    }
  } catch (e) {
    console.log(`[push-message] sender_name_rpc_threw id=${requestId}`, {
      senderId,
      error: String(e),
    });
  }

  // 2) Fallback: users.name. There is no FK between chats.other_user_id and
  // users, so PostgREST embeds on chats fail; and senderId is already known
  // from the request, so a direct users lookup covers everything the old
  // chats-join path did. full_name is intentionally not selected — the column
  // no longer exists in the current schema and selecting it fails the whole
  // query silently.
  try {
    const { data: userRow, error: userErr } = await client
      .from("users")
      .select("name")
      .eq("id", senderId)
      .maybeSingle();
    if (userErr) {
      console.log(`[push-message] sender_name_users_error id=${requestId}`, {
        error: String(userErr.message ?? userErr),
      });
    } else if (userRow) {
      const raw = String((userRow as { name?: string | null }).name ?? "").trim();
      if (raw) {
        const masked = maskFullName(raw);
        console.log(`[push-message] sender_name_users_hit id=${requestId}`, { name: masked });
        return masked;
      }
    }
  } catch (e) {
    console.log(`[push-message] sender_name_users_threw id=${requestId}`, { error: String(e) });
  }

  return "";
}

function base64UrlEncodeJson(obj: Record<string, unknown>): string {
  const json = JSON.stringify(obj);
  const bytes = new TextEncoder().encode(json);
  return base64UrlEncodeBytes(bytes);
}

function pemToDerBytes(pem: string): Uint8Array {
  const normalized = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "")
    .trim();
  const raw = atob(normalized);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

function sanitizeUrl(raw: string | undefined | null): string | null {
  const trimmed = String(raw ?? "").trim();
  if (!trimmed) return null;
  const withoutBackticks = trimmed.replace(/^`+/, "").replace(/`+$/, "").trim();
  if (!withoutBackticks) return null;
  return withoutBackticks;
}

type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
};

let _cachedAccessToken: string | null = null;
let _cachedAccessTokenExpiryMs = 0;

async function getFcmAccessToken(serviceAccount: ServiceAccount): Promise<string> {
  const nowMs = Date.now();
  if (_cachedAccessToken && nowMs + 60_000 < _cachedAccessTokenExpiryMs) {
    return _cachedAccessToken;
  }

  const tokenUri = sanitizeUrl(serviceAccount.token_uri) || "https://oauth2.googleapis.com/token";

  const iat = Math.floor(nowMs / 1000);
  const exp = iat + 3600;
  const claims = {
    iss: serviceAccount.client_email,
    sub: serviceAccount.client_email,
    aud: tokenUri,
    iat,
    exp,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
  };

  const header = { alg: "RS256", typ: "JWT" };
  const signingInput = `${base64UrlEncodeJson(header)}.${base64UrlEncodeJson(claims)}`;

  const keyBytes = pemToDerBytes(serviceAccount.private_key);
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "RSASSA-PKCS1-v1_5" },
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  const jwt = `${signingInput}.${base64UrlEncodeBytes(new Uint8Array(signature))}`;

  const form = new URLSearchParams();
  form.set("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer");
  form.set("assertion", jwt);

  const resp = await fetch(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: form.toString(),
  });
  const raw = await resp.text();
  if (!resp.ok) {
    throw new Error(`OAuth token exchange failed status=${resp.status} body=${raw}`);
  }
  const parsed = JSON.parse(raw) as { access_token?: string; expires_in?: number };
  if (!parsed.access_token) throw new Error("OAuth token exchange missing access_token");
  const expiresInSec = typeof parsed.expires_in === "number" ? parsed.expires_in : 3600;

  _cachedAccessToken = parsed.access_token;
  _cachedAccessTokenExpiryMs = nowMs + expiresInSec * 1000;
  return parsed.access_token;
}

// ---------------------------------------------------------------------------
// Server-side preference + locale + badge helpers.
// Killed/background system-tray pushes bypass ALL client gates, so the server
// must enforce the same rules or "disabled/paused" users still buzz.
// Mirrors lib/providers/user_preferences_provider.dart matrix keys:
//   global_methods.push (default true)
//   matrix[chat_messages|new_match|expiring_match|admin_announcements].push
//   legacy enable_* flags, paused_until_ms_utc / paused_indefinitely.
// ---------------------------------------------------------------------------
type PushMatrixKey =
  | "chat_messages"
  | "new_match"
  | "expiring_match"
  | "admin_announcements";

function isPushEnabledForPrefs(
  prefs: unknown,
  matrixKey: PushMatrixKey,
  legacyKey: string,
): boolean {
  try {
    if (prefs == null || typeof prefs !== "object" || Array.isArray(prefs)) return true;
    const p = prefs as Record<string, unknown>;
    if (p["paused_indefinitely"] === true) return false;
    const untilRaw = p["paused_until_ms_utc"];
    if (typeof untilRaw === "number" && Number.isFinite(untilRaw)) {
      if (untilRaw > Date.now()) return false;
    } else if (typeof untilRaw === "string" && untilRaw.trim() !== "") {
      const n = Number(untilRaw.trim());
      if (Number.isFinite(n) && n > Date.now()) return false;
    }
    const gm = p["global_methods"];
    if (gm != null && typeof gm === "object" && !Array.isArray(gm)) {
      const push = (gm as Record<string, unknown>)["push"];
      if (push === false) return false;
    }
    const matrix = p["matrix"];
    if (matrix != null && typeof matrix === "object" && !Array.isArray(matrix)) {
      const entry = (matrix as Record<string, unknown>)[matrixKey];
      if (entry != null && typeof entry === "object" && !Array.isArray(entry)) {
        const v = (entry as Record<string, unknown>)["push"];
        if (typeof v === "boolean") return v;
      }
    }
    const legacy = p[legacyKey];
    if (typeof legacy === "boolean") return legacy;
    return true;
  } catch (_) {
    return true;
  }
}

// MatchMe ships exactly three languages: en, es, he. Keep this list and
// _pushStrings in sync with the AppLanguage entries in
// lib/providers/locale_provider.dart. Anything else falls back to English
// rather than silently rendering an untranslated string.
function normalizeLocale(raw: unknown): string {
  const s = String(raw ?? "en").trim().toLowerCase();
  if (!s) return "en";
  if (s.startsWith("he")) return "he";
  if (s.startsWith("es")) return "es";
  return "en";
}

// Minimal killed-state copy so tray pushes aren't English-only. Foreground
// Dart still does full localization; this only covers system-tray display.
const _pushStrings: Record<string, Record<string, string>> = {
  en: {
    newMatchTitle: "New Match!",
    newMatchBody: "You matched with {name}",
    newMessageBody: "New message",
    someone: "Someone",
  },
  he: {
    newMatchTitle: "התאמה חדשה!",
    newMatchBody: "יש לך התאמה עם {name}",
    newMessageBody: "הודעה חדשה",
    someone: "מישהו",
  },
  es: {
    newMatchTitle: "¡Nueva coincidencia!",
    newMatchBody: "Coincidiste con {name}",
    newMessageBody: "Mensaje nuevo",
    someone: "Alguien",
  },
};

function pushString(locale: string, key: string): string {
  const table = _pushStrings[locale] ?? _pushStrings["en"];
  return table[key] ?? _pushStrings["en"][key] ?? key;
}

async function fetchRecipientProfile(
  client: ReturnType<typeof createClient>,
  userId: string,
): Promise<{ prefs: unknown; locale: string }> {
  try {
    const { data } = await client
      .from("users")
      .select("notification_preferences, preferred_language")
      .eq("id", userId)
      .maybeSingle();
    const row = data as { notification_preferences?: unknown; preferred_language?: unknown } | null;
    return {
      prefs: row?.notification_preferences ?? null,
      locale: normalizeLocale(row?.preferred_language),
    };
  } catch (_) {
    return { prefs: null, locale: "en" };
  }
}

async function fetchBadgeCount(
  client: ReturnType<typeof createClient>,
  userId: string,
): Promise<number> {
  try {
    const { data, error } = await client.rpc("check_unread_notifications", {
      p_user_id: userId,
    });
    if (error) return 1;
    const row = Array.isArray(data) ? data[0] : data;
    const r = row as Record<string, unknown> | null | undefined;
    const matches = Number(r?.["unread_matches_count"] ?? 0);
    const messages = Number(r?.["unread_messages_count"] ?? 0);
    const total = (Number.isFinite(matches) ? matches : 0) +
      (Number.isFinite(messages) ? messages : 0);
    if (total <= 0) return 1;
    return Math.min(99, Math.max(1, Math.floor(total)));
  } catch (_) {
    return 1;
  }
}

// Best-effort offline fallback for recipients with no FCM token (desktop
// with no push registration, uninstalled clients). Only for 1:1 chat
// mentions and only when chat pushes are enabled. Never throws — push flow
// must not fail because email is unconfigured.
async function sendOfflineMentionEmail({
  adminClient,
  recipientId,
  senderName,
  matchId,
  locale,
  requestId,
}: {
  adminClient: ReturnType<typeof createClient>;
  recipientId: string;
  senderName: string;
  matchId: string;
  locale: string;
  requestId: string;
}): Promise<boolean> {
  try {
    const resendApiKey = Deno.env.get("RESEND_API_KEY") ?? "";
    if (!resendApiKey) return false;
    const from = Deno.env.get("RESEND_FROM_EMAIL") ||
      Deno.env.get("FROM_EMAIL") ||
      "MatchMe <onboarding@resend.dev>";
    let email = "";
    try {
      const { data: userData } = await adminClient.auth.admin.getUserById(recipientId);
      email = String(userData?.user?.email ?? "").trim();
    } catch (_) {
      return false;
    }
    if (!email) return false;
    const isHe = locale === "he";
    const subject = isHe
      ? `הודעה חדשה מ-${senderName}`
      : `New message from ${senderName}`;
    const cta = `${Deno.env.get("APP_DEEP_LINK_BASE") ?? ""}`.trim();
    const link = cta ? `${cta}/chat/${matchId}` : `/chat/${matchId}`;
    const html = isHe
      ? `<div dir="rtl"><p>קיבלת הודעה חדשה מ-${senderName} ב-MatchMe.</p><p><a href="${link}">פתח את הצ'אט</a></p></div>`
      : `<div><p>You received a new message from ${senderName} on MatchMe.</p><p><a href="${link}">Open chat</a></p></div>`;
    const resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${resendApiKey}`,
      },
      body: JSON.stringify({ from, to: email, subject, html }),
    });
    if (!resp.ok) {
      console.log(`[push-message] email_fallback_failed id=${requestId}`, {
        status: resp.status,
      });
      return false;
    }
    console.log(`[push-message] email_fallback_sent id=${requestId}`, { recipientId });
    return true;
  } catch (e) {
    console.log(`[push-message] email_fallback_threw id=${requestId}`, {
      error: String(e),
    });
    return false;
  }
}

// Record a notification in the user's persistent inbox (public.user_notifications).
// push-message sends directly via FCM without notification_queue, so without
// this the inbox trigger on the queue never sees chat/new-match pushes.
// ignoreDuplicates maps to ON CONFLICT DO NOTHING, which dedupes via the
// partial unique index on (user_id, data->>'message_id') when a message_id
// is present, and is a no-op otherwise.
async function recordInboxNotification(
  adminClient: SupabaseClient,
  params: {
    userId: string;
    type: string;
    title: string;
    body: string;
    data: Record<string, unknown>;
    requestId: string;
  },
): Promise<void> {
  try {
    const { error } = await adminClient
      .from("user_notifications")
      .insert(
        {
          user_id: params.userId,
          type: params.type,
          title: params.title,
          body: params.body,
          data: params.data,
        },
        { ignoreDuplicates: true },
      );
    if (error) {
      console.log(`[push-message] inbox_insert_failed id=${params.requestId}`, {
        userId: params.userId,
        type: params.type,
        ...formatSbErrorLocal(error),
      });
    }
  } catch (e) {
    console.log(`[push-message] inbox_insert_threw id=${params.requestId}`, {
      error: String(e),
    });
  }
}

function formatSbErrorLocal(err: unknown): Record<string, unknown> {
  try {
    if (!err || typeof err !== "object") return { error: String(err) };
    const e = err as Record<string, unknown>;
    return {
      message: typeof e["message"] === "string" ? e["message"] : undefined,
      code: typeof e["code"] === "string" ? e["code"] : undefined,
    };
  } catch (_) {
    return { error: String(err) };
  }
}

async function sendFcmV1({
  serviceAccount,
  accessToken,
  token,
  notification,
  data,
  tag,
  collapseKey,
  channelId,
  badge,
  silent,
}: {
  serviceAccount: ServiceAccount;
  accessToken: string;
  token: string;
  notification: { title: string; body: string };
  data: Record<string, string>;
  tag?: string;
  collapseKey?: string;
  channelId?: string;
  badge?: number;
  silent?: boolean;
}): Promise<{ ok: boolean; status: number; body: unknown }> {
  const projectId = serviceAccount.project_id.trim();
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  // Collapse tag survives app killed/off/reboot: retries replace the tray
  // entry instead of stacking. 7-day TTL keeps offline devices covered
  // (previous web TTL of 60s dropped anything offline > 1 minute).
  const collapse = String(collapseKey ?? tag ?? "").trim();
  // FCM v1 TTL format is "<seconds>s" (max 4 weeks). 7 days covers
  // device-off / reboot / browser-closed gaps without spamming stale rows.
  const ttlSeconds = "604800s";
  const apnsExpiration = String(
    Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
  );
  // Per-type channel must match a channel the app pre-creates with HIGH
  // importance (chat_messages / match_expiry_alerts / admin_broadcasts).
  // A missing/low-importance channel silences heads-up on Android 8+.
  const resolvedChannel = String(channelId ?? "chat_messages").trim() ||
    "chat_messages";
  const resolvedBadge = typeof badge === "number" && Number.isFinite(badge)
    ? Math.min(99, Math.max(1, Math.floor(badge)))
    : 1;
  // Silent (retraction) pushes carry data only: no tray card, just a wakeup
  // so clients can cancel/rebuild the grouped chat notification. iOS needs
  // push-type background + content-available and NO alert block.
  if (silent === true) {
    const silentBody = {
      message: {
        token,
        data: { ...data, badge: String(resolvedBadge), silent: "true" },
        android: {
          priority: "HIGH",
          ttl: ttlSeconds,
          ...(collapse ? { collapseKey: collapse } : {}),
        },
        apns: {
          headers: {
            "apns-priority": "5",
            "apns-push-type": "background",
            "apns-expiration": apnsExpiration,
            ...(collapse ? { "apns-collapse-id": collapse } : {}),
          },
          payload: {
            aps: {
              "content-available": 1,
              badge: resolvedBadge,
            },
          },
        },
        webpush: {
          headers: {
            TTL: "604800",
            Urgency: "high",
            ...(collapse ? { Topic: collapse } : {}),
          },
        },
      },
    };
    const silentResp = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json; charset=utf-8",
      },
      body: JSON.stringify(silentBody),
    });
    const silentRaw = await silentResp.text();
    let silentParsed: unknown = silentRaw;
    try {
      silentParsed = JSON.parse(silentRaw);
    } catch (_) {
    }
    return { ok: silentResp.ok, status: silentResp.status, body: silentParsed };
  }
  const body = {
    message: {
      token,
      notification,
      data: { ...data, badge: String(resolvedBadge) },
      android: {
        priority: "HIGH",
        ttl: ttlSeconds,
        ...(collapse ? { collapseKey: collapse } : {}),
        notification: {
          ...(collapse ? { tag: collapse } : {}),
          channelId: resolvedChannel,
          notificationPriority: "PRIORITY_HIGH",
          defaultSound: true,
        },
      },
      apns: {
        headers: {
          "apns-priority": "10",
          "apns-push-type": "alert",
          "apns-expiration": apnsExpiration,
          ...(collapse ? { "apns-collapse-id": collapse } : {}),
        },
        payload: {
          aps: {
            alert: { title: notification.title, body: notification.body },
            sound: "default",
            badge: resolvedBadge,
            "content-available": 1,
            "mutable-content": 1,
          },
        },
      },
      webpush: {
        headers: {
          TTL: "604800",
          Urgency: "high",
          ...(collapse ? { Topic: collapse } : {}),
        },
        notification: {
          icon: "/icons/Icon-192.png",
          badge: "/icons/Icon-192.png",
          requireInteraction: true,
          ...(collapse ? { tag: collapse, renotify: true } : {}),
        },
        fcmOptions: { link: data.route || data.action_url || "/" },
      },
    },
  };

  const resp = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json; charset=utf-8",
    },
    body: JSON.stringify(body),
  });
  const raw = await resp.text();
  let parsed: unknown = raw;
  try {
    parsed = JSON.parse(raw);
  } catch (_) {
  }
  return { ok: resp.ok, status: resp.status, body: parsed };
}

serve(async (req) => {
  const requestId = crypto.randomUUID();
  const startedAtMs = Date.now();
  const functionName = "push-message";
  let success = false;
  let httpStatus = 500;
  let errorType: string | null = null;
  let errorMessage: string | null = null;

  const jsonResponse = (body: Json, status = 200) => {
    httpStatus = status;
    success = status < 400;
    return new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  };

  try {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    console.log(`[push-message] start id=${requestId} method=${req.method}`);

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const fcmServiceAccountJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON") ?? "";
    const internalSecret = Deno.env.get("MATCHME_INTERNAL_SECRET") ?? "";

    console.log(`[push-message] env id=${requestId}`, {
      hasSupabaseUrl: !!supabaseUrl,
      hasServiceRoleKey: !!serviceRoleKey,
      hasAnonKey: !!anonKey,
      hasFcmServiceAccountJson: !!fcmServiceAccountJson,
      hasInternalSecret: !!internalSecret,
    });

    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: "Missing Supabase environment variables" }, 500);
    }
    if (!fcmServiceAccountJson) {
      return jsonResponse({ error: "Missing FCM_SERVICE_ACCOUNT_JSON" }, 500);
    }

    let payload: Json;
    try {
      payload = (await req.json()) as Json;
    } catch (_) {
      return jsonResponse({ error: "Invalid JSON body" }, 400);
    }

    const formatSbError = (err: unknown) => {
      try {
        if (!err || typeof err !== "object") return { error: String(err) };
        const e = err as Record<string, unknown>;
        return {
          message: typeof e["message"] === "string" ? e["message"] : undefined,
          details: typeof e["details"] === "string" ? e["details"] : undefined,
          hint: typeof e["hint"] === "string" ? e["hint"] : undefined,
          code: typeof e["code"] === "string" ? e["code"] : undefined,
          raw: JSON.stringify(err),
        };
      } catch (_) {
        return { error: String(err) };
      }
    };

    const rawKind = String(payload["kind"] ?? "").trim().toLowerCase();
    const messageId = String(payload["message_id"] ?? payload["messageId"] ?? "").trim();
    const matchIdHint = String(payload["match_id"] ?? payload["matchId"] ?? "").trim();
    const record = payload["record"];
    const matchIdFromRecord =
      record && typeof record === "object" && record !== null
        ? String((record as Record<string, unknown>)["id"] ?? "").trim()
        : "";

    const webhookTable = String(payload["table"] ?? "").trim().toLowerCase();
    const webhookType = String(payload["type"] ?? "").trim().toUpperCase();
    const isMatchWebhook = webhookTable === "matches" && webhookType === "INSERT";
    const isMessageWebhook = webhookTable === "chat_messages" && webhookType === "INSERT";

    // Webhook secret validation for webhook-triggered calls
    const webhookSecret = req.headers.get("x-matchme-webhook-secret") ?? "";
    if ((isMatchWebhook || isMessageWebhook) && webhookSecret !== internalSecret) {
      console.log(`[push-message] invalid_webhook_secret id=${requestId}`);
      return jsonResponse({ error: "Invalid webhook secret" }, 401);
    }

    // Server-to-server mode: translate-proxy passes the decrypted/translated body.
    // Identified by the `kind` field — translate-proxy is the only caller.
    const isTranslatedMessage = rawKind === "translated_message";
    const providedBody = String(payload["body"] ?? "").trim();

    const isRetraction = rawKind === "message_edited" ||
      rawKind === "message_deleted";
    const mode = isMessageWebhook
      ? "message_webhook"
      : isTranslatedMessage
        ? "translated_message"
        : isRetraction
          ? rawKind
          : messageId
            ? "message"
            : (rawKind === "match" || isMatchWebhook)
              ? "match"
              : "";
    if (!mode) {
      return jsonResponse({ error: "Invalid payload: expected message_id, kind=match, kind=translated_message, kind=message_edited/message_deleted, or chat_messages webhook" }, 400);
    }

    console.log(`[push-message] request id=${requestId}`, {
      mode,
      messageId,
      matchIdHint: matchIdHint || null,
    });

    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false },
    });

    async function loadUserTokens(userId: string): Promise<string[]> {
      let sessionRows: unknown[] = [];
      const primary = await adminClient
        .from("user_session")
        .select("id, metadata, platform, revoked")
        .eq("user_id", userId)
        .eq("revoked", false)
        .in("platform", ["ios", "android", "web"]);

      if (primary.error) {
        console.log(`[push-message] recipient_sessions_error id=${requestId}`, {
          recipientId: userId,
          table: "user_session",
          attempt: "filtered",
          ...formatSbError(primary.error),
        });

        const fallback1 = await adminClient
          .from("user_session")
          .select("id, metadata")
          .eq("user_id", userId);

        if (fallback1.error) {
          console.log(`[push-message] recipient_sessions_error id=${requestId}`, {
            recipientId: userId,
            table: "user_session",
            attempt: "unfiltered",
            ...formatSbError(fallback1.error),
          });

          const fallback2 = await adminClient
            .from("user_sessions")
            .select("id, metadata")
            .eq("user_id", userId);

          if (fallback2.error) {
            console.log(`[push-message] recipient_sessions_error id=${requestId}`, {
              recipientId: userId,
              table: "user_sessions",
              attempt: "unfiltered",
              ...formatSbError(fallback2.error),
            });
            return [];
          }

          sessionRows = (fallback2.data as unknown[] | null) ?? [];
        } else {
          sessionRows = (fallback1.data as unknown[] | null) ?? [];
        }
      } else {
        sessionRows = (primary.data as unknown[] | null) ?? [];
      }

      const tokens = (sessionRows ?? [])
        .map((r) => {
          const md = (r as { metadata?: Record<string, unknown> }).metadata ?? {};
          const t = String(md["fcm_token"] ?? "").trim();
          return t || null;
        })
        .filter((t): t is string => typeof t === "string" && t.length > 0);

      return Array.from(new Set(tokens));
    }

    let serviceAccount: ServiceAccount;
    try {
      serviceAccount = JSON.parse(fcmServiceAccountJson) as ServiceAccount;
    } catch (_) {
      return jsonResponse({ error: "FCM_SERVICE_ACCOUNT_JSON is not valid JSON" }, 500);
    }
    if (
      !serviceAccount?.project_id || !serviceAccount?.client_email ||
      !serviceAccount?.private_key
    ) {
      return jsonResponse({
        error:
          "FCM_SERVICE_ACCOUNT_JSON must include project_id, client_email, private_key",
      }, 500);
    }

    let accessToken: string;
    try {
      accessToken = await getFcmAccessToken(serviceAccount);
    } catch (e) {
      return jsonResponse({ error: "Failed to get FCM access token", detail: String(e) }, 502);
    }

    if (mode === "match") {
      if (!internalSecret) {
        return jsonResponse({ error: "Missing MATCHME_INTERNAL_SECRET" }, 500);
      }
      const providedSecret = String(req.headers.get("x-matchme-internal") ?? "").trim();
      if (providedSecret !== internalSecret) {
        console.log(`[push-message] forbidden_internal_secret id=${requestId}`);
        return jsonResponse({ error: "Forbidden" }, 403);
      }

      const matchId = matchIdHint || matchIdFromRecord;
      if (!matchId) return jsonResponse({ error: "match_id is required" }, 400);

      const recordUser1 =
        record && typeof record === "object" && record !== null
          ? String((record as Record<string, unknown>)["user1_id"] ?? "").trim()
          : "";
      const recordUser2 =
        record && typeof record === "object" && record !== null
          ? String((record as Record<string, unknown>)["user2_id"] ?? "").trim()
          : "";

      let user1Id = recordUser1;
      let user2Id = recordUser2;

      if (!user1Id || !user2Id) {
        const { data: matchRow, error: matchErr } = await adminClient
          .from("matches")
          .select("id, user1_id, user2_id")
          .eq("id", matchId)
          .maybeSingle();

        if (matchErr || !matchRow) {
          console.log(`[push-message] match_not_found id=${requestId}`, { matchId });
          return jsonResponse({ error: "Match not found" }, 404);
        }

        user1Id = String(matchRow.user1_id ?? "").trim();
        user2Id = String(matchRow.user2_id ?? "").trim();
      }

      if (!user1Id || !user2Id) {
        return jsonResponse({ error: "Invalid match participants" }, 400);
      }

      const { data: usersRows } = await adminClient
        .from("users")
        .select("id, name, notification_preferences, preferred_language")
        .in("id", [user1Id, user2Id]);

      const usersById = new Map<string, string>();
      const prefsById = new Map<string, unknown>();
      const localeById = new Map<string, string>();
      for (const row of (usersRows ?? []) as unknown[]) {
        const r = row as Record<string, unknown>;
        const id = String(r["id"] ?? "").trim();
        const name = String(r["name"] ?? "").trim();
        if (id) {
          usersById.set(id, name);
          prefsById.set(id, r["notification_preferences"] ?? null);
          localeById.set(id, normalizeLocale(r["preferred_language"]));
        }
      }

      const displayNameFor = (userId: string): string => {
        return firstTokenName(usersById.get(userId) || "Someone");
      };

      const recipients = [user1Id, user2Id];

      const sends = await Promise.allSettled(
        recipients.map(async (recipientId) => {
          const locale = localeById.get(recipientId) ?? "en";
          const someone = pushString(locale, "someone");
          const otherUserId = recipientId === user1Id ? user2Id : user1Id;
          const otherName = displayNameFor(otherUserId) === "Someone" && locale !== "en"
            ? someone
            : displayNameFor(otherUserId);
          const enforced = enforceTitleBody(
            pushString(locale, "newMatchTitle"),
            pushString(locale, "newMatchBody").replace("{name}", bidiIsolate(otherName)),
          );
          // FCM v1 accepts only title/body/image inside message.notification;
          // enforceTitleBody's extra `truncated` flag must not leak through.
          const notification = { title: enforced.title, body: enforced.body };
          const data = {
            matchId,
            match_id: matchId,
            tabIndex: "1",
            otherUserId,
            kind: "match",
            type: "match",
          };

          // The inbox records every new match, regardless of push
          // preferences or registered devices.
          await recordInboxNotification(adminClient, {
            userId: recipientId,
            type: "new_match",
            title: notification.title,
            body: notification.body,
            data,
            requestId,
          });

          // Server-side prefs gate: only the FCM send is gated; the inbox
          // row above is unconditional.
          const prefs = prefsById.get(recipientId) ?? null;
          if (!isPushEnabledForPrefs(prefs, "new_match", "enable_new_match_notifications")) {
            console.log(`[push-message] skip_disabled_match id=${requestId}`, { recipientId });
            return { recipientId, requested: 0, sent: 0, failed: 0, skipped: "disabled", failures: [] as unknown[] };
          }
          const tokens = await loadUserTokens(recipientId);
          console.log(`[push-message] tokens id=${requestId}`, {
            recipientId,
            tokens: tokens.length,
          });
          if (tokens.length === 0) return { recipientId, requested: 0, sent: 0, failed: 0, failures: [] as unknown[] };

          const badge = await fetchBadgeCount(adminClient, recipientId);

          const results = await Promise.allSettled(
            tokens.map((token) =>
              sendFcmV1({
                serviceAccount,
                accessToken,
                token,
                notification,
                data,
                tag: `new_match_${matchId}`,
                collapseKey: `new_match_${matchId}`,
                channelId: "chat_messages",
                badge,
              })
            ),
          );

          const successes: unknown[] = [];
          const failures: unknown[] = [];
          for (const r of results) {
            if (r.status === "fulfilled") {
              if (r.value.ok) successes.push(r.value.body);
              else failures.push({ status: r.value.status, body: r.value.body });
            } else {
              failures.push({ error: String(r.reason) });
            }
          }

          return {
            recipientId,
            requested: tokens.length,
            sent: successes.length,
            failed: failures.length,
            failures,
          };
        }),
      );

      const perRecipient: unknown[] = sends.map((s) =>
        s.status === "fulfilled" ? s.value : { error: String(s.reason) }
      );
      const totalRequested = perRecipient.reduce((acc, r) => {
        const rr = r as Record<string, unknown>;
        const n = typeof rr["requested"] === "number" ? rr["requested"] as number : 0;
        return acc + n;
      }, 0);
      const totalSent = perRecipient.reduce((acc, r) => {
        const rr = r as Record<string, unknown>;
        const n = typeof rr["sent"] === "number" ? rr["sent"] as number : 0;
        return acc + n;
      }, 0);
      const totalFailed = perRecipient.reduce((acc, r) => {
        const rr = r as Record<string, unknown>;
        const n = typeof rr["failed"] === "number" ? rr["failed"] as number : 0;
        return acc + n;
      }, 0);

      const response = {
        ok: true,
        mode,
        matchId,
        requested: totalRequested,
        sent: totalSent,
        failed: totalFailed,
        perRecipient,
      };

      console.log(`[push-message] result id=${requestId}`, {
        mode,
        requested: response.requested,
        sent: response.sent,
        failed: response.failed,
      });

      return jsonResponse(response);
    }

    // translated_message: server-to-server call from translate-proxy. The body
    // text has already been determined (translated or original plaintext). The
    // server-to-server call uses the internal secret instead of JWT.
    if (mode === "translated_message") {
      if (!internalSecret) {
        return jsonResponse({ error: "Missing MATCHME_INTERNAL_SECRET" }, 500);
      }
      const providedSecret = String(req.headers.get("x-matchme-internal") ?? "").trim();
      if (providedSecret !== internalSecret) {
        console.log(`[push-message] forbidden_internal_secret id=${requestId}`);
        return jsonResponse({ error: "Forbidden" }, 403);
      }
      if (!messageId) {
        return jsonResponse({ error: "message_id is required" }, 400);
      }
      if (!providedBody) {
        return jsonResponse({ error: "body is required" }, 400);
      }

      const { data: msgRow, error: msgErr } = await adminClient
        .from("chat_messages")
        .select("id, match_id, sender_id")
        .eq("id", messageId)
        .maybeSingle();

      if (msgErr || !msgRow) {
        console.log(`[push-message] message_not_found id=${requestId}`, { messageId });
        return jsonResponse({ error: "Message not found" }, 404);
      }

      const tMatchId = String(msgRow.match_id ?? "").trim();
      const tSenderId = String(msgRow.sender_id ?? "").trim();
      if (!tMatchId) return jsonResponse({ error: "match_id not found" }, 400);
      if (!tSenderId) return jsonResponse({ error: "sender_id not found" }, 400);

      const { data: matchRow } = await adminClient
        .from("matches")
        .select("user1_id, user2_id")
        .eq("id", tMatchId)
        .maybeSingle();
      const recipientId = (matchRow?.user1_id === tSenderId)
        ? String(matchRow.user2_id ?? "").trim()
        : String(matchRow.user1_id ?? "").trim();
      if (!recipientId) return jsonResponse({ error: "recipient not found" }, 400);

      const profile = await fetchRecipientProfile(adminClient, recipientId);
      const resolvedRawName = await resolveSenderName(adminClient, {
        senderId: tSenderId,
        matchId: tMatchId,
        recipientId,
        requestId,
      });
      const senderName = resolvedRawName ||
        pushString(profile.locale, "someone");

      const enforced = enforceTitleBody(senderName, providedBody);
      const notification = { title: enforced.title, body: enforced.body };
      const data: Record<string, string> = {
        matchId: tMatchId,
        match_id: tMatchId,
        route: `/chat/${tMatchId}`,
        messageId,
        message_id: messageId,
        senderId: tSenderId,
        sender_id: tSenderId,
        recipientId,
        recipient_id: recipientId,
        kind: "message",
        type: "chat_message",
        preview_capable: "true",
      };

      // The inbox records every chat message, regardless of push
      // preferences or registered devices (deduped per message by the DB).
      await recordInboxNotification(adminClient, {
        userId: recipientId,
        type: "chat_message",
        title: notification.title,
        body: notification.body,
        data,
        requestId,
      });

      // Server-side prefs gate: only the FCM send is gated; the inbox row
      // above is unconditional.
      if (!isPushEnabledForPrefs(profile.prefs, "chat_messages", "enable_chat_notifications")) {
        console.log(`[push-message] skip_disabled_chat id=${requestId}`, { recipientId });
        return jsonResponse({ ok: true, sent: 0, skipped: "disabled" });
      }

      const recipientTokens = await loadUserTokens(recipientId);
      console.log(`[push-message] chat_tokens id=${requestId}`, {
        recipientId,
        tokens: recipientTokens.length,
      });
      if (recipientTokens.length === 0) {
        return jsonResponse({ ok: true, sent: 0 });
      }

      const badge = await fetchBadgeCount(adminClient, recipientId);

      const results = await Promise.allSettled(
        recipientTokens.map((token) =>
          sendFcmV1({
            serviceAccount,
            accessToken,
            token,
            notification,
            data,
            tag: `match_${tMatchId}`,
            collapseKey: `match_${tMatchId}`,
            channelId: "chat_messages",
            badge,
          })
        ),
      );
      const successes: unknown[] = [];
      const failures: Array<Record<string, unknown>> = [];
      const retryableFailures: Array<{ token: string; detail: Record<string, unknown> }> = [];
      for (let i = 0; i < results.length; i++) {
        const token = recipientTokens[i];
        const r = results[i];
        if (r.status === "fulfilled") {
          if (r.value.ok) successes.push(r.value.body);
          else {
            const detail: Record<string, unknown> = { status: r.value.status, body: r.value.body };
            failures.push({ token, ...detail });
            // Transient FCM failures (rate limiting, 5xx, transport errors)
            // go to notification_queue for the cron-jobs drainer to retry
            // with backoff. Permanent errors (400 invalid payload, 404
            // UNREGISTERED token) are logged only: retrying cannot fix them.
            if (r.value.status === 429 || r.value.status >= 500) {
              retryableFailures.push({ token, detail });
            }
          }
        } else {
          failures.push({ token, error: String(r.reason) });
          // Exceptions are transport-level (timeout, network) → retryable.
          retryableFailures.push({ token, detail: { error: String(r.reason) } });
        }
      }
      console.log(`[push-message] chat_send_result id=${requestId}`, {
        recipientId,
        requested: recipientTokens.length,
        sent: successes.length,
        failed: failures.length,
        failures,
      });
      // Backstop: hand transient failures to the queue so a chat push that
      // fails once is retried by cron-jobs instead of being dropped silently.
      if (retryableFailures.length > 0) {
        const queueRows = retryableFailures.map((f) => ({
          user_id: recipientId,
          fcm_token: f.token,
          title: notification.title,
          body: notification.body,
          data,
          status: "pending",
          attempts: 0,
          scheduled_at: new Date().toISOString(),
        }));
        const { error: queueErr } = await adminClient
          .from("notification_queue")
          .insert(queueRows);
        console.log(`[push-message] chat_queue_retry id=${requestId}`, {
          queued: queueRows.length,
          error: queueErr ? formatSbError(queueErr) : null,
        });
      }
      // Delivery receipt: FCM accepting the send is the server's best proof
      // the message reached the recipient's device transport, so mark it
      // delivered without waiting for the recipient's client ACK (which only
      // happens once they open the app). The guarded update keeps the client
      // ACK authoritative: delivered_at is only filled while still null.
      if (successes.length > 0) {
        const { error: deliveredErr } = await adminClient
          .from("chat_messages")
          .update({ delivered_at: new Date().toISOString() })
          .eq("id", messageId)
          .is("delivered_at", null);
        if (deliveredErr) {
          console.log(
            `[push-message] delivered_mark_failed id=${requestId}`,
            { messageId, ...formatSbError(deliveredErr) },
          );
        }
      }
      return jsonResponse({
        ok: true,
        mode,
        requested: recipientTokens.length,
        sent: successes.length,
        failed: failures.length,
      });
    }

    // Retraction (edit/delete) pushes: silent data-only so recipients cancel
    // or rebuild the grouped chat tray instead of showing a stale card.
    // Called by the sender client right after a successful edit/delete RPC.
    // JWT authed user must be a match participant (deleted rows can't be
    // re-read, so match membership is the check, not message ownership).
    if (mode === "message_edited" || mode === "message_deleted") {
      if (!anonKey) {
        return jsonResponse({ error: "Missing SUPABASE_ANON_KEY" }, 500);
      }
      const rMatchId = String(
        payload["match_id"] ?? payload["matchId"] ?? matchIdHint ?? "",
      ).trim();
      const rMessageId = String(
        payload["message_id"] ?? payload["messageId"] ?? messageId ?? "",
      ).trim();
      if (!rMatchId) return jsonResponse({ error: "match_id is required" }, 400);
      if (!rMessageId) return jsonResponse({ error: "message_id is required" }, 400);

      const authHeader = req.headers.get("Authorization") ?? "";
      if (!authHeader.toLowerCase().startsWith("bearer ")) {
        return jsonResponse({ error: "Missing authorization header" }, 401);
      }
      const authClient = createClient(supabaseUrl, anonKey, {
        auth: { persistSession: false },
        global: { headers: { Authorization: authHeader } },
      });
      const { data: userData, error: userErr } = await authClient.auth.getUser();
      const authedUserId = userData?.user?.id ?? "";
      if (userErr || !authedUserId) {
        return jsonResponse({ error: "Unauthorized" }, 401);
      }
      const { data: rMatchRow } = await adminClient
        .from("matches")
        .select("user1_id, user2_id")
        .eq("id", rMatchId)
        .maybeSingle();
      const rU1 = String(rMatchRow?.user1_id ?? "").trim();
      const rU2 = String(rMatchRow?.user2_id ?? "").trim();
      if (!rU1 || !rU2 || (authedUserId !== rU1 && authedUserId !== rU2)) {
        return jsonResponse({ error: "Forbidden" }, 403);
      }
      const rRecipientId = authedUserId === rU1 ? rU2 : rU1;
      const rProfile = await fetchRecipientProfile(adminClient, rRecipientId);
      if (!isPushEnabledForPrefs(rProfile.prefs, "chat_messages", "enable_chat_notifications")) {
        return jsonResponse({ ok: true, sent: 0, skipped: "disabled" });
      }
      const rTokens = await loadUserTokens(rRecipientId);
      if (rTokens.length === 0) {
        return jsonResponse({ ok: true, sent: 0 });
      }
      const rBadge = await fetchBadgeCount(adminClient, rRecipientId);
      const rData: Record<string, string> = {
        matchId: rMatchId,
        match_id: rMatchId,
        route: `/chat/${rMatchId}`,
        messageId: rMessageId,
        message_id: rMessageId,
        senderId: authedUserId,
        sender_id: authedUserId,
        recipientId: rRecipientId,
        recipient_id: rRecipientId,
        kind: mode,
        type: mode,
      };
      const rResults = await Promise.allSettled(
        rTokens.map((token) =>
          sendFcmV1({
            serviceAccount,
            accessToken,
            token,
            notification: { title: "", body: "" },
            data: rData,
            tag: `match_${rMatchId}`,
            collapseKey: `match_${rMatchId}`,
            channelId: "chat_messages",
            badge: rBadge,
            silent: true,
          })
        ),
      );
      let rSent = 0;
      for (const r of rResults) {
        if (r.status === "fulfilled" && r.value.ok) rSent++;
      }
      return jsonResponse({
        ok: true,
        mode,
        requested: rTokens.length,
        sent: rSent,
        failed: rTokens.length - rSent,
      });
    }

    if (!anonKey) {
      return jsonResponse({ error: "Missing SUPABASE_ANON_KEY" }, 500);
    }

    // For webhook mode, extract message details from the record payload.
    // For client mode, we need JWT auth to verify the sender.
    let messageRow: Record<string, unknown> | null = null;
    let authedUserId = "";

    if (mode === "message_webhook") {
      if (!record || typeof record !== "object") {
        return jsonResponse({ error: "Invalid webhook payload: missing record" }, 400);
      }
      messageRow = record as Record<string, unknown>;
      const recordMatchId = String(messageRow["match_id"] ?? "").trim();
      const recordSenderId = String(messageRow["sender_id"] ?? "").trim();
      if (!recordMatchId) return jsonResponse({ error: "match_id not found in record" }, 400);
      if (!recordSenderId) return jsonResponse({ error: "sender_id not found in record" }, 400);
      console.log(`[push-message] webhook_mode id=${requestId}`, { matchId: recordMatchId, senderId: recordSenderId });
    } else {
      // Client mode: require JWT auth
      const authHeader = req.headers.get("Authorization") ?? "";
      if (!authHeader.toLowerCase().startsWith("bearer ")) {
        console.log(`[push-message] missing_auth id=${requestId}`);
        return jsonResponse({ error: "Missing authorization header" }, 401);
      }

      const authClient = createClient(supabaseUrl, anonKey, {
        auth: { persistSession: false },
        global: { headers: { Authorization: authHeader } },
      });

      const { data: userData, error: userErr } = await authClient.auth.getUser();
      authedUserId = userData?.user?.id ?? "";
      if (userErr || !authedUserId) {
        console.log(`[push-message] unauthorized id=${requestId}`);
        return jsonResponse({ error: "Unauthorized" }, 401);
      }

      console.log(`[push-message] authed id=${requestId}`, { authedUserId });

      const { data: msgRow, error: msgErr } = await adminClient
        .from("chat_messages")
        .select("id, match_id, sender_id, encryption_scheme, created_at")
        .eq("id", messageId)
        .maybeSingle();

      if (msgErr || !msgRow) {
        console.log(`[push-message] message_not_found id=${requestId}`, { messageId });
        return jsonResponse({ error: "Message not found" }, 404);
      }
      messageRow = msgRow as Record<string, unknown>;
    }

    const matchId = String(messageRow["match_id"] ?? "").trim() || matchIdHint;
    if (!matchId) return jsonResponse({ error: "match_id not found" }, 400);

    const senderId = String(messageRow["sender_id"] ?? "").trim();
    if (!senderId) return jsonResponse({ error: "sender_id not found" }, 400);

    // Only verify sender for client mode (webhook mode is server-triggered)
    if (mode === "message" && authedUserId !== senderId) {
      console.log(`[push-message] forbidden_not_sender id=${requestId}`, {
        matchId,
        authedUserId,
        senderId,
      });
      return jsonResponse({ error: "Only sender may trigger push" }, 403);
    }

    let recipientId = "";

    const { data: matchRow, error: matchErr } = await adminClient
      .from("matches")
      .select("id, user1_id, user2_id")
      .eq("id", matchId)
      .maybeSingle();

    if (!matchErr && matchRow) {
      const user1Id = String(matchRow.user1_id ?? "").trim();
      const user2Id = String(matchRow.user2_id ?? "").trim();
      const participantIds = new Set([user1Id, user2Id]);
      if (mode !== "message_webhook" && !participantIds.has(authedUserId)) {
        console.log(`[push-message] forbidden_not_participant id=${requestId}`, {
          matchId,
          authedUserId,
        });
        return jsonResponse({ error: "Forbidden" }, 403);
      }

      recipientId = senderId === user1Id ? user2Id : user1Id;
      if (!recipientId) {
        console.log(`[push-message] recipient_not_found id=${requestId}`, {
          matchId,
          user1Id,
          user2Id,
          senderId,
        });
        return jsonResponse({ error: "Recipient not found" }, 400);
      }
    } else {
      if (matchErr) {
        console.log(`[push-message] match_lookup_error id=${requestId}`, {
          matchId,
          error: JSON.stringify(matchErr),
        });
      } else {
        console.log(`[push-message] match_not_found id=${requestId}`, { matchId });
      }

      const { data: chatRow, error: chatErr } = await adminClient
        .from("chats")
        .select("other_user_id")
        .eq("user_id", senderId)
        .eq("match_id", matchId)
        .maybeSingle();

      if (chatErr) {
        console.log(`[push-message] chats_lookup_error id=${requestId}`, {
          matchId,
          senderId,
          error: String(chatErr),
        });
      }

      recipientId = String(chatRow?.other_user_id ?? "").trim();
      if (!recipientId) {
        return jsonResponse({ error: "Match not found" }, 404);
      }

      console.log(`[push-message] recipient_from_chats id=${requestId}`, {
        matchId,
        recipientId,
      });
    }

    if (recipientId === senderId) {
      console.log(`[push-message] recipient_is_sender id=${requestId}`, {
        matchId,
        senderId,
      });
      return jsonResponse({ ok: true, sent: 0 }, 200);
    }

    const recipientProfile = await fetchRecipientProfile(adminClient, recipientId);
    const resolvedRawName = await resolveSenderName(adminClient, {
      senderId,
      matchId,
      recipientId,
      requestId,
    });
    const senderName = resolvedRawName ||
      pushString(recipientProfile.locale, "someone");

    const encryptionScheme = String(messageRow["encryption_scheme"] ?? "v1").trim().toLowerCase();

    // Check for existing translation on the message
    const hasServerTranslation =
      messageRow["content_translated_encrypted"] != null &&
      String(messageRow["content_translated_encrypted"]).trim().length > 0 &&
      messageRow["content_translated_nonce"] != null &&
      String(messageRow["content_translated_nonce"]).trim().length > 0 &&
      messageRow["translated_target_language"] != null &&
      String(messageRow["translated_target_language"]).trim().length > 0;

    // Look up recipient's chat to check translation language preference
    let recipientTargetLang: string | null = null;
    try {
      const { data: recipientChat } = await adminClient
        .from("chats")
        .select("translation_enabled, translation_language")
        .eq("user_id", recipientId)
        .eq("match_id", matchId)
        .maybeSingle();
      if (recipientChat?.translation_enabled && recipientChat.translation_language) {
        recipientTargetLang = String(recipientChat.translation_language).trim().toLowerCase();
      }
    } catch (_) {}

    // If the server has a translation matching the recipient's target language, we could
    // include the translated text — but since we can't decrypt server-side without the
    // crypto functions, we just pass the encrypted translation in the data payload so
    // the client app can decrypt and display it as a local notification update.
    const translationMatchesUi =
      hasServerTranslation &&
      recipientTargetLang != null &&
      String(messageRow["translated_target_language"]).trim().toLowerCase() === recipientTargetLang;

    // Notification body — always a placeholder since the server can't decrypt.
    // Localized so killed-state tray matches the recipient language.
    const messageText = pushString(recipientProfile.locale, "newMessageBody");

    // Include translation data in the payload so the client can decrypt and update
    const messageIdForPush = String(messageRow["id"] ?? messageId).trim();
    const data: Record<string, string> = {
      matchId,
      match_id: matchId,
      route: `/chat/${matchId}`,
      messageId: messageIdForPush,
      message_id: messageIdForPush,
      senderId,
      sender_id: senderId,
      recipientId,
      recipient_id: recipientId,
      kind: "message",
      type: "chat_message",
      encryption_scheme: encryptionScheme,
      preview_capable: "true",
    };
    if (translationMatchesUi) {
      data["translated_content_encrypted"] = String(messageRow["content_translated_encrypted"]);
      data["translated_content_nonce"] = String(messageRow["content_translated_nonce"]);
      data["translated_target_language"] = String(messageRow["translated_target_language"]);
      data["has_translation"] = "true";
    }

    const enforced = enforceTitleBody(
      senderName,
      messageText.length > 0 ? messageText : pushString(recipientProfile.locale, "newMessageBody"),
    );
    const notification = { title: enforced.title, body: enforced.body };

    // The inbox records every chat message, regardless of push preferences
    // or registered devices (deduped per message by the DB).
    await recordInboxNotification(adminClient, {
      userId: recipientId,
      type: "chat_message",
      title: notification.title,
      body: notification.body,
      data,
      requestId,
    });

    // Server-side prefs gate: only the FCM send is gated; the inbox row
    // above is unconditional.
    if (!isPushEnabledForPrefs(recipientProfile.prefs, "chat_messages", "enable_chat_notifications")) {
      console.log(`[push-message] skip_disabled_chat id=${requestId}`, { recipientId });
      return jsonResponse({ ok: true, sent: 0, skipped: "disabled" });
    }

    const recipientTokens = await loadUserTokens(recipientId);
    console.log(`[push-message] tokens id=${requestId}`, { recipientTokens: recipientTokens.length });
    if (recipientTokens.length === 0) {
      // No push target (desktop with no FCM registration, uninstalled
      // client): best-effort email so the mention isn't silently lost.
      // Gated by the same chat-push preference checked above.
      const emailed = await sendOfflineMentionEmail({
        adminClient,
        recipientId,
        senderName,
        matchId,
        locale: recipientProfile.locale,
        requestId,
      });
      return jsonResponse({ ok: true, sent: 0, emailFallback: emailed });
    }

    const senderTokens = await loadUserTokens(senderId);
    const senderTokenSet = new Set(senderTokens);
    const uniqueTokens = senderTokenSet.size === 0
      ? recipientTokens
      : recipientTokens.filter((t) => !senderTokenSet.has(t));

    if (uniqueTokens.length !== recipientTokens.length) {
      console.log(`[push-message] tokens_filtered id=${requestId}`, {
        excluded: recipientTokens.length - uniqueTokens.length,
      });
    }

    if (uniqueTokens.length === 0) {
      return jsonResponse({ ok: true, sent: 0 });
    }

    const badge = await fetchBadgeCount(adminClient, recipientId);

    const results = await Promise.allSettled(
      uniqueTokens.map((token) =>
        sendFcmV1({
          serviceAccount,
          accessToken,
          token,
          notification,
          data,
          tag: `match_${matchId}`,
          collapseKey: `match_${matchId}`,
          channelId: "chat_messages",
          badge,
        })
      ),
    );

  const successes: unknown[] = [];
  const failures: unknown[] = [];
  for (const r of results) {
    if (r.status === "fulfilled") {
      if (r.value.ok) successes.push(r.value.body);
      else failures.push({ status: r.value.status, body: r.value.body });
    } else {
      failures.push({ error: String(r.reason) });
    }
  }

    let emailFallback = false;
    if (successes.length === 0 && failures.length > 0) {
      // Tokens exist but all sends failed (stale/uninstalled): same fallback.
      emailFallback = await sendOfflineMentionEmail({
        adminClient,
        recipientId,
        senderName,
        matchId,
        locale: recipientProfile.locale,
        requestId,
      });
    }
    const response = {
      ok: true,
      requested: uniqueTokens.length,
      sent: successes.length,
      failed: failures.length,
      failures,
      emailFallback,
    };

    console.log(`[push-message] result id=${requestId}`, {
      requested: response.requested,
      sent: response.sent,
      failed: response.failed,
      emailFallback,
    });

    return jsonResponse(response);
  } catch (e) {
    console.error(`[push-message] unhandled id=${requestId}`, String(e));
    errorType = e instanceof Error ? e.name : "Error";
    errorMessage = e instanceof Error ? e.message : String(e);
    return jsonResponse({ error: "Unhandled error", detail: String(e) }, 500);
  } finally {
    const elapsedMs = Date.now() - startedAtMs;
    console.log(`[push-message] end id=${requestId} ms=${elapsedMs}`);
    if (req.method !== "OPTIONS") {
      await logEdgeFunctionInvocation({
        requestId,
        functionName,
        durationMs: elapsedMs,
        success,
        httpStatus,
        errorType,
        errorMessage,
        aiUsed: false,
        meta: { method: req.method },
      });
    }
  }
});
