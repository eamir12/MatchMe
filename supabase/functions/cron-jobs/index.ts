// supabase/functions/cron-jobs/index.ts
import { serve } from 'std/http/server.ts';
import { createClient } from 'supabase';
import { RRule } from 'rrule-deno';
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";

// Initialize Supabase Admin Client
const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { auth: { persistSession: false } }
);

const _translationCache = new Map<string, string>();
const _translationFallbacks: Record<string, string> = {
  adminAiQuotaWarnTitle: 'AI quota warning',
  adminAiQuotaCriticalTitle: 'AI quota critical',
  adminAiQuotaAlertBody: '{provider}: {used}/{limit} {unit} used ({percent}%)',
  adminAiQuotaAlertBodyNoLimit: '{provider}: {used} {unit} used',
  adminAiProviderDeepL: 'DeepL',
  adminAiProviderGemini: 'Gemini',
  adminAiQuotaStatusOk: 'OK',
  adminAiQuotaStatusWarn: 'Warning',
  adminAiQuotaStatusCritical: 'Critical',
  adminAiQuotaStatusUnknown: 'Unknown',
};

async function getTranslation(locale: string, key: string): Promise<string> {
  const normalizedLocale = String(locale ?? '').trim().toLowerCase() || 'en';
  const normalizedKey = String(key ?? '').trim();
  const cacheKey = `${normalizedLocale}|${normalizedKey}`;
  const cached = _translationCache.get(cacheKey);
  if (cached != null) return cached;

  try {
    const { data, error } = await supabase
      .from('translations')
      .select('value')
      .eq('locale', normalizedLocale)
      .eq('key', normalizedKey)
      .maybeSingle();
    if (!error) {
      const value = String((data as Record<string, unknown> | null | undefined)?.value ?? '').trim();
      if (value) {
        _translationCache.set(cacheKey, value);
        return value;
      }
    }
  } catch {
  }

  const fallback = _translationFallbacks[normalizedKey] ?? normalizedKey;
  _translationCache.set(cacheKey, fallback);
  return fallback;
}

function tokenPrefix(value: string, prefixLen = 12): string {
  const v = String(value ?? '');
  if (!v) return '';
  return v.slice(0, Math.min(prefixLen, v.length));
}

const rtlScriptRegex = /[\u0590-\u08FF]/;

function wrapRtlIfNeeded(value: string): string {
  const v = String(value ?? '');
  if (!v) return v;
  if (!rtlScriptRegex.test(v)) return v;
  if (v.includes('\u2067') || v.includes('\u2066') || v.includes('\u202B')) return v;
  return `\u2067${v}\u2069`;
}

function getErrorInfo(error: unknown): Record<string, unknown> {
  if (!error) return { error: String(error) };
  if (error instanceof Error) {
    return {
      name: error.name,
      message: error.message,
      stack: error.stack,
      ...((error as unknown as Record<string, unknown>) ?? {}),
    };
  }
  if (typeof error === 'object') return { ...(error as Record<string, unknown>) };
  return { error: String(error) };
}

function log(invocationId: string, message: string, details?: Record<string, unknown>) {
  if (details) {
    console.log(`[cron-jobs][${invocationId}] ${message}`, JSON.stringify(details));
    return;
  }
  console.log(`[cron-jobs][${invocationId}] ${message}`);
}

function logError(invocationId: string, message: string, error: unknown, details?: Record<string, unknown>) {
  const payload = { ...(details ?? {}), error: getErrorInfo(error) };
  console.error(`[cron-jobs][${invocationId}] ${message}`, JSON.stringify(payload));
}

type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
};

