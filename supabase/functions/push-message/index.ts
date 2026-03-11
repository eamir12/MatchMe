import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";

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

async function sendFcmV1({
  serviceAccount,
  accessToken,
  token,
  notification,
  data,
}: {
  serviceAccount: ServiceAccount;
  accessToken: string;
  token: string;
  notification: { title: string; body: string };
  data: Record<string, string>;
}): Promise<{ ok: boolean; status: number; body: unknown }> {
  const projectId = serviceAccount.project_id.trim();
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  const body = {
    message: {
      token,
      notification,
      data,
      android: { priority: "HIGH" },
      apns: {
        headers: { "apns-priority": "10" },
        payload: { aps: { sound: "default" } },
      },
      webpush: {
        headers: { TTL: "60" },
        notification: {
          icon: "/icons/Icon-192.png",
          badge: "/icons/Icon-192.png",
        },
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

    const mode = messageId ? "message" : ((rawKind === "match" || isMatchWebhook) ? "match" : "");
    if (!mode) {
      return jsonResponse({ error: "Invalid payload: expected message_id or kind=match" }, 400);
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
        .select("id, name")
        .in("id", [user1Id, user2Id]);

      const usersById = new Map<string, string>();
      for (const row of (usersRows ?? []) as unknown[]) {
        const r = row as Record<string, unknown>;
        const id = String(r["id"] ?? "").trim();
        const name = String(r["name"] ?? "").trim();
        if (id) usersById.set(id, name);
      }

      const { data: profilesRows } = await adminClient
        .from("user_profiles")
        .select("user_id, profile_data")
        .in("user_id", [user1Id, user2Id]);

      const profileNamesById = new Map<string, string>();
      for (const row of (profilesRows ?? []) as unknown[]) {
        const r = row as Record<string, unknown>;
        const id = String(r["user_id"] ?? "").trim();
        const pd = r["profile_data"] as Record<string, unknown> | null | undefined;
        const fullName = String(pd?.["fullName"] ?? "").trim();
        if (id && fullName) profileNamesById.set(id, fullName);
      }

      const displayNameFor = (userId: string): string => {
        return (
          profileNamesById.get(userId) ||
          usersById.get(userId) ||
          "Someone"
        );
      };

      const recipients = [user1Id, user2Id];

      const sends = await Promise.allSettled(
        recipients.map(async (recipientId) => {
          const otherUserId = recipientId === user1Id ? user2Id : user1Id;
          const otherName = displayNameFor(otherUserId);
          const tokens = await loadUserTokens(recipientId);
          console.log(`[push-message] tokens id=${requestId}`, {
            recipientId,
            tokens: tokens.length,
          });
          if (tokens.length === 0) return { recipientId, requested: 0, sent: 0, failed: 0, failures: [] as unknown[] };

          const notification = {
            title: "New Match!",
            body: `You matched with ${otherName}`,
          };
          const data = {
            matchId,
            tabIndex: "1",
            otherUserId,
            kind: "match",
          };

          const results = await Promise.allSettled(
            tokens.map((token) =>
              sendFcmV1({ serviceAccount, accessToken, token, notification, data })
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

    if (!anonKey) {
      return jsonResponse({ error: "Missing SUPABASE_ANON_KEY" }, 500);
    }

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
    const authedUserId = userData?.user?.id ?? "";
    if (userErr || !authedUserId) {
      console.log(`[push-message] unauthorized id=${requestId}`);
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    console.log(`[push-message] authed id=${requestId}`, { authedUserId });

    const { data: messageRow, error: msgErr } = await adminClient
      .from("chat_messages")
      .select("id, match_id, sender_id, content_original, content_translated, created_at")
      .eq("id", messageId)
      .maybeSingle();

    if (msgErr || !messageRow) {
      console.log(`[push-message] message_not_found id=${requestId}`, { messageId });
      return jsonResponse({ error: "Message not found" }, 404);
    }

    const matchId = String(messageRow.match_id ?? "").trim() || matchIdHint;
    if (!matchId) return jsonResponse({ error: "match_id not found" }, 400);

    const senderId = String(messageRow.sender_id ?? "").trim();
    if (!senderId) return jsonResponse({ error: "sender_id not found" }, 400);

    if (authedUserId !== senderId) {
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
      if (!participantIds.has(authedUserId)) {
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

    const { data: senderProfile } = await adminClient
      .from("user_profiles")
      .select("profile_data")
      .eq("user_id", senderId)
      .maybeSingle();

    const senderName =
      (senderProfile?.profile_data?.fullName as string | undefined)?.trim() ||
      "New message";

    const messageText = String(
      (messageRow.content_translated ?? messageRow.content_original ?? "") as string,
    ).trim();

    const recipientTokens = await loadUserTokens(recipientId);
    console.log(`[push-message] tokens id=${requestId}`, { recipientTokens: recipientTokens.length });
    if (recipientTokens.length === 0) {
      return jsonResponse({ ok: true, sent: 0 });
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

    const notification = {
      title: senderName,
      body: messageText.length > 0 ? messageText : "New message",
    };
    const data = {
      matchId,
      route: `/chat/${matchId}`,
      messageId,
      senderId,
      recipientId,
    };

    const results = await Promise.allSettled(
      uniqueTokens.map((token) =>
        sendFcmV1({ serviceAccount, accessToken, token, notification, data })
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

    const response = {
      ok: true,
      requested: uniqueTokens.length,
      sent: successes.length,
      failed: failures.length,
      failures,
    };

    console.log(`[push-message] result id=${requestId}`, {
      requested: response.requested,
      sent: response.sent,
      failed: response.failed,
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