function base64UrlEncodeBytes(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  const base64 = btoa(binary);
  return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function base64UrlEncodeJson(obj: Record<string, unknown>): string {
  const json = JSON.stringify(obj);
  const bytes = new TextEncoder().encode(json);
  return base64UrlEncodeBytes(bytes);
}

function pemToDerBytes(pem: string): Uint8Array {
  const normalized = pem
    .replace(/-----BEGIN [^-]+-----/g, '')
    .replace(/-----END [^-]+-----/g, '')
    .replace(/\s+/g, '')
    .trim();
  const raw = atob(normalized);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

let cachedAccessToken: string | null = null;
let cachedAccessTokenExpiryMs = 0;

async function getFcmAccessToken(serviceAccount: ServiceAccount): Promise<string> {
  const nowMs = Date.now();
  if (cachedAccessToken && nowMs + 60_000 < cachedAccessTokenExpiryMs) {
    return cachedAccessToken;
  }

  const tokenUri = String(serviceAccount.token_uri ?? '').trim() || 'https://oauth2.googleapis.com/token';
  const iat = Math.floor(nowMs / 1000);
  const exp = iat + 3600;
  const claims = {
    iss: serviceAccount.client_email,
    sub: serviceAccount.client_email,
    aud: tokenUri,
    iat,
    exp,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
  };

  const header = { alg: 'RS256', typ: 'JWT' };
  const signingInput = `${base64UrlEncodeJson(header)}.${base64UrlEncodeJson(claims)}`;

  const keyBytes = pemToDerBytes(serviceAccount.private_key);
  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    keyBytes.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  const signature = await crypto.subtle.sign(
    { name: 'RSASSA-PKCS1-v1_5' },
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  const jwt = `${signingInput}.${base64UrlEncodeBytes(new Uint8Array(signature))}`;

  const form = new URLSearchParams();
  form.set('grant_type', 'urn:ietf:params:oauth:grant-type:jwt-bearer');
  form.set('assertion', jwt);

  const resp = await fetch(tokenUri, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
  });
  const raw = await resp.text();
  if (!resp.ok) {
    throw new Error(`OAuth token exchange failed status=${resp.status} body=${raw}`);
  }

  const parsed = JSON.parse(raw) as { access_token?: string; expires_in?: number };
  if (!parsed.access_token) throw new Error('OAuth token exchange missing access_token');
  const expiresInSec = typeof parsed.expires_in === 'number' ? parsed.expires_in : 3600;

  cachedAccessToken = parsed.access_token;
  cachedAccessTokenExpiryMs = nowMs + expiresInSec * 1000;
  return parsed.access_token;
}

const _googleAccessTokenCache = new Map<string, { token: string; expiryMs: number }>();

async function getGoogleAccessToken({
  serviceAccount,
  scope,
}: {
  serviceAccount: ServiceAccount;
  scope: string;
}): Promise<string> {
  const nowMs = Date.now();
  const cacheKey = `${serviceAccount.client_email}|${scope}`;
  const cached = _googleAccessTokenCache.get(cacheKey);
  if (cached && nowMs + 60_000 < cached.expiryMs) return cached.token;

  const tokenUri =
    String(serviceAccount.token_uri ?? '').trim() || 'https://oauth2.googleapis.com/token';
  const iat = Math.floor(nowMs / 1000);
  const exp = iat + 3600;
  const claims = {
    iss: serviceAccount.client_email,
    sub: serviceAccount.client_email,
    aud: tokenUri,
    iat,
    exp,
    scope,
  };

  const header = { alg: 'RS256', typ: 'JWT' };
  const signingInput = `${base64UrlEncodeJson(header)}.${base64UrlEncodeJson(claims)}`;

  const keyBytes = pemToDerBytes(serviceAccount.private_key);
  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    keyBytes.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  const signature = await crypto.subtle.sign(
    { name: 'RSASSA-PKCS1-v1_5' },
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  const jwt = `${signingInput}.${base64UrlEncodeBytes(new Uint8Array(signature))}`;

  const form = new URLSearchParams();
  form.set('grant_type', 'urn:ietf:params:oauth:grant-type:jwt-bearer');
  form.set('assertion', jwt);

  const resp = await fetch(tokenUri, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
  });
  const raw = await resp.text();
  if (!resp.ok) {
    throw new Error(`OAuth token exchange failed status=${resp.status} body=${raw}`);
  }

  const parsed = JSON.parse(raw) as { access_token?: string; expires_in?: number };
  if (!parsed.access_token) throw new Error('OAuth token exchange missing access_token');
  const expiresInSec = typeof parsed.expires_in === 'number' ? parsed.expires_in : 3600;
  const entry = { token: parsed.access_token, expiryMs: nowMs + expiresInSec * 1000 };
  _googleAccessTokenCache.set(cacheKey, entry);
  return entry.token;
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
  const title = wrapRtlIfNeeded(notification.title);
  const bodyText = wrapRtlIfNeeded(notification.body);
  const body = {
    message: {
      token,
      notification: { title, body: bodyText },
      data,
      android: { priority: 'HIGH' },
      apns: {
        headers: { 'apns-priority': '10' },
        payload: { aps: { sound: 'default' } },
      },
      webpush: {
        headers: { TTL: '60' },
        notification: {
          icon: '/icons/Icon-192.png',
          badge: '/icons/Icon-192.png',
        },
      },
    },
  };

  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json; charset=utf-8',
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

function coerceStringRecord(value: unknown): Record<string, string> {
  let normalized: unknown = value;
  if (typeof normalized === 'string') {
    const trimmed = normalized.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        normalized = JSON.parse(trimmed) as unknown;
      } catch {
        return {};
      }
    } else {
      return {};
    }
  }

  if (!normalized || typeof normalized !== 'object' || Array.isArray(normalized)) return {};
  const v = normalized as Record<string, unknown>;
  const out: Record<string, string> = {};
  for (const [k, val] of Object.entries(v)) {
    if (!k) continue;
    if (val === null || val === undefined) continue;
    if (typeof val === 'string') {
      out[k] = val;
      continue;
    }

    if (typeof val === 'number' || typeof val === 'boolean' || typeof val === 'bigint') {
      out[k] = String(val);
      continue;
    }

    if ((k === 'action_url' || k.endsWith('_url')) && val && typeof val === 'object' && !Array.isArray(val)) {
      const objVal = val as Record<string, unknown>;
      const candidate =
        (typeof objVal.url === 'string' && objVal.url.trim()) ||
        (typeof objVal.href === 'string' && objVal.href.trim()) ||
        (typeof objVal.value === 'string' && objVal.value.trim()) ||
        '';
      if (candidate) {
        out[k] = candidate;
        continue;
      }
    }

    out[k] = JSON.stringify(val);
  }
  return out;
}

function isFcmUnregistered(status: number, body: unknown): boolean {
  if (status !== 404 || !body || typeof body !== 'object' || Array.isArray(body)) return false;
  const err = (body as Record<string, unknown>).error;
  if (!err || typeof err !== 'object' || Array.isArray(err)) return false;
  const details = (err as Record<string, unknown>).details;
  if (!Array.isArray(details)) return false;
  for (const d of details) {
    if (!d || typeof d !== 'object' || Array.isArray(d)) continue;
    const code = (d as Record<string, unknown>).errorCode;
    if (typeof code === 'string' && code.trim().toUpperCase() === 'UNREGISTERED') return true;
  }
  return false;
}

async function getChatStartWindowSeconds(): Promise<number> {
  try {
    const { data, error } = await supabase
      .from('app_config')
      .select('config_value')
      .eq('config_key', 'matches.chat_start_window_seconds')
      .maybeSingle();

    if (error) throw error;
    const parsed = Number.parseInt(String(data?.config_value ?? ''), 10);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 86400;
  } catch {
    return 86400;
  }
}

async function cleanupExpiredMatches() {
  console.log('Running Expired Match Cleanup...');
  try {
    const chatStartWindowSeconds = await getChatStartWindowSeconds();
    const cutoffIso = new Date(Date.now() - chatStartWindowSeconds * 1000).toISOString();

    const { data, error } = await supabase.rpc('cleanup_expired_matches', {
      p_cutoff: cutoffIso,
      p_limit: 500,
    });

    if (error) {
      console.error('Expired Match Cleanup RPC error:', error);
      throw error;
    }

    const deletedCount = typeof data === 'number' ? data : Number(data ?? 0);
    console.log(`Expired Match Cleanup completed successfully. Deleted: ${deletedCount}`);
  } catch (error) {
    console.error('Error during Expired Match Cleanup:', error.message);
    throw error;
  }
}

/**
 * Task 1: Enforces user-defined invisibility schedules.
 */
async function handleInvisibilitySchedules() {
  console.log('Running Invisibility Scheduler...');
  try {
    // Reset system_visibility_status to 'visible' only for users who are manually visible
    // (don't override users who manually set themselves to invisible)
    await supabase.from('users')
      .update({ system_visibility_status: 'visible' })
      .eq('user_visibility_setting', true)
      .eq('system_visibility_status', 'invisible');
    console.log('Scheduler: Reset system visibility to visible for manually visible users who were system-invisible.');

    const { data: schedules, error: scheduleError } = await supabase
      .from('user_visibility_schedules')
      .select('user_id, rrule')
      .eq('is_active', true);

    if (scheduleError) throw scheduleError;
    if (!schedules || schedules.length === 0) {
      console.log('Scheduler: No active schedules found.');
      return; // Exit if no rules to apply
    }

    const now = new Date();
    const usersToMakeInvisible = new Set<string>();

    for (const schedule of schedules) {
      if (!schedule.rrule) {
          console.warn(`Scheduler: Skipping schedule for user ${schedule.user_id} due to missing rrule.`);
          continue;
      }
      try {
        // Need to ensure the rrule string includes a DTSTART
        // Let's assume it does for now, or add parsing/defaulting if needed
        const rule = RRule.fromString(schedule.rrule);
        // Find occurrences between now and a very short time after now
        const occurrences = rule.between(now, new Date(now.getTime() + 60000), true); // Check within the next minute

        if (occurrences.length > 0) {
            // Check if 'now' falls within an "invisible" duration based on rule interpretation
            // RRule itself generates start times. We need logic to determine duration.
            // Simplified: If an occurrence starts *now* or *just before now*, consider invisible.
            // This needs a more robust duration logic based on your RRule format.
            // For example, if RRule defines START and END/DURATION.
            // Let's assume for now: if a rule matches *at all* in this check, user is invisible.
            usersToMakeInvisible.add(schedule.user_id);
        }
      } catch (rruleError) {
        console.error(`Scheduler: Skipping bad rrule for user ${schedule.user_id}: ${schedule.rrule} - ${rruleError.message}`);
      }
    }

    // Batch-update users in PostgreSQL to be invisible (only if they are manually visible)
    if (usersToMakeInvisible.size > 0) {
      const userIds = Array.from(usersToMakeInvisible);
      console.log(`Scheduler: Setting ${userIds.length} users to invisible based on schedule (only if manually visible).`);
      const { error: updateError } = await supabase
        .from('users')
        .update({ system_visibility_status: 'invisible' })
        .in('id', userIds)
        .eq('user_visibility_setting', true);
    } else {
        console.log('Scheduler: No users need to be set to invisible based on current schedules.');
    }

  } catch (error) {
    console.error('Error during Invisibility scheduling:', error.message);
    throw error;
  }
}

/**
 * Task 2: Performs continuous event matching for all events
 */
async function handleContinuousEventMatching() {
  console.log('Running Continuous Event Matching...');
  try {
    const { data, error } = await supabase.rpc('perform_continuous_event_matching');

    if (error) {
      console.error('Error during continuous event matching:', error);
      throw error;
    }

    console.log('Continuous Event Matching completed successfully.');
  } catch (error) {
    console.error('Error during Continuous Event Matching:', error.message);
    throw error;
  }
}

/**
 * Task 3: Performs continuous user proximity matching for all users
 */
async function handleContinuousUserMatching() {
  console.log('Running Continuous User Matching...');
  try {
    const { data, error } = await supabase.rpc('perform_continuous_user_matching');

    if (error) {
      console.error('Error during continuous user matching:', error);
      throw error;
    }

    console.log('Continuous User Matching completed successfully.');
  } catch (error) {
    console.error('Error during Continuous User Matching:', error.message);
    throw error;
  }
}

async function handleCleanupOrphanProfilePhotos(invocationId: string) {
  log(invocationId, 'Running Orphan Profile Photo Cleanup...');
  try {
    const minAgeMinutes = 1440;
    const limit = 500;

    let totalDeleted = 0;
    for (;;) {
      const { data, error } = await supabase.rpc('list_orphan_profile_photos', {
        p_min_age_minutes: minAgeMinutes,
        p_limit: limit,
      });
      if (error) throw error;

      const rows = Array.isArray(data) ? data : [];
      const names = rows
        .map((r) => (r && typeof r === 'object' ? String((r as Record<string, unknown>).name ?? '') : ''))
        .filter((v) => v.length > 0);

      if (names.length === 0) break;

      const { error: removeError } = await supabase.storage.from('profile-photos').remove(names);
      if (removeError) throw removeError;

      totalDeleted += names.length;
      if (names.length < limit) break;
    }

    log(invocationId, 'Orphan Profile Photo Cleanup completed.', { deletedCount: totalDeleted });
  } catch (error) {
    logError(invocationId, 'Error during Orphan Profile Photo Cleanup', error);
    throw error;
  }
}

async function handleScheduledAdminBroadcasts(invocationId: string) {
  log(invocationId, 'Processing Scheduled Admin Broadcasts...');
  try {
    const nowIso = new Date().toISOString();
    log(invocationId, 'Looking for scheduled broadcasts', { nowIso });
    const { data: broadcasts, error } = await supabase
      .from('admin_broadcasts')
      .select('id,status,scheduled_at,created_at,updated_at')
      .not('scheduled_at', 'is', null)
      .lte('scheduled_at', nowIso)
      .in('status', ['scheduled'])
      .limit(25);

    if (error) throw error;
    if (!broadcasts || broadcasts.length === 0) {
      log(invocationId, 'No scheduled broadcasts to send.');
      return;
    }

    log(invocationId, 'Scheduled broadcasts found', { count: broadcasts.length });

    let hadError = false;
    for (const b of broadcasts as Array<{ id: string; status?: string; scheduled_at?: string; created_at?: string; updated_at?: string }>) {
      const broadcastId = String(b.id ?? '').trim();
      if (!broadcastId) continue;
      log(invocationId, 'Sending scheduled broadcast', {
        broadcastId,
        status: b.status ?? null,
        scheduledAt: b.scheduled_at ?? null,
        createdAt: b.created_at ?? null,
        updatedAt: b.updated_at ?? null,
      });
      const { error: sendError } = await supabase.rpc('send_admin_broadcast', {
        broadcast_id: broadcastId,
      });
      if (sendError) {
        logError(invocationId, 'send_admin_broadcast RPC error', sendError, { broadcastId });
        hadError = true;
        await supabase
          .from('admin_broadcasts')
          .update({ status: 'failed', updated_at: new Date().toISOString() })
          .eq('id', broadcastId);
        continue;
      }
      log(invocationId, 'send_admin_broadcast RPC succeeded', { broadcastId });
    }
    if (hadError) {
      throw new Error('One or more scheduled broadcasts failed.');
    }
  } catch (error) {
    logError(invocationId, 'Error during Scheduled Admin Broadcasts', error);
    throw error;
  }
}

/**
 * Task 4: Processes pending FCM notifications from the notification queue
 */
async function handleNotificationQueueProcessing(invocationId: string) {
  log(invocationId, 'Processing Notification Queue...');
  try {
    const fcmServiceAccountJson = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON') ?? '';
    if (!fcmServiceAccountJson) {
      throw new Error('Missing FCM_SERVICE_ACCOUNT_JSON');
    }

    let serviceAccount: ServiceAccount;
    try {
      serviceAccount = JSON.parse(fcmServiceAccountJson) as ServiceAccount;
    } catch (_) {
      throw new Error('FCM_SERVICE_ACCOUNT_JSON is not valid JSON');
    }
    if (!serviceAccount?.project_id || !serviceAccount?.client_email || !serviceAccount?.private_key) {
      throw new Error('FCM_SERVICE_ACCOUNT_JSON must include project_id, client_email, private_key');
    }

    log(invocationId, 'FCM service account loaded', {
      projectId: serviceAccount.project_id,
      clientEmail: serviceAccount.client_email,
      tokenUri: serviceAccount.token_uri ?? 'https://oauth2.googleapis.com/token',
    });

    const accessToken = await getFcmAccessToken(serviceAccount);
    const nowIso = new Date().toISOString();
    log(invocationId, 'FCM access token acquired', { nowIso });

    const { data: pendingRows, error: listError } = await supabase
      .from('notification_queue')
      .select('id,user_id,fcm_token,title,body,data,platform,status,attempts,max_attempts,scheduled_at,created_at')
      .eq('status', 'pending')
      .lte('scheduled_at', nowIso)
      .order('created_at', { ascending: true })
      .limit(100);

    if (listError) throw listError;
    const rows = (pendingRows ?? []) as Array<Record<string, unknown>>;
    if (rows.length === 0) {
      log(invocationId, 'No pending notifications ready to send.', { nowIso });
      return;
    }

    const broadcastRows = rows.filter((r) => {
      const data = r.data as Record<string, unknown> | null | undefined;
      return (data?.type ?? '') === 'admin_broadcast';
    });

    log(invocationId, 'Pending notifications fetched', {
      count: rows.length,
      adminBroadcastCount: broadcastRows.length,
      firstCreatedAt: rows.length ? String(rows[0]?.created_at ?? '') : null,
      lastCreatedAt: rows.length ? String(rows[rows.length - 1]?.created_at ?? '') : null,
    });

    let processed = 0;

    for (const row of rows) {
      const id = String(row.id ?? '').trim();
      const userId = String(row.user_id ?? '').trim();
      const token = String(row.fcm_token ?? '').trim();
      const title = String(row.title ?? '').trim();
      const body = String(row.body ?? '').trim();
      const attempts = Number(row.attempts ?? 0);
      const maxAttempts = Number(row.max_attempts ?? 3);
      const data = coerceStringRecord(row.data);

      if (!id || !token || !title) continue;

      const nextAttempts = attempts + 1;
      log(invocationId, 'Attempting to claim queue row', {
        id,
        userId: userId || null,
        platform: String(row.platform ?? '') || null,
        attempts,
        nextAttempts,
        maxAttempts,
        scheduledAt: String(row.scheduled_at ?? '') || null,
        createdAt: String(row.created_at ?? '') || null,
        fcmTokenPrefix: tokenPrefix(token),
        dataType: data.type ?? null,
        broadcastId: data.broadcast_id ?? null,
      });
      const { data: updated, error: markError } = await supabase
        .from('notification_queue')
        .update({
          status: 'processing',
          attempts: nextAttempts,
          updated_at: new Date().toISOString(),
        })
        .eq('id', id)
        .eq('status', 'pending')
        .select('id')
        .maybeSingle();

      if (markError || !updated) {
        if (markError) {
          logError(invocationId, 'Failed to mark row as processing', markError, { id });
        } else {
          log(invocationId, 'Row not claimed (no longer pending)', { id });
        }
        continue;
      }

      log(invocationId, 'Row claimed', { id, nextAttempts });

      try {
        const result = await sendFcmV1({
          serviceAccount,
          accessToken,
          token,
          notification: { title, body },
          data,
        });

        if (result.ok) {
          await supabase
            .from('notification_queue')
            .update({
              status: 'sent',
              sent_at: new Date().toISOString(),
              failure_reason: null,
              updated_at: new Date().toISOString(),
            })
            .eq('id', id);

          if (data.type === 'admin_broadcast' && data.broadcast_id && userId) {
            await supabase
              .from('admin_broadcast_deliveries')
              .update({
                delivery_status: 'sent',
              })
              .eq('broadcast_id', data.broadcast_id)
              .eq('user_id', userId);
          }

          processed += 1;
          log(invocationId, 'FCM send succeeded', {
            id,
            userId: userId || null,
            platform: String(row.platform ?? '') || null,
            fcmTokenPrefix: tokenPrefix(token),
            dataType: data.type ?? null,
            broadcastId: data.broadcast_id ?? null,
            fcmStatus: result.status,
          });
          continue;
        }

        const unregistered = isFcmUnregistered(result.status, result.body);
        const shouldFail = unregistered || nextAttempts >= maxAttempts;
        const retryAt = new Date(Date.now() + Math.min(60, 5 * nextAttempts) * 60_000).toISOString();

        log(invocationId, 'FCM send failed', {
          id,
          shouldFail,
          retryAt: shouldFail ? null : retryAt,
          nextAttempts,
          maxAttempts,
          fcmStatus: result.status,
          fcmBody: result.body,
          dataType: data.type ?? null,
          broadcastId: data.broadcast_id ?? null,
          fcmTokenPrefix: tokenPrefix(token),
        });

        if (unregistered) {
          try {
            await supabase.rpc('clear_user_session_fcm_token', { p_fcm_token: token });
          } catch (e) {
            logError(invocationId, 'Failed to clear UNREGISTERED FCM token', e, {
              fcmTokenPrefix: tokenPrefix(token),
            });
          }
        }

        const queueUpdate: Record<string, unknown> = {
          status: shouldFail ? 'failed' : 'pending',
          failure_reason: `FCM status=${result.status} body=${JSON.stringify(result.body)}`,
          updated_at: new Date().toISOString(),
        };
        if (!shouldFail) queueUpdate.scheduled_at = retryAt;

        await supabase
          .from('notification_queue')
          .update(queueUpdate)
          .eq('id', id);

        if (data.type === 'admin_broadcast' && data.broadcast_id && userId) {
          await supabase
            .from('admin_broadcast_deliveries')
            .update({
              delivery_status: 'failed',
              failure_reason: `FCM status=${result.status}`,
            })
            .eq('broadcast_id', data.broadcast_id)
            .eq('user_id', userId)
            .eq('delivery_status', 'pending');
        }
      } catch (sendError) {
        const shouldFail = nextAttempts >= maxAttempts;
        const retryAt = new Date(Date.now() + Math.min(60, 5 * nextAttempts) * 60_000).toISOString();
        const errorMessage = sendError instanceof Error ? sendError.message : String(sendError);

        logError(invocationId, 'FCM send threw error', sendError, {
          id,
          shouldFail,
          retryAt: shouldFail ? null : retryAt,
          nextAttempts,
          maxAttempts,
          dataType: data.type ?? null,
          broadcastId: data.broadcast_id ?? null,
          fcmTokenPrefix: tokenPrefix(token),
        });

        const queueUpdate: Record<string, unknown> = {
          status: shouldFail ? 'failed' : 'pending',
          failure_reason: errorMessage,
          updated_at: new Date().toISOString(),
        };
        if (!shouldFail) queueUpdate.scheduled_at = retryAt;

        await supabase
          .from('notification_queue')
          .update(queueUpdate)
          .eq('id', id);

        if (data.type === 'admin_broadcast' && data.broadcast_id && userId) {
          await supabase
            .from('admin_broadcast_deliveries')
            .update({
              delivery_status: 'failed',
              failure_reason: errorMessage,
            })
            .eq('broadcast_id', data.broadcast_id)
            .eq('user_id', userId)
            .eq('delivery_status', 'pending');
        }
      }
    }

    log(invocationId, 'Notification Queue Processing completed successfully.', { sent: processed });
  } catch (error) {
    logError(invocationId, 'Error during Notification Queue Processing', error);
    throw error;
  }
}

function _toNum(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  const parsed = Number(String(value ?? '').trim());
  if (!Number.isFinite(parsed)) return null;
  return parsed;
}

function _toInt(value: unknown): number | null {
  const n = _toNum(value);
  if (n == null) return null;
  return Math.trunc(n);
}

function _ratio(used: number | null, limit: number | null): number | null {
  if (used == null || limit == null) return null;
  if (!Number.isFinite(used) || !Number.isFinite(limit)) return null;
  if (limit <= 0) return null;
  return used / limit;
}

function _statusForRatio(ratio: number | null): 'ok' | 'warn' | 'critical' | 'unknown' {
  if (ratio == null) return 'unknown';
  if (ratio >= 0.95) return 'critical';
  if (ratio >= 0.8) return 'warn';
  return 'ok';
}

async function _upsertQuotaStatus({
  invocationId,
  provider,
  metric,
  window,
  used,
  limit,
  unit,
  status,
  startTime,
  endTime,
  details,
}: {
  invocationId: string;
  provider: string;
  metric: string;
  window: string;
  used: number | null;
  limit: number | null;
  unit: string;
  status: 'ok' | 'warn' | 'critical' | 'unknown';
  startTime?: string | null;
  endTime?: string | null;
  details: Record<string, unknown>;
}) {
  const payload: Record<string, unknown> = {
    provider,
    metric,
    window_key: window,
    used,
    limit_value: limit,
    unit,
    status,
    start_time: startTime ?? null,
    end_time: endTime ?? null,
    details,
    updated_at: new Date().toISOString(),
  };

  const { error } = await supabase
    .from('ai_quota_status')
    .upsert(payload, { onConflict: 'provider,metric,window_key' });
  if (error) {
    logError(invocationId, 'Failed to upsert ai_quota_status', error, {
      provider,
      metric,
      window,
    });
    throw error;
  }
}

function _pushEnabled(notificationPreferences: unknown): boolean {
  if (!notificationPreferences || typeof notificationPreferences !== 'object' || Array.isArray(notificationPreferences)) {
    return true;
  }
  const np = notificationPreferences as Record<string, unknown>;
  const globalMethods = np.global_methods;
  if (globalMethods && typeof globalMethods === 'object' && !Array.isArray(globalMethods)) {
    const push = (globalMethods as Record<string, unknown>).push;
    if (push === false) return false;
  }
  const matrix = np.matrix;
  if (matrix && typeof matrix === 'object' && !Array.isArray(matrix)) {
    const admin = (matrix as Record<string, unknown>).admin_announcements;
    if (admin && typeof admin === 'object' && !Array.isArray(admin)) {
      const push = (admin as Record<string, unknown>).push;
      if (push === false) return false;
    }
  }
  const legacy = np.enable_admin_notifications;
  if (legacy === false) return false;
  return true;
}

async function _listAdminNotificationTargets(invocationId: string): Promise<Array<{
  userId: string;
  locale: string;
  token: string;
  platform: string;
}>> {
  const { data: adminUsers, error: adminErr } = await supabase
    .from('users')
    .select('id,preferred_language,notification_preferences,is_admin')
    .eq('is_admin', true)
    .limit(500);
  if (adminErr) throw adminErr;
  const admins = (adminUsers ?? []) as Array<Record<string, unknown>>;
  const adminIds = admins.map((u) => String(u.id ?? '').trim()).filter((v) => v.length > 0);
  if (adminIds.length === 0) return [];

  const userById = new Map<string, { locale: string; notificationPreferences: unknown }>();
  for (const u of admins) {
    const id = String(u.id ?? '').trim();
    if (!id) continue;
    const locale = String(u.preferred_language ?? 'en').trim().toLowerCase() || 'en';
    userById.set(id, { locale, notificationPreferences: u.notification_preferences });
  }

  const { data: sessions, error: sessErr } = await supabase
    .from('user_session')
    .select('user_id,platform,metadata,revoked')
    .eq('revoked', false)
    .in('user_id', adminIds)
    .limit(5000);
  if (sessErr) throw sessErr;

  const out: Array<{ userId: string; locale: string; token: string; platform: string }> = [];
  const seen = new Set<string>();
  for (const row of (sessions ?? []) as Array<Record<string, unknown>>) {
    const userId = String(row.user_id ?? '').trim();
    if (!userId) continue;
    const user = userById.get(userId);
    if (!user) continue;
    if (!_pushEnabled(user.notificationPreferences)) continue;
    const metadata = row.metadata;
    const token =
      metadata && typeof metadata === 'object' && !Array.isArray(metadata)
        ? String((metadata as Record<string, unknown>).fcm_token ?? '').trim()
        : '';
    if (!token) continue;
    const platform = String(row.platform ?? '').trim() || 'unknown';
    const key = `${userId}|${token}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ userId, locale: user.locale, token, platform });
  }

  log(invocationId, 'AI quota admin notification targets', { count: out.length });
  return out;
}

async function _shouldSendQuotaAlert({
  invocationId,
  provider,
  metric,
  window,
  severity,
  ratio,
  used,
  limit,
}: {
  invocationId: string;
  provider: string;
  metric: string;
  window: string;
  severity: 'warn' | 'critical';
  ratio: number | null;
  used: number | null;
  limit: number | null;
}): Promise<boolean> {
  const minMs = severity === 'critical' ? 60 * 60 * 1000 : 6 * 60 * 60 * 1000;
  const now = Date.now();

  const { data, error } = await supabase
    .from('ai_quota_alert_state')
    .select('last_sent_at')
    .match({ provider, metric, window_key: window, severity })
    .maybeSingle();
  if (error) throw error;
  const lastSentAtRaw = String((data as Record<string, unknown> | null | undefined)?.last_sent_at ?? '').trim();
  const lastSentAt = lastSentAtRaw ? Date.parse(lastSentAtRaw) : NaN;
  if (Number.isFinite(lastSentAt) && now - lastSentAt < minMs) {
    return false;
  }

  const { error: upsertErr } = await supabase
    .from('ai_quota_alert_state')
    .upsert(
      {
        provider,
        metric,
        window_key: window,
        severity,
        last_sent_at: new Date().toISOString(),
        last_ratio: ratio,
        last_used: used,
        last_limit: limit,
      },
      { onConflict: 'provider,metric,window_key,severity' },
    );
  if (upsertErr) {
    logError(invocationId, 'Failed to upsert ai_quota_alert_state', upsertErr, {
      provider,
      metric,
      window,
      severity,
    });
    throw upsertErr;
  }
  return true;
}

function _formatPercent(ratio: number | null): string {
  if (ratio == null || !Number.isFinite(ratio)) return '';
  return String(Math.round(ratio * 100));
}

async function _queueAdminQuotaAlert({
  invocationId,
  providerKey,
  metric,
  window,
  severity,
  used,
  limit,
  unit,
  ratio,
}: {
  invocationId: string;
  providerKey: 'adminAiProviderDeepL' | 'adminAiProviderGemini';
  metric: string;
  window: string;
  severity: 'warn' | 'critical';
  used: number | null;
  limit: number | null;
  unit: string;
  ratio: number | null;
}) {
  const targets = await _listAdminNotificationTargets(invocationId);
  if (targets.length === 0) return;

  for (const t of targets) {
    const providerName = await getTranslation(t.locale, providerKey);
    const titleKey = severity === 'critical' ? 'adminAiQuotaCriticalTitle' : 'adminAiQuotaWarnTitle';
    const title = await getTranslation(t.locale, titleKey);

    const bodyTemplateKey = limit != null && limit > 0 ? 'adminAiQuotaAlertBody' : 'adminAiQuotaAlertBodyNoLimit';
    const bodyTemplate = await getTranslation(t.locale, bodyTemplateKey);
    const usedText = used == null ? '' : String(Math.round(used));
    const limitText = limit == null ? '' : String(Math.round(limit));
    const percentText = _formatPercent(ratio);
    const body = bodyTemplate
      .replaceAll('{provider}', providerName)
      .replaceAll('{used}', usedText)
      .replaceAll('{limit}', limitText)
      .replaceAll('{unit}', unit)
      .replaceAll('{percent}', percentText);

    const data = {
      type: 'ai_quota',
      provider: providerName,
      metric,
      window,
      severity,
      ratio: ratio == null ? '' : String(ratio),
    };

    const { error } = await supabase.rpc('queue_fcm_notification', {
      p_user_id: t.userId,
      p_fcm_token: t.token,
      p_title: title,
      p_body: body,
      p_data: data,
      p_platform: t.platform,
    });
    if (error) {
      logError(invocationId, 'Failed to queue AI quota notification', error, {
        userId: t.userId,
        platform: t.platform,
      });
    }
  }
}

async function _fetchDeepLQuota(invocationId: string) {
  const apiKey = String(Deno.env.get('DEEPL_API_KEY') ?? '').trim();
  const baseUrl = String(Deno.env.get('DEEPL_BASE_URL') ?? 'https://api-free.deepl.com/v2').trim();
  if (!apiKey) {
    await _upsertQuotaStatus({
      invocationId,
      provider: 'deepl',
      metric: 'characters',
      window: 'billing_period',
      used: null,
      limit: null,
      unit: 'chars',
      status: 'unknown',
      details: { error: 'missing_env', env: 'DEEPL_API_KEY' },
    });
    return;
  }

  const url = `${baseUrl.replace(/\/+$/g, '')}/usage`;
  const resp = await fetch(url, {
    method: 'GET',
    headers: {
      Authorization: `DeepL-Auth-Key ${apiKey}`,
    },
  });
  const raw = await resp.text();
  if (!resp.ok) {
    await _upsertQuotaStatus({
      invocationId,
      provider: 'deepl',
      metric: 'characters',
      window: 'billing_period',
      used: null,
      limit: null,
      unit: 'chars',
      status: 'unknown',
      details: { http_status: resp.status, body: raw.slice(0, 2000) },
    });
    return;
  }

  const data = JSON.parse(raw) as Record<string, unknown>;
  const used = _toNum(data.character_count);
  const limit = _toNum(data.character_limit);
  const startTime = String(data.start_time ?? '').trim() || null;
  const endTime = String(data.end_time ?? '').trim() || null;

  const ratio = _ratio(used, limit);
  const status = _statusForRatio(ratio);
  await _upsertQuotaStatus({
    invocationId,
    provider: 'deepl',
    metric: 'characters',
    window: 'billing_period',
    used,
    limit,
    unit: 'chars',
    status,
    startTime,
    endTime,
    details: data,
  });

  if (status === 'warn' || status === 'critical') {
    const severity = status === 'critical' ? 'critical' : 'warn';
    const shouldSend = await _shouldSendQuotaAlert({
      invocationId,
      provider: 'deepl',
      metric: 'characters',
      window: 'billing_period',
      severity,
      ratio,
      used,
      limit,
    });
    if (shouldSend) {
      await _queueAdminQuotaAlert({
        invocationId,
        providerKey: 'adminAiProviderDeepL',
        metric: 'characters',
        window: 'billing_period',
        severity,
        used,
        limit,
        unit: 'chars',
        ratio,
      });
    }
  }
}

function _quoteFilterValue(value: string): string {
  return `"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
}

function _formatRfc3339(dt: Date): string {
  return dt.toISOString();
}

function _parsePointValue(point: Record<string, unknown>): number {
  const value = point.value;
  if (!value || typeof value !== 'object' || Array.isArray(value)) return 0;
  const v = value as Record<string, unknown>;
  const intVal = v.int64Value;
  if (intVal != null) return Number(String(intVal));
  const doubleVal = v.doubleValue;
  if (doubleVal != null) return Number(doubleVal);
  return 0;
}

async function _listMonitoringTimeSeries({
  projectId,
  accessToken,
  filter,
  startTime,
  endTime,
  view,
  pageSize,
}: {
  projectId: string;
  accessToken: string;
  filter: string;
  startTime: string;
  endTime: string;
  view: 'FULL' | 'HEADERS';
  pageSize: number;
}): Promise<Array<Record<string, unknown>>> {
  const base = `https://monitoring.googleapis.com/v3/projects/${encodeURIComponent(projectId)}/timeSeries`;
  const out: Array<Record<string, unknown>> = [];
  let pageToken = '';
  for (let i = 0; i < 3; i++) {
    const qp = new URLSearchParams();
    qp.set('filter', filter);
    qp.set('interval.startTime', startTime);
    qp.set('interval.endTime', endTime);
    qp.set('view', view);
    qp.set('pageSize', String(pageSize));
    if (pageToken) qp.set('pageToken', pageToken);
    const url = `${base}?${qp.toString()}`;

    const resp = await fetch(url, {
      method: 'GET',
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    const raw = await resp.text();
    if (!resp.ok) {
      throw new Error(`Monitoring API error status=${resp.status} body=${raw.slice(0, 2000)}`);
    }
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const ts = parsed.timeSeries;
    if (Array.isArray(ts)) {
      for (const item of ts) {
        if (item && typeof item === 'object' && !Array.isArray(item)) out.push(item as Record<string, unknown>);
      }
    }
    const next = String(parsed.nextPageToken ?? '').trim();
    if (!next) break;
    pageToken = next;
  }
  return out;
}

function _metricLabels(ts: Record<string, unknown>): Record<string, string> {
  const metric = ts.metric;
  if (!metric || typeof metric !== 'object' || Array.isArray(metric)) return {};
  const labels = (metric as Record<string, unknown>).labels;
  if (!labels || typeof labels !== 'object' || Array.isArray(labels)) return {};
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(labels as Record<string, unknown>)) {
    if (!k) continue;
    const s = String(v ?? '').trim();
    if (s) out[k] = s;
  }
  return out;
}

function _sumPoints(ts: Record<string, unknown>): number {
  const points = ts.points;
  if (!Array.isArray(points)) return 0;
  let sum = 0;
  for (const p of points) {
    if (!p || typeof p !== 'object' || Array.isArray(p)) continue;
    sum += _parsePointValue(p as Record<string, unknown>);
  }
  return sum;
}

function _latestPointValue(ts: Record<string, unknown>): number | null {
  const points = ts.points;
  if (!Array.isArray(points) || points.length === 0) return null;
  const p0 = points[0];
  if (!p0 || typeof p0 !== 'object' || Array.isArray(p0)) return null;
  const v = _parsePointValue(p0 as Record<string, unknown>);
  return Number.isFinite(v) ? v : null;
}

async function _fetchGeminiQuotaFromGcp(invocationId: string) {
  const saJson = String(Deno.env.get('GCP_QUOTA_SERVICE_ACCOUNT_JSON') ?? '').trim();
  if (!saJson) {
    await _upsertQuotaStatus({
      invocationId,
      provider: 'gemini',
      metric: 'gcp_quota',
      window: '24h',
      used: null,
      limit: null,
      unit: 'requests',
      status: 'unknown',
      details: { error: 'missing_env', env: 'GCP_QUOTA_SERVICE_ACCOUNT_JSON' },
    });
    return;
  }

  let serviceAccount: ServiceAccount;
  try {
    serviceAccount = JSON.parse(saJson) as ServiceAccount;
  } catch (e) {
    await _upsertQuotaStatus({
      invocationId,
      provider: 'gemini',
      metric: 'gcp_quota',
      window: '24h',
      used: null,
      limit: null,
      unit: 'requests',
      status: 'unknown',
      details: { error: 'invalid_json', env: 'GCP_QUOTA_SERVICE_ACCOUNT_JSON', message: String(e) },
    });
    return;
  }

  const projectId = String(Deno.env.get('GCP_PROJECT_ID') ?? serviceAccount.project_id ?? '').trim();
  if (!projectId || !serviceAccount.client_email || !serviceAccount.private_key) {
    await _upsertQuotaStatus({
      invocationId,
      provider: 'gemini',
      metric: 'gcp_quota',
      window: '24h',
      used: null,
      limit: null,
      unit: 'requests',
      status: 'unknown',
      details: { error: 'missing_fields', projectIdPresent: !!projectId },
    });
    return;
  }

  const accessToken = await getGoogleAccessToken({
    serviceAccount,
    scope: 'https://www.googleapis.com/auth/monitoring.read',
  });

  const now = new Date();
  const startLimit = new Date(now.getTime() - 5 * 60 * 1000);
  const service = 'generativelanguage.googleapis.com';
  const limitFilter =
    `metric.type="serviceruntime.googleapis.com/quota/limit" ` +
    `resource.type="consumer_quota" ` +
    `resource.label.service=${_quoteFilterValue(service)}`;

  let limitSeries: Array<Record<string, unknown>> = [];
  try {
    limitSeries = await _listMonitoringTimeSeries({
      projectId,
      accessToken,
      filter: limitFilter,
      startTime: _formatRfc3339(startLimit),
      endTime: _formatRfc3339(now),
      view: 'FULL',
      pageSize: 200,
    });
  } catch (e) {
    await _upsertQuotaStatus({
      invocationId,
      provider: 'gemini',
      metric: 'gcp_quota',
      window: '24h',
      used: null,
      limit: null,
      unit: 'requests',
      status: 'unknown',
      details: {
        error: 'monitoring_api_error',
        service,
        ...getErrorInfo(e),
      },
    });
    return;
  }

  const limits: Array<{ quotaMetric: string; limitName: string; limit: number }> = [];
  for (const ts of limitSeries) {
    const labels = _metricLabels(ts);
    const quotaMetric = String(labels.quota_metric ?? '').trim();
    const limitName = String(labels.limit_name ?? '').trim();
    const limit = _latestPointValue(ts);
    if (!quotaMetric || limit == null || !Number.isFinite(limit) || limit <= 0) continue;
    limits.push({ quotaMetric, limitName, limit });
  }

  const preferDaily = limits.filter((l) => {
    const hay = `${l.limitName} ${l.quotaMetric}`.toLowerCase();
    return hay.includes('perday') || hay.includes('per_day') || hay.includes('per day') || hay.includes('rpd');
  });
  const selected = (preferDaily.length > 0 ? preferDaily : limits)
    .sort((a, b) => b.limit - a.limit)
    .slice(0, 6);

  if (selected.length === 0) {
    await _upsertQuotaStatus({
      invocationId,
      provider: 'gemini',
      metric: 'gcp_quota',
      window: '24h',
      used: null,
      limit: null,
      unit: 'requests',
      status: 'unknown',
      details: { error: 'no_quota_metrics_found', service },
    });
    return;
  }

  const usageStart = new Date(now.getTime() - 24 * 60 * 60 * 1000);

  for (const entry of selected) {
    const quotaMetric = entry.quotaMetric;
    const limitName = entry.limitName;
    const metricName = (limitName || quotaMetric).slice(0, 200);
    const usageFilterParts = [
      `metric.type="serviceruntime.googleapis.com/quota/rate/net_usage"`,
      `resource.type="consumer_quota"`,
      `resource.label.service=${_quoteFilterValue(service)}`,
      `metric.label.quota_metric=${_quoteFilterValue(quotaMetric)}`,
    ];
    if (limitName) {
      usageFilterParts.push(`metric.label.limit_name=${_quoteFilterValue(limitName)}`);
    }
    const usageFilter = usageFilterParts.join(' ');

    let used = 0;
    try {
      const usageSeries = await _listMonitoringTimeSeries({
        projectId,
        accessToken,
        filter: usageFilter,
        startTime: _formatRfc3339(usageStart),
        endTime: _formatRfc3339(now),
        view: 'FULL',
        pageSize: 200,
      });
      for (const ts of usageSeries) {
        used += _sumPoints(ts);
      }
    } catch (e) {
      logError(invocationId, 'Gemini quota usage query failed', e, {
        quotaMetric,
        limitName,
      });
    }

    const limit = entry.limit;
    const ratio = _ratio(used, limit);
    const status = _statusForRatio(ratio);

    await _upsertQuotaStatus({
      invocationId,
      provider: 'gemini',
      metric: metricName,
      window: '24h',
      used,
      limit,
      unit: 'requests',
      status,
      details: {
        source: 'gcp_monitoring',
        service,
        quota_metric: quotaMetric,
        limit_name: limitName,
        interval_hours: 24,
      },
    });

    if (status === 'warn' || status === 'critical') {
      const severity = status === 'critical' ? 'critical' : 'warn';
      const shouldSend = await _shouldSendQuotaAlert({
        invocationId,
        provider: 'gemini',
        metric: metricName,
        window: '24h',
        severity,
        ratio,
        used,
        limit,
      });
      if (shouldSend) {
        await _queueAdminQuotaAlert({
          invocationId,
          providerKey: 'adminAiProviderGemini',
          metric: metricName,
          window: '24h',
          severity,
          used,
          limit,
          unit: 'requests',
          ratio,
        });
      }
    }
  }
}

async function handleAiQuotaMonitoring(invocationId: string) {
  log(invocationId, 'Checking AI quota status...');
  await _fetchDeepLQuota(invocationId);
  await _fetchGeminiQuotaFromGcp(invocationId);
  const { data, error } = await supabase.from('ai_quota_status').select('provider,metric,window_key,status').limit(5);
  if (error) {
    logError(invocationId, 'Failed to verify ai_quota_status rows after monitoring', error);
  } else {
    log(invocationId, 'AI quota status sample rows', { count: (data ?? []).length, rows: data });
  }
}

// Main server logic
async function runCronTask(
  invocationId: string,
  name: string,
  fn: () => Promise<void>,
): Promise<{ name: string; ok: boolean; error?: Record<string, unknown> }> {
  try {
    await fn();
    return { name, ok: true };
  } catch (error) {
    logError(invocationId, `Cron task failed: ${name}`, error);
    return { name, ok: false, error: getErrorInfo(error) };
  }
}

serve(async (req) => {
  const invocationId = crypto.randomUUID();
  const startedAtMs = Date.now();
  const functionName = "cron-jobs";
  let success = false;
  let httpStatus = 500;
  let errorType: string | null = null;
  let errorMessage: string | null = null;
  let meta: Record<string, unknown> = { method: req.method };
  const logSuccesses =
    (Deno.env.get("CRON_LOG_SUCCESSES") ?? "").toLowerCase() === "true";

  log(invocationId, 'Cron job function invoked.', {
    method: req.method,
    url: req.url,
    supabaseUrlHost: (() => {
      try {
        const u = new URL(Deno.env.get('SUPABASE_URL') ?? '');
        return u.host;
      } catch {
        return null;
      }
    })(),
    hasServiceRoleKey: Boolean(Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')),
    hasFcmServiceAccountJson: Boolean(Deno.env.get('FCM_SERVICE_ACCOUNT_JSON')),
  });
  try {
    const results = [
      await runCronTask(invocationId, 'invisibility_schedules', () => handleInvisibilitySchedules()),
      await runCronTask(invocationId, 'cleanup_expired_matches', () => cleanupExpiredMatches()),
      await runCronTask(invocationId, 'continuous_event_matching', () => handleContinuousEventMatching()),
      await runCronTask(invocationId, 'continuous_user_matching', () => handleContinuousUserMatching()),
      await runCronTask(invocationId, 'cleanup_orphan_profile_photos', () => handleCleanupOrphanProfilePhotos(invocationId)),
      await runCronTask(invocationId, 'scheduled_admin_broadcasts', () => handleScheduledAdminBroadcasts(invocationId)),
      await runCronTask(invocationId, 'notification_queue_processing', () => handleNotificationQueueProcessing(invocationId)),
      await runCronTask(invocationId, 'ai_quota_monitoring', () => handleAiQuotaMonitoring(invocationId)),
    ];

    const failed = results.filter((r) => !r.ok);
    success = failed.length === 0;
    httpStatus = 200;
    if (!success) {
      errorType = 'CronTaskFailure';
      errorMessage = `${failed.length} cron task(s) failed.`;
    }
    meta = {
      ...meta,
      taskResults: results.map((r) => ({
        name: r.name,
        ok: r.ok,
        errorMessage: r.ok ? null : String((r.error as Record<string, unknown> | undefined)?.message ?? ''),
        errorCode: r.ok ? null : String((r.error as Record<string, unknown> | undefined)?.code ?? ''),
      })),
    };

    log(invocationId, 'Cron job function completed.', {
      success,
      failedCount: failed.length,
    });

    return new Response(JSON.stringify({
      success,
      message: success ? "Cron jobs executed." : "Cron jobs executed with errors.",
      failedTasks: failed.map((f) => f.name),
    }), {
      headers: { 'Content-Type': 'application/json' },
      status: 200 // Explicitly set success status
    });

  } catch (error) {
    logError(invocationId, 'Cron job function failed', error);
    errorType = error instanceof Error ? error.name : "Error";
    errorMessage = error instanceof Error ? error.message : String(error);
    httpStatus = 500;
    return new Response(JSON.stringify({ success: false, error: error.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  } finally {
    const shouldLog =
      req.method !== "OPTIONS" && (logSuccesses || !success || httpStatus >= 400);
    if (shouldLog) {
      await logEdgeFunctionInvocation({
        requestId: invocationId,
        functionName,
        durationMs: Date.now() - startedAtMs,
        success,
        httpStatus,
        errorType,
        errorMessage,
        aiUsed: false,
        meta,
      });
    }
  }
});
