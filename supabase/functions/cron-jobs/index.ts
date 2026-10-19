// supabase/functions/cron-jobs/index.ts
import { serve } from 'std/http/server.ts';
import { createClient } from 'supabase';
import { RRule } from 'rrule-deno';
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";
import { bidiIsolate, enforceTitleBody, maskFullName } from "../_shared/notification_limits.ts";
import { isWnsChannelUri, sendWnsToast, wnsLaunchUri } from "../_shared/wns.ts";
import { handleHealthSampler } from "./health_sampler.ts";

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
  pinnedExpiryTitle: 'Pinned location expiring soon',
  pinnedExpiryBodyMinutes: 'Your pinned location{labelPart} expires in {count} minutes. Open the app to add more time.',
  pinnedExpiryBodyHours: 'Your pinned location{labelPart} expires in {count} hours. Open the app to add more time.',
};

/**
 * MatchMe ships exactly three languages: en, es, he.
 * Anything else resolves to English rather than silently querying a locale
 * that has no translations. Keep in sync with the AppLanguage entries in
 * lib/providers/locale_provider.dart and the _pushStrings table in
 * supabase/functions/push-message/index.ts.
 */
function normalizeSupportedLocale(raw: unknown): string {
  const s = String(raw ?? '').trim().toLowerCase();
  if (s.startsWith('he')) return 'he';
  if (s.startsWith('es')) return 'es';
  return 'en';
}

async function getTranslation(locale: string, key: string): Promise<string> {
  const normalizedLocale = normalizeSupportedLocale(locale);
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
    keyBytes.slice(),
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
    keyBytes.slice(),
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

// Queue drain sizing. The batch is drained once per invocation (~1 min).
// A large admin broadcast fans out thousands of rows: 300 per tick at
// concurrency 10 clears 18k rows in about an hour while staying inside the
// edge-function wall clock.
const QUEUE_DRAIN_BATCH = 300;
const QUEUE_SEND_CONCURRENCY = 10;

function channelIdForType(data: Record<string, string>): string {
  const t = String(data.type ?? data.kind ?? '').trim().toLowerCase();
  if (t === 'admin_broadcast') return 'admin_broadcasts';
  if (t === 'match_expiry' || t === 'pinned_expiry') return 'match_expiry_alerts';
  if (t === 'location_share') return 'location_sharing';
  return 'chat_messages';
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
}): Promise<{ ok: boolean; status: number; body: unknown }> {
  const projectId = serviceAccount.project_id.trim();
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  const title = wrapRtlIfNeeded(notification.title);
  const bodyText = wrapRtlIfNeeded(notification.body);
  const collapse = (collapseKey ?? tag ?? '').trim();
  // Per-recipient alert preference. Admin-broadcast queue rows carry the
  // recipient's sound/vibrate flags plus the matching Android channel id
  // (see migration 20260925000000_admin_broadcast_alert_preferences.sql).
  // Android 8+ takes sound/vibration from the CHANNEL, so the channel id is
  // what actually silences a muted admin announcement; `defaultSound` /
  // `defaultVibrateTimings` cover Android 7 and keep FCM honest about intent.
  const prefSound = String(data.sound ?? '').trim().toLowerCase();
  const prefVibrate = String(data.vibrate ?? '').trim().toLowerCase();
  const soundEnabled = prefSound === '' ? true : prefSound !== 'false';
  const vibrateEnabled = prefVibrate === '' ? true : prefVibrate !== 'false';
  const dataChannelId = String(data.channel_id ?? '').trim();
  const resolvedChannel =
    String(dataChannelId || channelId || channelIdForType(data)).trim() ||
    'chat_messages';
  const resolvedBadge = typeof badge === 'number' && Number.isFinite(badge)
    ? Math.min(99, Math.max(0, Math.floor(badge)))
    : 1;
  // 7-day TTL: queue pushes (expiry/admin) must survive device-off,
  // reboot, and browser-closed gaps. 60s dropped anything offline > 1 min.
  const ttlSeconds = '604800s';
  const apnsExpiration = String(
    Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
  );
  const body = {
    message: {
      token,
      notification: { title, body: bodyText },
      data,
      android: {
        priority: 'HIGH' as const,
        ttl: ttlSeconds,
        // FCM v1 uses camelCase collapseKey; keep legacy key for safety.
        ...(collapse
          ? {
              collapseKey: collapse,
              collapse_key: collapse,
              notification: {
                tag: collapse,
                channelId: resolvedChannel,
                notificationPriority: 'PRIORITY_HIGH',
                defaultSound: soundEnabled,
                defaultVibrateTimings: vibrateEnabled,
              },
            }
          : {
              notification: {
                channelId: resolvedChannel,
                notificationPriority: 'PRIORITY_HIGH',
                defaultSound: soundEnabled,
                defaultVibrateTimings: vibrateEnabled,
              },
            }),
      },
      apns: {
        headers: {
          'apns-priority': '10',
          'apns-push-type': 'alert',
          'apns-expiration': apnsExpiration,
          ...(collapse ? { 'apns-collapse-id': collapse } : {}),
        },
        payload: {
          aps: {
            alert: { title, body: bodyText },
            // Muted admin announcements must stay silent on iOS too.
            ...(soundEnabled ? { sound: 'default' } : {}),
            badge: resolvedBadge,
            'content-available': 1,
            'mutable-content': 1,
            // Same delivered-notification identity as the Android `tag`:
            // the app checks threadIdentifier to see whether the server card
            // for this event (expiry/admin) is already sitting in
            // Notification Center before posting its own local card.
            ...(collapse ? { 'thread-id': collapse } : {}),
          },
        },
      },
      webpush: {
        headers: {
          TTL: '604800',
          Urgency: 'high',
          ...(collapse ? { Topic: collapse } : {}),
        },
        notification: {
          icon: '/icons/Icon-192.png',
          badge: '/icons/Icon-192.png',
          requireInteraction: true,
          ...(collapse ? { tag: collapse, renotify: true } : {}),
        },
        fcmOptions: {
          link: (data as Record<string, string>).route ||
            (data as Record<string, string>).action_url ||
            ((data as Record<string, string>).match_id
              ? `/chat/${(data as Record<string, string>).match_id}`
              : '/'),
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

function parseConfigScalar(value: unknown): unknown {
  if (typeof value !== 'string') return value;
  const trimmed = value.trim();
  if (!trimmed) return '';
  try {
    return JSON.parse(trimmed);
  } catch {
    return trimmed;
  }
}

function configString(value: unknown, fallback = ''): string {
  const parsed = parseConfigScalar(value);
  if (typeof parsed === 'string') return parsed.trim();
  if (typeof parsed === 'number' || typeof parsed === 'boolean') {
    return String(parsed);
  }
  return fallback;
}

function configNumber(value: unknown, fallback: number): number {
  const parsed = parseConfigScalar(value);
  const numeric =
    typeof parsed === 'number' ? parsed : Number.parseFloat(String(parsed ?? '').trim());
  return Number.isFinite(numeric) ? numeric : fallback;
}

function configBoolean(value: unknown, fallback: boolean): boolean {
  const parsed = parseConfigScalar(value);
  if (typeof parsed === 'boolean') return parsed;
  const normalized = String(parsed ?? '').trim().toLowerCase();
  if (['true', '1', 'yes', 'on'].includes(normalized)) return true;
  if (['false', '0', 'no', 'off'].includes(normalized)) return false;
  return fallback;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

async function getAppConfigValue(configKey: string): Promise<unknown | null> {
  try {
    const { data, error } = await supabase
      .from('app_config')
      .select('config_value')
      .eq('config_key', configKey)
      .maybeSingle();

    if (error) throw error;
    return (data as { config_value?: unknown } | null)?.config_value ?? null;
  } catch {
    return null;
  }
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

type CurrencyRefreshSettings = {
  enabled: boolean;
  intervalMinutes: number;
  timeoutMs: number;
  provider: string;
  baseCurrency: string;
};

async function getCurrencyRefreshSettings(): Promise<CurrencyRefreshSettings> {
  const [
    enabledValue,
    intervalValue,
    timeoutValue,
    providerValue,
    baseCurrencyValue,
  ] = await Promise.all([
    getAppConfigValue('billing.currency.refresh_enabled'),
    getAppConfigValue('billing.currency.refresh_interval_minutes'),
    getAppConfigValue('billing.currency.refresh_timeout_ms'),
    getAppConfigValue('billing.currency.refresh_provider'),
    getAppConfigValue('billing.currency.refresh_base_currency'),
  ]);

  return {
    enabled: configBoolean(enabledValue, false),
    intervalMinutes: Math.max(15, Math.round(configNumber(intervalValue, 360))),
    timeoutMs: Math.max(3000, Math.min(60000, Math.round(configNumber(timeoutValue, 15000)))),
    provider: configString(providerValue, 'openexchangerates').toLowerCase() || 'openexchangerates',
    baseCurrency: configString(baseCurrencyValue, 'USD').toUpperCase() || 'USD',
  };
}

async function getLatestCurrencyRefreshFetchedAt(baseCurrency: string): Promise<Date | null> {
  const { data, error } = await supabase
    .from('currency_exchange_rates')
    .select('fetched_at')
    .eq('base_currency', baseCurrency)
    .order('fetched_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) throw error;
  const raw = String((data as Record<string, unknown> | null)?.fetched_at ?? '').trim();
  if (!raw) return null;
  const parsed = new Date(raw);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function buildOpenExchangeRatesLatestUrl(baseUrl: string, appId: string): string {
  const normalizedBase = baseUrl.endsWith('/') ? baseUrl : `${baseUrl}/`;
  const url = new URL('latest.json', normalizedBase);
  url.searchParams.set('app_id', appId);
  return url.toString();
}

function buildCurrencyFreaksLatestUrl(
  baseUrl: string,
  apiKey: string,
  baseCurrency: string,
): string {
  const normalizedBase = baseUrl.endsWith('/') ? baseUrl : `${baseUrl}/`;
  const url = new URL('latest', normalizedBase);
  url.searchParams.set('apikey', apiKey);
  url.searchParams.set('base', baseCurrency);
  return url.toString();
}

function buildAbstractApiLatestUrl(
  baseUrl: string,
  apiKey: string,
  baseCurrency: string,
): string {
  const url = new URL(baseUrl);
  url.searchParams.set('api_key', apiKey);
  url.searchParams.set('base', baseCurrency);
  return url.toString();
}

type CurrencyProviderFetchResult = {
  provider: string;
  requestUrl: string;
  rates: Record<string, unknown>;
  fetchedAtIso: string;
};

function parseProviderTimestamp(value: unknown): string | null {
  if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
    return new Date(value * 1000).toISOString();
  }
  const asNumber = Number(String(value ?? '').trim());
  if (Number.isFinite(asNumber) && asNumber > 0) {
    return new Date(asNumber * 1000).toISOString();
  }
  const asString = String(value ?? '').trim();
  if (!asString) return null;
  const parsed = new Date(asString);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toISOString();
}

function parseOpenExchangeRatesResponse(
  parsed: Record<string, unknown>,
  expectedBaseCurrency: string,
): { rates: Record<string, unknown>; fetchedAtIso: string } {
  if (parsed.error === true) {
    const providerMessage =
      configString(parsed.message) ||
      configString(parsed.description) ||
      'unknown provider error';
    throw new Error(`Open Exchange Rates returned an error: ${providerMessage}`);
  }

  const responseBaseCurrency = configString(parsed.base, expectedBaseCurrency).toUpperCase();
  if (responseBaseCurrency !== expectedBaseCurrency) {
    throw new Error(
      `Open Exchange Rates returned base=${responseBaseCurrency}; expected ${expectedBaseCurrency}.`,
    );
  }

  const rates = asRecord(parsed.rates);
  if (!rates || Object.keys(rates).length === 0) {
    throw new Error('Open Exchange Rates returned no rates.');
  }

  return {
    rates,
    fetchedAtIso: parseProviderTimestamp(parsed.timestamp) ?? new Date().toISOString(),
  };
}

function parseCurrencyFreaksResponse(
  parsed: Record<string, unknown>,
  expectedBaseCurrency: string,
): { rates: Record<string, unknown>; fetchedAtIso: string } {
  if (parsed.error === true) {
    const providerMessage =
      configString(parsed.message) ||
      configString(parsed.description) ||
      configString(parsed.errors) ||
      'unknown provider error';
    throw new Error(`CurrencyFreaks returned an error: ${providerMessage}`);
  }

  const responseBaseCurrency = configString(parsed.base, expectedBaseCurrency).toUpperCase();
  if (responseBaseCurrency !== expectedBaseCurrency) {
    throw new Error(
      `CurrencyFreaks returned base=${responseBaseCurrency}; expected ${expectedBaseCurrency}.`,
    );
  }

  const rates = asRecord(parsed.rates);
  if (!rates || Object.keys(rates).length === 0) {
    throw new Error('CurrencyFreaks returned no rates.');
  }

  return {
    rates,
    fetchedAtIso:
      parseProviderTimestamp(parsed.timestamp) ??
      parseProviderTimestamp(parsed.date) ??
      new Date().toISOString(),
  };
}

function parseAbstractApiResponse(
  parsed: Record<string, unknown>,
  expectedBaseCurrency: string,
): { rates: Record<string, unknown>; fetchedAtIso: string } {
  if (parsed.error === true) {
    const providerMessage =
      configString(parsed.message) ||
      configString(parsed.description) ||
      'unknown provider error';
    throw new Error(`AbstractAPI returned an error: ${providerMessage}`);
  }

  const responseBaseCurrency = configString(parsed.base, expectedBaseCurrency).toUpperCase();
  if (responseBaseCurrency !== expectedBaseCurrency) {
    throw new Error(
      `AbstractAPI returned base=${responseBaseCurrency}; expected ${expectedBaseCurrency}.`,
    );
  }

  const rates =
    asRecord(parsed.exchange_rates) ??
    asRecord(parsed.rates);
  if (!rates || Object.keys(rates).length === 0) {
    throw new Error('AbstractAPI returned no rates.');
  }

  return {
    rates,
    fetchedAtIso:
      parseProviderTimestamp(parsed.last_updated) ??
      parseProviderTimestamp(parsed.timestamp) ??
      new Date().toISOString(),
  };
}

function parseCurrencyProviderPayload(
  provider: string,
  parsed: Record<string, unknown>,
  expectedBaseCurrency: string,
): { rates: Record<string, unknown>; fetchedAtIso: string } {
  switch (provider) {
    case 'openexchangerates':
      return parseOpenExchangeRatesResponse(parsed, expectedBaseCurrency);
    case 'currencyfreaks':
      return parseCurrencyFreaksResponse(parsed, expectedBaseCurrency);
    case 'abstractapi':
      return parseAbstractApiResponse(parsed, expectedBaseCurrency);
    default:
      throw new Error(`Unsupported exchange-rate provider: ${provider}`);
  }
}

function getCurrencyProviderRequest(
  provider: string,
  baseCurrency: string,
): { requestUrl: string; providerLabel: string } | null {
  switch (provider) {
    case 'openexchangerates': {
      const appId = String(Deno.env.get('OPENEXCHANGERATES_APP_ID') ?? '').trim();
      if (!appId) return null;
      const baseUrl = String(
        Deno.env.get('OPENEXCHANGERATES_BASE_URL') ?? 'https://openexchangerates.org/api/',
      ).trim();
      return {
        requestUrl: buildOpenExchangeRatesLatestUrl(baseUrl, appId),
        providerLabel: 'openexchangerates',
      };
    }
    case 'currencyfreaks': {
      const apiKey = String(Deno.env.get('CURRENCYFREAKS_API_KEY') ?? '').trim();
      if (!apiKey) return null;
      const baseUrl = String(
        Deno.env.get('CURRENCYFREAKS_BASE_URL') ?? 'https://api.currencyfreaks.com/v2.0/',
      ).trim();
      return {
        requestUrl: buildCurrencyFreaksLatestUrl(baseUrl, apiKey, baseCurrency),
        providerLabel: 'currencyfreaks',
      };
    }
    case 'abstractapi': {
      const apiKey = String(Deno.env.get('ABSTRACTAPI_API_KEY') ?? '').trim();
      if (!apiKey) return null;
      const baseUrl = String(
        Deno.env.get('ABSTRACTAPI_EXCHANGE_RATES_URL') ??
          'https://exchange-rates.abstractapi.com/v1/live/',
      ).trim();
      return {
        requestUrl: buildAbstractApiLatestUrl(baseUrl, apiKey, baseCurrency),
        providerLabel: 'abstractapi',
      };
    }
    default:
      throw new Error(`Unsupported billing.currency.refresh_provider=${provider}`);
  }
}

async function fetchCurrencyProviderRates({
  invocationId,
  provider,
  baseCurrency,
  timeoutMs,
}: {
  invocationId: string;
  provider: string;
  baseCurrency: string;
  timeoutMs: number;
}): Promise<CurrencyProviderFetchResult | null> {
  const request = getCurrencyProviderRequest(provider, baseCurrency);
  if (!request) {
    log(
      invocationId,
      `Currency rate refresh skipped; provider secret is missing for ${provider}.`,
    );
    return null;
  }

  const abortController = new AbortController();
  const timeoutId = setTimeout(() => abortController.abort(), timeoutMs);
  let responseText = '';

  try {
    log(invocationId, 'Refreshing cached currency exchange rates.', {
      baseCurrency,
      provider: request.providerLabel,
      requestUrlHost: (() => {
        try {
          return new URL(request.requestUrl).host;
        } catch {
          return null;
        }
      })(),
    });

    const response = await fetch(request.requestUrl, {
      method: 'GET',
      headers: {
        Accept: 'application/json',
      },
      signal: abortController.signal,
    });

    responseText = await response.text();
    let parsed: Record<string, unknown> | null = null;
    try {
      parsed = asRecord(JSON.parse(responseText));
    } catch {
      parsed = null;
    }

    if (!response.ok) {
      const providerMessage =
        configString(parsed?.message) ||
        configString(parsed?.description) ||
        configString(parsed?.error) ||
        `status=${response.status}`;
      throw new Error(`Exchange-rate provider request failed: ${providerMessage}`);
    }

    if (!parsed) {
      throw new Error('Exchange-rate provider returned a non-object JSON payload.');
    }

    const normalized = parseCurrencyProviderPayload(
      provider,
      parsed,
      baseCurrency,
    );

    return {
      provider: request.providerLabel,
      requestUrl: request.requestUrl,
      rates: normalized.rates,
      fetchedAtIso: normalized.fetchedAtIso,
    };
  } catch (error) {
    const isAbort = error instanceof DOMException && error.name === 'AbortError';
    if (isAbort) {
      throw new Error(
        `Exchange-rate provider request timed out after ${timeoutMs}ms.`,
      );
    }
    logError(invocationId, 'Currency rate refresh failed.', error, {
      provider,
      baseCurrency,
      responsePreview: responseText.slice(0, 300),
    });
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }
}

async function handleCurrencyExchangeRateRefresh(invocationId: string) {
  const settings = await getCurrencyRefreshSettings();
  if (!settings.enabled) {
    log(invocationId, 'Currency rate refresh skipped; disabled in app_config.');
    return;
  }

  if (settings.baseCurrency !== 'USD') {
    throw new Error(
      `Unsupported billing.currency.refresh_base_currency=${settings.baseCurrency}; current client conversion flow expects USD.`,
    );
  }

  const lastFetchedAt = await getLatestCurrencyRefreshFetchedAt(settings.baseCurrency);
  const minAgeMs = settings.intervalMinutes * 60_000;
  if (lastFetchedAt && Date.now() - lastFetchedAt.getTime() < minAgeMs) {
    log(invocationId, 'Currency rate refresh skipped; cached rates are still fresh.', {
      baseCurrency: settings.baseCurrency,
      lastFetchedAt: lastFetchedAt.toISOString(),
      intervalMinutes: settings.intervalMinutes,
      provider: settings.provider,
    });
    return;
  }

  const result = await fetchCurrencyProviderRates({
    invocationId,
    provider: settings.provider,
    baseCurrency: settings.baseCurrency,
    timeoutMs: settings.timeoutMs,
  });
  if (!result) {
    return;
  }

  const { data, error } = await supabase.rpc(
    'upsert_currency_exchange_rates_batch',
    {
      p_base_currency: settings.baseCurrency,
      p_rates: result.rates,
      p_source: result.provider,
      p_fetched_at: result.fetchedAtIso,
    },
  );

  if (error) throw error;

  log(invocationId, 'Currency exchange rates refreshed successfully.', {
    baseCurrency: settings.baseCurrency,
    fetchedAt: result.fetchedAtIso,
    upsertedCount: Number(data ?? 0),
    provider: result.provider,
    intervalMinutes: settings.intervalMinutes,
  });
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
    console.error('Error during Expired Match Cleanup:', error instanceof Error ? error.message : String(error));
    throw error;
  }
}

/**
 * Cleanup old presence events: Deletes presence event records older than 48 hours
 * to prevent unbounded table growth.
 */
async function cleanupOldPresenceEvents() {
  console.log('Running Old Presence Events Cleanup...');
  try {
    const { data, error } = await supabase.rpc('cleanup_old_presence_events');

    if (error) {
      console.error('Old Presence Events Cleanup RPC error:', error);
      throw error;
    }

    const deletedCount = typeof data === 'number' ? data : Number(data ?? 0);
    console.log(`Old Presence Events Cleanup completed successfully. Deleted: ${deletedCount}`);
  } catch (error) {
    console.error('Error during Old Presence Events Cleanup:', error instanceof Error ? error.message : String(error));
    throw error;
  }
}

/**
 * Cleanup stale online users: Set is_online = false for users whose last_activity
 * is older than 61 seconds. This ensures real-time online count accuracy.
 * Triggers real-time UPDATE events that clients receive immediately.
 */
async function cleanupStaleOnlineUsers() {
  console.log('Running Stale Online Users Cleanup...');
  try {
    const { data, error } = await supabase.rpc('cleanup_stale_online_users');

    if (error) {
      console.error('Stale Online Users Cleanup RPC error:', error);
      throw error;
    }

    const updatedCount = typeof data === 'number' ? data : Number(data ?? 0);
    console.log(`Stale Online Users Cleanup completed. Users set offline: ${updatedCount}`);
  } catch (error) {
    console.error('Error during Stale Online Users Cleanup:', error instanceof Error ? error.message : String(error));
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
        console.error(`Scheduler: Skipping bad rrule for user ${schedule.user_id}: ${schedule.rrule} - ${rruleError instanceof Error ? rruleError.message : String(rruleError)}`);
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
    console.error('Error during Invisibility scheduling:', error instanceof Error ? error.message : String(error));
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
    console.error('Error during Continuous Event Matching:', error instanceof Error ? error.message : String(error));
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
    console.error('Error during Continuous User Matching:', error instanceof Error ? error.message : String(error));
    throw error;
  }
}

async function handleCleanupExpiredEmailCodes(invocationId: string) {
  log(invocationId, 'Running Email Code Cleanup...');
  try {
    const { data, error } = await supabase.rpc('cleanup_expired_email_codes');

    if (error) {
      console.error('Error during email code cleanup:', error);
      throw error;
    }

    const deletedCount = data?.[0]?.deleted_count ?? 0;
    log(invocationId, `Email Code Cleanup completed. Deleted ${deletedCount} expired codes.`, {
      deletedCount,
    });
  } catch (error) {
    console.error('Error during Email Code Cleanup:', error instanceof Error ? error.message : String(error));
    throw error;
  }
}

async function handleCleanupPendingEmailChanges(invocationId: string) {
  log(invocationId, 'Running Pending Email Changes Cleanup...');
  try {
    // Use RPC to bypass RLS policies
    const { data, error } = await supabase.rpc('cleanup_pending_email_changes');

    if (error) {
      console.error('Error during pending email changes cleanup:', error);
      throw error;
    }

    const deletedCount = data?.[0]?.deleted_count ?? 0;
    log(invocationId, `Pending Email Changes Cleanup completed. Deleted ${deletedCount} expired entries.`, {
      deletedCount,
    });
  } catch (error) {
    console.error('Error during Pending Email Changes Cleanup:', error instanceof Error ? error.message : String(error));
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
      // Chunked fan-out: 2000 deliveries per RPC call, up to 20k cap enforced
      // in SQL. Prevents statement-timeout on large blasts; final chunk flips
      // status to sent (see 20260916000000_add_notification_limits.sql).
      // 11 iterations: 10 full chunks (20k) + 1 empty probe so exactly-20k
      // audiences flip from sending -> sent instead of sticking.
      const chunkSize = 2000;
      let offset = 0;
      let broadcastFailed = false;
      for (let chunk = 0; chunk < 11; chunk++) {
        const { data: chunkRes, error: sendError } = await supabase.rpc('send_admin_broadcast', {
          broadcast_id: broadcastId,
          p_limit: chunkSize,
          p_offset: offset,
        });
        if (sendError) {
          // Fallback for pre-migration single-arg overload.
          if (offset === 0 && String(sendError.message ?? '').toLowerCase().includes('function')) {
            const retry = await supabase.rpc('send_admin_broadcast', { broadcast_id: broadcastId });
            if (retry.error) {
              logError(invocationId, 'send_admin_broadcast RPC error', retry.error, { broadcastId });
              broadcastFailed = true;
            } else {
              log(invocationId, 'send_admin_broadcast RPC succeeded (legacy)', { broadcastId });
            }
            break;
          }
          logError(invocationId, 'send_admin_broadcast RPC error', sendError, { broadcastId, offset });
          broadcastFailed = true;
          break;
        }
        const resObj = chunkRes as Record<string, unknown> | null;
        const sentCount = Number(resObj?.['sent_count'] ?? chunkSize);
        // scanned_count is the number of candidate rows the chunk examined
        // (before the 2/24h frequency guard). Pagination must advance by it,
        // otherwise guarded users make sentCount underflow and the tail of the
        // audience never gets processed. Fall back to sentCount for pre-fix
        // functions so behavior is preserved.
        const scannedCount = Number(resObj?.['scanned_count'] ?? sentCount);
        log(invocationId, 'send_admin_broadcast chunk succeeded', { broadcastId, offset, sentCount, scannedCount });
        offset += scannedCount;
        if (!Number.isFinite(scannedCount) || scannedCount < chunkSize) break;
      }
      if (broadcastFailed) {
        hadError = true;
        await supabase
          .from('admin_broadcasts')
          .update({ status: 'failed', updated_at: new Date().toISOString() })
          .eq('id', broadcastId);
        continue;
      }
      log(invocationId, 'send_admin_broadcast RPC succeeded', { broadcastId, chunksOffset: offset });
    }
    if (hadError) {
      throw new Error('One or more scheduled broadcasts failed.');
    }
  } catch (error) {
    logError(invocationId, 'Error during Scheduled Admin Broadcasts', error);
    throw error;
  }
}

async function handleBirthdayBroadcastAutomations(invocationId: string) {
  log(invocationId, 'Queueing birthday broadcast automations...');
  try {
    const { data: broadcasts, error } = await supabase
      .from('admin_broadcasts')
      .select('id,title,automation_type,automation_enabled')
      .eq('automation_enabled', true)
      .eq('automation_type', 'birthday')
      .limit(200);

    if (error) throw error;

    const rows = (broadcasts ?? []) as Array<Record<string, unknown>>;
    if (rows.length === 0) {
      log(invocationId, 'No birthday broadcast automations are enabled.');
      return;
    }

    let totalQueued = 0;
    for (const row of rows) {
      const broadcastId = String(row.id ?? '').trim();
      if (!broadcastId) continue;

      const { data, error: queueError } = await supabase.rpc(
        'queue_birthday_broadcast_notifications',
        {
          p_broadcast_id: broadcastId,
        },
      );
      if (queueError) {
        logError(invocationId, 'Birthday automation queue RPC failed', queueError, {
          broadcastId,
          title: String(row.title ?? '').trim() || null,
        });
        continue;
      }

      const queuedCount = typeof data === 'number' ? data : Number(data ?? 0);
      totalQueued += Number.isFinite(queuedCount) ? queuedCount : 0;
      log(invocationId, 'Birthday automation processed', {
        broadcastId,
        title: String(row.title ?? '').trim() || null,
        queuedCount,
      });
    }

    log(invocationId, 'Birthday broadcast automations completed.', {
      broadcastCount: rows.length,
      totalQueued,
    });
  } catch (error) {
    logError(invocationId, 'Error during Birthday Broadcast Automations', error);
    throw error;
  }
}

/**
 * Automatic "complete your profile" reminders — birthday-style automation.
 * Enabled admin_broadcasts rows with automation_type 'profile_reminder' are
 * processed every tick: queue_profile_reminder_broadcast_notifications()
 * claims due users (incomplete profile, app closed per the intervals in
 * app_config notifications.profile_reminder.*, stage-tracked in
 * profile_reminder_state), personalizes {first_name}/{name} from the
 * broadcast row's text, records an admin_broadcast_deliveries row, and
 * queues the push — so text and the enable toggle are edited in the admin
 * broadcasts composer, exactly like the birthday automation.
 */
async function handleProfileCompletionReminders(invocationId: string) {
  log(invocationId, 'Queueing profile reminder automations...');
  try {
    const { data: broadcasts, error } = await supabase
      .from('admin_broadcasts')
      .select('id,title,automation_type,automation_enabled')
      .eq('automation_enabled', true)
      .eq('automation_type', 'profile_reminder')
      .limit(200);

    if (error) throw error;

    const rows = (broadcasts ?? []) as Array<Record<string, unknown>>;
    if (rows.length === 0) {
      log(invocationId, 'No profile reminder automations are enabled.');
      return;
    }

    let totalQueued = 0;
    for (const row of rows) {
      const broadcastId = String(row.id ?? '').trim();
      if (!broadcastId) continue;

      const { data, error: queueError } = await supabase.rpc(
        'queue_profile_reminder_broadcast_notifications',
        {
          p_broadcast_id: broadcastId,
        },
      );
      if (queueError) {
        logError(invocationId, 'Profile reminder automation queue RPC failed', queueError, {
          broadcastId,
          title: String(row.title ?? '').trim() || null,
        });
        continue;
      }

      const queuedCount = typeof data === 'number' ? data : Number(data ?? 0);
      totalQueued += Number.isFinite(queuedCount) ? queuedCount : 0;
      log(invocationId, 'Profile reminder automation processed', {
        broadcastId,
        title: String(row.title ?? '').trim() || null,
        queuedCount,
      });
    }

    log(invocationId, 'Profile reminder automations completed.', {
      broadcastCount: rows.length,
      totalQueued,
    });
  } catch (error) {
    logError(invocationId, 'Error during Profile Reminder Automations', error);
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
      .limit(QUEUE_DRAIN_BATCH);

    if (listError) throw listError;
    const rows = (pendingRows ?? []) as Array<Record<string, unknown>>;
    // Health signal: full batch likely means backlog; surface via logs.
    // Detailed numbers available via rpc get_notification_queue_health().
    if (rows.length >= QUEUE_DRAIN_BATCH) {
      log(invocationId, `Queue backlog warning: batch full (${QUEUE_DRAIN_BATCH}), more pending likely`, {});
    }
    try {
      const { data: health } = await supabase.rpc('get_notification_queue_health');
      const h = health as Record<string, unknown> | null;
      if (h && h['alert'] === true) {
        logError(invocationId, 'Queue health alert', new Error(JSON.stringify(h)), {});
      } else if (h) {
        log(invocationId, 'Queue health ok', { pending: h['pending'] ?? null });
      }
    } catch {
      // Health RPC missing pre-migration; ignore.
    }
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

    // Per-row send, extracted so rows can be sent concurrently: a large
    // admin broadcast fans out thousands of queue rows, and fully-serial
    // FCM round-trips (~100-300ms each) blew the edge-function wall clock.
    // Rows are independent: each claims its own row optimistically before
    // sending, so concurrent claims cannot double-send.
    const processQueueRow = async (row: Record<string, unknown>): Promise<void> => {
      const id = String(row.id ?? '').trim();
      const userId = String(row.user_id ?? '').trim();
      const token = String(row.fcm_token ?? '').trim();
      const rawTitle = String(row.title ?? '').trim();
      const rawBody = String(row.body ?? '').trim();
      const attempts = Number(row.attempts ?? 0);
      const maxAttempts = Number(row.max_attempts ?? 3);
      const data = coerceStringRecord(row.data);
      // Transport guard: byte-based truncation (FCM 4096B). DB trigger
      // already truncates, this covers legacy oversize rows.
      const enforced = enforceTitleBody(rawTitle, rawBody);
      const title = enforced.title;
      const body = enforced.body || '(see app)';
      if (enforced.truncated) {
        log(invocationId, 'Queue row truncated to limits', { id });
      }

      if (!id || !token || !title) return;

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
        return;
      }

      log(invocationId, 'Row claimed', { id, nextAttempts });

      try {
        // Collapse updates so retries replace the previous tray entry
        // instead of stacking (match_expiry 60/59/58..., admin resends).
        let collapseTag: string | undefined;
        if ((data.type === 'match_expiry' || data.type === 'pinned_expiry') && (data.match_id || data.user_id)) {
          const thr = String(data.threshold_seconds ?? '').trim();
          const key = String(data.match_id ?? data.user_id ?? '').trim();
          collapseTag = thr ? `${data.type}_${key}_${thr}` : `${data.type}_${key}`;
        } else if ((data.type === 'match' || data.type === 'new_match') && (data.match_id || data.matchId)) {
          // New-match queue rows (trg_enqueue_new_match_fcm): retries replace
          // the previous tray entry instead of stacking, same tag the direct
          // push-message path uses.
          const key = String(data.match_id ?? data.matchId ?? '').trim();
          if (key) collapseTag = `new_match_${key}`;
        } else if (data.type === 'admin_broadcast' && data.broadcast_id) {
          collapseTag = `admin_${String(data.broadcast_id).trim()}`;
        } else if (data.type === 'chat_message') {
          // Chat retry rows (queued by push-message on transient FCM
          // failures): same tag the direct push-message path uses, so a
          // retried push collapses with the live chat tray entry.
          const key = String(data.match_id ?? data.matchId ?? '').trim();
          if (key) collapseTag = `match_${key}`;
        }
        const rowBadge = Number(data.badge ?? 1);
        // >= 0 (not > 0): an explicit badge of 0 must survive so retractions
        // clear the iOS icon badge instead of resurrecting a phantom "1".
        const safeRowBadge = Number.isFinite(rowBadge) && rowBadge >= 0
          ? Math.min(99, Math.floor(rowBadge))
          : 1;
        // Transport dispatch: WNS channel URIs (queued with platform
        // 'windows', token stored in fcm_token) are toasts; everything else
        // goes through FCM v1 the same way the direct push-message path does.
        const isWnsTarget = isWnsChannelUri(token);
        const result = isWnsTarget
          ? await sendWnsToast(supabase, {
              channelUri: token,
              title,
              body,
              launch: wnsLaunchUri(data.match_id ?? data.matchId ?? data.user_id),
              tag: collapseTag,
              // Chat retry rows queued while older messages were unread
              // land in Action Center silently, matching FCM silent pushes.
              suppressPopup:
                data.silent === 'true' ||
                (data.type === 'chat_message' && data.should_alert === 'false'),
            })
          : await sendFcmV1({
          serviceAccount,
          accessToken,
          token,
          notification: { title, body },
          data: { ...data, badge: String(safeRowBadge) },
          tag: collapseTag,
          collapseKey: collapseTag,
          channelId: channelIdForType(data),
          badge: safeRowBadge,
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

          if (data.type === 'chat_message') {
            // Delivery receipt for retried chat pushes: same guarded update
            // push-message performs for inline sends, so the sender's
            // checkmark flips even when delivery went through the queue.
            const deliveredId = String(data.message_id ?? data.messageId ?? '').trim();
            if (deliveredId) {
              const { error: deliveredErr } = await supabase
                .from('chat_messages')
                .update({ delivered_at: new Date().toISOString() })
                .eq('id', deliveredId)
                .is('delivered_at', null);
              if (deliveredErr) {
                logError(invocationId, 'Failed to mark chat message delivered', deliveredErr, {
                  id,
                  messageId: deliveredId,
                });
              }
            }
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
          return;
        }

        // WNS channel invalidation is permanent (410 Gone): prune the
        // registration. FCM UNREGISTERED keeps its existing RPC.
        const unregistered = isWnsTarget
          ? (result as { expired?: boolean }).expired === true
          : isFcmUnregistered(result.status, result.body);
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
          transport: isWnsTarget ? 'wns' : 'fcm',
          dataType: data.type ?? null,
          broadcastId: data.broadcast_id ?? null,
          fcmTokenPrefix: tokenPrefix(token),
        });

        if (unregistered) {
          try {
            if (isWnsTarget) {
              await supabase.rpc('clear_user_session_wns_channel', { p_wns_channel_uri: token });
            } else {
              await supabase.rpc('clear_user_session_fcm_token', { p_fcm_token: token });
            }
          } catch (e) {
            logError(invocationId, 'Failed to clear UNREGISTERED credential', e, {
              fcmTokenPrefix: tokenPrefix(token),
              transport: isWnsTarget ? 'wns' : 'fcm',
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
    };

    // Bounded concurrency: 10 parallel FCM sends keeps latency ~10x lower
    // for big fan-outs without hammering FCM or the DB connection pool.
    for (let i = 0; i < rows.length; i += QUEUE_SEND_CONCURRENCY) {
      const chunk = rows.slice(i, i + QUEUE_SEND_CONCURRENCY);
      await Promise.all(chunk.map((row) => processQueueRow(row)));
    }

    log(invocationId, 'Notification Queue Processing completed successfully.', { sent: processed });
  } catch (error) {
    logError(invocationId, 'Error during Notification Queue Processing', error);
    throw error;
  }
}

/**
 * Match Expiry Warnings: server-side background push for expiring matches.
 * Runs every cron tick (1m). Checks matches expiring within configured
 * thresholds, and enqueues FCM via notification_queue so warnings fire even
 * when the app is killed or in background. Extension-aware: includes expiry_at
 * in dedup key so same threshold can re-fire after an extension moves expiry.
 */
async function handleMatchExpiryWarnings(invocationId: string) {
  log(invocationId, 'Running Match Expiry Warnings...');
  try {
    // 1) Load thresholds
    let thresholds: number[] = [3600, 900, 300, 60];
    try {
      const { data: cfg } = await supabase
        .from('app_config')
        .select('config_value')
        .eq('config_key', 'matches.chat_start_expiry_warning_seconds')
        .maybeSingle();
      if (cfg?.config_value != null) {
        const raw = cfg.config_value as unknown;
        let arr: unknown = raw;
        if (typeof raw === 'string') { try { arr = JSON.parse(raw as string); } catch { arr = raw; } }
        if (Array.isArray(arr)) {
          const parsed = (arr as unknown[]).map((v) => Number(String(v).trim())).filter((n) => Number.isFinite(n) && n > 0).sort((a, b) => a - b);
          if (parsed.length > 0) thresholds = parsed;
        }
      }
    } catch {}
    if (thresholds.length === 0) thresholds = [3600, 300, 60];
    const maxThreshold = Math.max(...thresholds);
    log(invocationId, 'Expiry thresholds loaded', { thresholds, maxThreshold });

    // Default window for matches with null snapshot
    let defaultWindow = 86400;
    try {
      const { data: wRow } = await supabase.from('app_config').select('config_value').eq('config_key', 'matches.chat_start_window_seconds').maybeSingle();
      if (wRow?.config_value != null) {
        const v = Number(String(wRow.config_value).trim());
        if (Number.isFinite(v) && v > 0) defaultWindow = v;
      }
    } catch {}

    // 2) Fetch candidate matches from last 7 days (covers max window+extension)
    const cutoffCreated = new Date(Date.now() - 7 * 24 * 3600 * 1000).toISOString();
    const { data: matches, error: matchErr } = await supabase
      .from('matches')
      .select('id,user1_id,user2_id,created_at,chat_start_window_seconds,chat_start_extension_seconds,match_type')
      .in('match_type', ['proximity', 'event', 'co_motion'])
      .gte('created_at', cutoffCreated)
      .limit(500);
    if (matchErr) throw matchErr;
    const rows = (matches ?? []) as Array<Record<string, unknown>>;
    if (rows.length === 0) { log(invocationId, 'No candidate matches for expiry warnings'); return; }

    // 3) Exclude matches that already have a chat
    const matchIds = rows.map((r) => String(r.id ?? '').trim()).filter(Boolean);
    const { data: chatRows } = await supabase.from('chat_messages').select('match_id').in('match_id', matchIds.length ? matchIds : ['00000000-0000-0000-0000-000000000000']);
    const hasChat = new Set(((chatRows ?? []) as Array<Record<string, unknown>>).map((r) => String((r as Record<string, unknown>).match_id ?? '').trim()));
    const nowMs = Date.now();
    const now = new Date(nowMs);
    type Candidate = { matchId: string; user1: string; user2: string; expiryMs: number; expiryIso: string; remainingSec: number; threshold: number; createdAt: string };
    const candidates: Candidate[] = [];
    for (const r of rows) {
      const id = String(r.id ?? '').trim();
      if (!id || hasChat.has(id)) continue;
      const u1 = String(r.user1_id ?? '').trim();
      const u2 = String(r.user2_id ?? '').trim();
      if (!u1 || !u2) continue;
      const createdAtStr = String(r.created_at ?? '').trim();
      if (!createdAtStr) continue;
      const createdMs = Date.parse(createdAtStr);
      if (!Number.isFinite(createdMs)) continue;
      const win = Number(r.chat_start_window_seconds ?? defaultWindow);
      const ext = Number(r.chat_start_extension_seconds ?? 0);
      const effWindow = (Number.isFinite(win) && win > 0 ? win : defaultWindow) + (Number.isFinite(ext) && ext > 0 ? ext : 0);
      const expiryMs = createdMs + effWindow * 1000;
      const remainingSec = Math.floor((expiryMs - nowMs) / 1000);
      if (remainingSec <= 0 || remainingSec > maxThreshold) continue;
      let thr: number | null = null;
      for (const t of thresholds) { if (remainingSec <= t) { thr = t; break; } }
      if (thr == null) continue;
      candidates.push({ matchId: id, user1: u1, user2: u2, expiryMs, expiryIso: new Date(expiryMs).toISOString(), remainingSec, threshold: thr, createdAt: createdAtStr });
    }
    if (candidates.length === 0) { log(invocationId, 'No matches within expiry windows', { checked: rows.length }); return; }
    log(invocationId, 'Candidates within expiry windows', { count: candidates.length, thresholds });

    // 4) Batch fetch users, warnings, sessions
    const allUserIds = [...new Set(candidates.flatMap((c) => [c.user1, c.user2]))];
    const { data: users } = await supabase.from('users').select('id,preferred_language,name,notification_preferences').in('id', allUserIds);
    const userMap = new Map<string, Record<string, unknown>>();
    for (const u of (users ?? []) as Array<Record<string, unknown>>) { userMap.set(String(u.id ?? '').trim(), u); }

    // Existing warnings to dedup (match_id, user_id, threshold, expiry).
    // NOTE: expiry_at is timestamptz — PostgREST returns it as
    // "2026-09-03 17:57:00.88+00" while we compute "2026-09-03T17:57:00.880Z".
    // String comparison NEVER matches, causing a re-send every cron tick.
    // Compare by epoch millis instead.
    const candidateMatchIds = [...new Set(candidates.map((c) => c.matchId))];
    const { data: warns } = await supabase.from('match_expiry_warnings').select('match_id,user_id,threshold_seconds,expiry_at').in('match_id', candidateMatchIds.length ? candidateMatchIds : ['00000000-0000-0000-0000-000000000000']);
    const warnedKeys = new Set(((warns ?? []) as Array<Record<string, unknown>>).map((w) => {
      const expiryMs = Date.parse(String(w.expiry_at ?? ''));
      return `${String(w.match_id)}|${String(w.user_id)}|${String(w.threshold_seconds)}|${Number.isFinite(expiryMs) ? expiryMs : String(w.expiry_at)}`;
    }));

    // Only push to recently-active sessions; ancient revoked=false rows
    // (e.g. test devices from months ago) otherwise get spammed forever.
    const sessionCutoffIso = new Date(Date.now() - 60 * 24 * 3600 * 1000).toISOString();
    const { data: sessions } = await supabase.from('user_session').select('user_id,metadata,platform,last_active_at').in('user_id', allUserIds).eq('revoked', false).gte('last_active_at', sessionCutoffIso);
    const tokensByUser = new Map<string, Array<{ token: string; platform: string }>>();
    for (const s of (sessions ?? []) as Array<Record<string, unknown>>) {
      const uid = String(s.user_id ?? '').trim();
      const meta = s.metadata as Record<string, unknown> | null | undefined;
      if (!uid) continue;
      const plat = String(s.platform ?? 'unknown').trim() || 'unknown';
      const arr = tokensByUser.get(uid) ?? [];
      // FCM tokens (ios/android/web) and WNS channel URIs (windows) share the
      // queue column; the drainer dispatches per transport.
      const tok = String(meta?.['fcm_token'] ?? '').trim();
      if (tok && tok.length >= 10) {
        if (!arr.some((e) => e.token === tok)) arr.push({ token: tok, platform: plat });
      }
      const wnsUri = String(meta?.['wns_channel_uri'] ?? '').trim();
      if (wnsUri && isWnsChannelUri(wnsUri)) {
        if (!arr.some((e) => e.token === wnsUri)) {
          arr.push({ token: wnsUri, platform: plat === 'unknown' ? 'windows' : plat });
        }
      }
      tokensByUser.set(uid, arr);
    }

    let enqueued = 0;
    let skippedDisabled = 0;
    let skippedAlreadyWarned = 0;
    let skippedNoToken = 0;
    let skippedDuplicateToken = 0;
    // Same FCM token must never receive two users' content in one run.
    // This happens when one phone tested multiple accounts: the token is
    // stored per-user but FCM delivery is per-token. First user wins.
    const tokensClaimedThisRun = new Map<string, string>();

    for (const c of candidates) {
      for (const uid of [c.user1, c.user2]) {
        const otherUid = uid === c.user1 ? c.user2 : c.user1;
        const warnKey = `${c.matchId}|${uid}|${c.threshold}|${c.expiryMs}`;
        if (warnedKeys.has(warnKey)) { skippedAlreadyWarned++; continue; }

        const userRec = userMap.get(uid);
        // Check notification preference - default true if missing
        const prefs = userRec?.notification_preferences as Record<string, unknown> | null | undefined;
        const enabled = prefs == null ? true : (prefs['enable_match_expiry_notifications'] as unknown);

        const locale = String((userRec?.preferred_language as string) ?? 'en').trim().toLowerCase() || 'en';
        const otherRec = userMap.get(otherUid);
        const otherName = maskFullName(String((otherRec?.name as string) ?? ''));
        const minutesLeft = Math.max(1, Math.ceil(c.remainingSec / 60));
        let title = await getTranslation(locale, 'matchExpiryTitle');
        let body = await getTranslation(locale, 'matchExpiryBody');
        // getTranslation may return key itself if missing; fallback to English
        if (!title || title === 'matchExpiryTitle') title = await getTranslation('en', 'matchExpiryTitle');
        if (!body || body === 'matchExpiryBody') body = await getTranslation('en', 'matchExpiryBody');
        title = String(title).replace('{count}', String(minutesLeft));
        body = String(body).replace('{count}', String(minutesLeft)).replace('{otherUserName}', bidiIsolate(otherName));
        // Transport guard: byte-based truncation (shared limits).
        {
          const enforced = enforceTitleBody(title, body);
          title = enforced.title;
          body = enforced.body || body;
        }

        const data = { type: 'match_expiry', kind: 'match_expiry', user_id: uid, match_id: c.matchId, threshold_seconds: c.threshold, expiry_at: c.expiryIso, remaining_seconds: c.remainingSec, other_user_id: otherUid };

        // Inbox records every warning, regardless of push preferences or
        // registered devices.
        try {
          const { error: inboxErr } = await supabase.from('user_notifications').insert({
            user_id: uid,
            type: 'match_expiry',
            title,
            body,
            data,
          });
          if (inboxErr) {
            logError(invocationId, 'Failed to record expiry warning in inbox', inboxErr, { matchId: c.matchId, userId: uid, threshold: c.threshold });
          }
        } catch (e) {
          logError(invocationId, 'Inbox insert threw (expiry warning)', e as Error, { matchId: c.matchId, userId: uid });
        }

        // Mark as warned now: the inbox row above must never duplicate on the
        // next tick, even when the push itself is suppressed below.
        // Upsert (not insert) makes this idempotent even if two ticks race.
        try {
          const { error: upErr } = await supabase.from('match_expiry_warnings').upsert({
            match_id: c.matchId,
            user_id: uid,
            threshold_seconds: c.threshold,
            expiry_at: c.expiryIso,
          }, { onConflict: 'match_id,user_id,threshold_seconds,expiry_at' });
          if (upErr) throw upErr;
          warnedKeys.add(warnKey);
        } catch (e) {
          logError(invocationId, 'Failed to mark expiry warning as warned', e, { matchId: c.matchId, userId: uid, threshold: c.threshold });
        }

        if (enabled === false) { skippedDisabled++; continue; }

        const tokens = tokensByUser.get(uid) ?? [];
        if (tokens.length === 0) { skippedNoToken++; continue; }

        // Claim tokens for this user first so the same physical device never
        // gets two users' content in one run (stale multi-account sessions).
        const claimable = tokens.filter(({ token }) => {
          const claimedBy = tokensClaimedThisRun.get(token);
          if (claimedBy != null && claimedBy !== uid) {
            skippedDuplicateToken++;
            return false;
          }
          return true;
        });
        if (claimable.length === 0) {
          continue;
        }

        for (const { token, platform } of claimable) {
          try {
            const { error: insErr } = await supabase.from('notification_queue').insert({
              user_id: uid,
              fcm_token: token,
              title,
              body,
              data,
              platform,
              status: 'pending',
              scheduled_at: new Date().toISOString(),
            });
            if (insErr) {
              logError(invocationId, 'Failed to enqueue expiry warning', insErr, { matchId: c.matchId, userId: uid, threshold: c.threshold });
              continue;
            }
            tokensClaimedThisRun.set(token, uid);
            enqueued++;
          } catch (e) {
            logError(invocationId, 'Enqueue threw', e as Error, { matchId: c.matchId, userId: uid });
          }
        }
      }
    }

    log(invocationId, 'Match Expiry Warnings completed', { enqueued, skippedAlreadyWarned, skippedDisabled, skippedNoToken, skippedDuplicateToken, candidates: candidates.length });
  } catch (error) {
    logError(invocationId, 'Error during Match Expiry Warnings', error);
    throw error;
  }
}

/**
 * Pinned Location Expiry Warnings: server-side background push before a pinned
 * home-base location expires. Runs every cron tick. Extension-aware: expiry_at
 * is part of the dedup key so extending a pin re-arms all thresholds.
 *
 * Body copy is unit-aware (separate minutes/hours keys) so every locale gets
 * fully translated text — no English duration words leak into other languages.
 */
async function handlePinnedExpiryWarnings(invocationId: string) {
  log(invocationId, 'Running Pinned Location Expiry Warnings...');
  try {
    // 1) Load thresholds
    let thresholds: number[] = [86400, 3600, 900];
    try {
      const { data: cfg } = await supabase
        .from('app_config')
        .select('config_value')
        .eq('config_key', 'pinned_location_expiry_warning_seconds')
        .maybeSingle();
      if (cfg?.config_value != null) {
        const raw = cfg.config_value as unknown;
        let arr: unknown = raw;
        if (typeof raw === 'string') { try { arr = JSON.parse(raw as string); } catch { arr = raw; } }
        if (Array.isArray(arr)) {
          const parsed = (arr as unknown[]).map((v) => Number(String(v).trim())).filter((n) => Number.isFinite(n) && n > 0).sort((a, b) => a - b);
          if (parsed.length > 0) thresholds = parsed;
        }
      }
    } catch {}
    if (thresholds.length === 0) thresholds = [86400, 3600, 900];
    const maxThreshold = Math.max(...thresholds);

    // 2) Active pins expiring within the widest threshold
    const nowMs = Date.now();
    const horizonIso = new Date(nowMs + maxThreshold * 1000).toISOString();
    const { data: pins, error: pinsErr } = await supabase
      .from('user_locations')
      .select('user_id,pinned_expires_at,pinned_label')
      .eq('is_pinned', true)
      .gt('pinned_expires_at', new Date(nowMs).toISOString())
      .lte('pinned_expires_at', horizonIso)
      .limit(500);
    if (pinsErr) throw pinsErr;
    const rows = (pins ?? []) as Array<Record<string, unknown>>;
    if (rows.length === 0) { log(invocationId, 'No pinned locations near expiry'); return; }

    type PinnedCandidate = { userId: string; expiryMs: number; expiryIso: string; remainingSec: number; threshold: number; label: string };
    const candidates: PinnedCandidate[] = [];
    for (const r of rows) {
      const uid = String(r.user_id ?? '').trim();
      const expiryStr = String(r.pinned_expires_at ?? '').trim();
      if (!uid || !expiryStr) continue;
      const expiryMs = Date.parse(expiryStr);
      if (!Number.isFinite(expiryMs)) continue;
      const remainingSec = Math.floor((expiryMs - nowMs) / 1000);
      if (remainingSec <= 0 || remainingSec > maxThreshold) continue;
      let thr: number | null = null;
      for (const t of thresholds) { if (remainingSec <= t) { thr = t; break; } }
      if (thr == null) continue;
      candidates.push({ userId: uid, expiryMs, expiryIso: new Date(expiryMs).toISOString(), remainingSec, threshold: thr, label: String(r.pinned_label ?? '').trim() });
    }
    if (candidates.length === 0) { log(invocationId, 'No pinned locations within expiry windows', { checked: rows.length }); return; }
    log(invocationId, 'Pinned candidates within expiry windows', { count: candidates.length, thresholds });

    // 3) Batch fetch users, warnings, sessions
    const userIds = [...new Set(candidates.map((c) => c.userId))];
    const { data: users } = await supabase.from('users').select('id,preferred_language,notification_preferences').in('id', userIds);
    const userMap = new Map<string, Record<string, unknown>>();
    for (const u of (users ?? []) as Array<Record<string, unknown>>) { userMap.set(String(u.id ?? '').trim(), u); }

    // Epoch-millis dedup (PostgREST timestamptz strings never match ISO strings).
    const { data: warns } = await supabase.from('pinned_location_warnings').select('user_id,threshold_seconds,expiry_at').in('user_id', userIds);
    const warnedKeys = new Set(((warns ?? []) as Array<Record<string, unknown>>).map((w) => {
      const expiryMs = Date.parse(String(w.expiry_at ?? ''));
      return `${String(w.user_id)}|${String(w.threshold_seconds)}|${Number.isFinite(expiryMs) ? expiryMs : String(w.expiry_at)}`;
    }));

    const sessionCutoffIso = new Date(Date.now() - 60 * 24 * 3600 * 1000).toISOString();
    const { data: sessions } = await supabase.from('user_session').select('user_id,metadata,platform,last_active_at').in('user_id', userIds).eq('revoked', false).gte('last_active_at', sessionCutoffIso);
    const tokensByUser = new Map<string, Array<{ token: string; platform: string }>>();
    for (const s of (sessions ?? []) as Array<Record<string, unknown>>) {
      const uid = String(s.user_id ?? '').trim();
      const meta = s.metadata as Record<string, unknown> | null | undefined;
      if (!uid) continue;
      const plat = String(s.platform ?? 'unknown').trim() || 'unknown';
      const arr = tokensByUser.get(uid) ?? [];
      // FCM tokens (ios/android/web) and WNS channel URIs (windows) share the
      // queue column; the drainer dispatches per transport. (Pinned expiry.)
      const tok = String(meta?.['fcm_token'] ?? '').trim();
      if (tok && tok.length >= 10) {
        if (!arr.some((e) => e.token === tok)) arr.push({ token: tok, platform: plat });
      }
      const wnsUri = String(meta?.['wns_channel_uri'] ?? '').trim();
      if (wnsUri && isWnsChannelUri(wnsUri)) {
        if (!arr.some((e) => e.token === wnsUri)) {
          arr.push({ token: wnsUri, platform: plat === 'unknown' ? 'windows' : plat });
        }
      }
      tokensByUser.set(uid, arr);
    }

    let enqueued = 0;
    let skippedDisabled = 0;
    let skippedAlreadyWarned = 0;
    let skippedNoToken = 0;
    let skippedDuplicateToken = 0;
    // Same FCM token must never receive two users' content in one run.
    const tokensClaimedThisRun = new Map<string, string>();

    for (const c of candidates) {
      const warnKey = `${c.userId}|${c.threshold}|${c.expiryMs}`;
      if (warnedKeys.has(warnKey)) { skippedAlreadyWarned++; continue; }

      const userRec = userMap.get(c.userId);
      // Missing key defaults to TRUE so warnings work before the client setting exists.
      const prefs = userRec?.notification_preferences as Record<string, unknown> | null | undefined;
      const enabled = prefs == null ? true : (prefs['enable_pinned_expiry_notifications'] as unknown);

      const locale = String((userRec?.preferred_language as string) ?? 'en').trim().toLowerCase() || 'en';
      const useHours = c.remainingSec >= 3600;
      const bodyKey = useHours ? 'pinnedExpiryBodyHours' : 'pinnedExpiryBodyMinutes';
      const count = useHours
        ? Math.ceil(c.remainingSec / 3600)
        : Math.max(1, Math.ceil(c.remainingSec / 60));
      let title = await getTranslation(locale, 'pinnedExpiryTitle');
      let body = await getTranslation(locale, bodyKey);
      if (!title || title === 'pinnedExpiryTitle') title = await getTranslation('en', 'pinnedExpiryTitle');
      if (!body || body === bodyKey) body = await getTranslation('en', bodyKey);
      const safeLabel = bidiIsolate(c.label);
      const labelPart = c.label ? ` ("${safeLabel}")` : '';
      title = String(title).replace('{label}', safeLabel).replace('{labelPart}', labelPart);
      body = String(body).replace('{count}', String(count)).replace('{label}', safeLabel).replace('{labelPart}', labelPart);
      {
        const enforced = enforceTitleBody(title, body);
        title = enforced.title;
        body = enforced.body || body;
      }

      const data = { type: 'pinned_expiry', kind: 'pinned_expiry', user_id: c.userId, threshold_seconds: c.threshold, expiry_at: c.expiryIso, remaining_seconds: c.remainingSec };

      // Inbox records every warning, regardless of push preferences or
      // registered devices.
      try {
        const { error: inboxErr } = await supabase.from('user_notifications').insert({
          user_id: c.userId,
          type: 'pinned_expiry',
          title,
          body,
          data,
        });
        if (inboxErr) {
          logError(invocationId, 'Failed to record pinned warning in inbox', inboxErr, { userId: c.userId, threshold: c.threshold });
        }
      } catch (e) {
        logError(invocationId, 'Inbox insert threw (pinned warning)', e as Error, { userId: c.userId });
      }

      // Mark as warned now: the inbox row above must never duplicate on the
      // next tick, even when the push itself is suppressed below.
      // Upsert (not insert) makes this idempotent even if two ticks race.
      try {
        const { error: upErr } = await supabase.from('pinned_location_warnings').upsert({
          user_id: c.userId,
          threshold_seconds: c.threshold,
          expiry_at: c.expiryIso,
        }, { onConflict: 'user_id,threshold_seconds,expiry_at' });
        if (upErr) throw upErr;
        warnedKeys.add(warnKey);
      } catch (e) {
        logError(invocationId, 'Failed to mark pinned warning as warned', e, { userId: c.userId, threshold: c.threshold });
      }

      if (enabled === false) { skippedDisabled++; continue; }

      const tokens = tokensByUser.get(c.userId) ?? [];
      if (tokens.length === 0) { skippedNoToken++; continue; }

      const claimable = tokens.filter(({ token }) => {
        const claimedBy = tokensClaimedThisRun.get(token);
        if (claimedBy != null && claimedBy !== c.userId) {
          skippedDuplicateToken++;
          return false;
        }
        return true;
      });
      if (claimable.length === 0) {
        continue;
      }

      for (const { token, platform } of claimable) {
        try {
          const { error: insErr } = await supabase.from('notification_queue').insert({
            user_id: c.userId,
            fcm_token: token,
            title,
            body,
            data,
            platform,
            status: 'pending',
            scheduled_at: new Date().toISOString(),
          });
          if (insErr) {
            logError(invocationId, 'Failed to enqueue pinned warning', insErr, { userId: c.userId, threshold: c.threshold });
            continue;
          }
          tokensClaimedThisRun.set(token, c.userId);
          enqueued++;
        } catch (e) {
          logError(invocationId, 'Enqueue threw', e as Error, { userId: c.userId });
        }
      }
    }

    log(invocationId, 'Pinned Location Expiry Warnings completed', { enqueued, skippedAlreadyWarned, skippedDisabled, skippedNoToken, skippedDuplicateToken, candidates: candidates.length });
  } catch (error) {
    logError(invocationId, 'Error during Pinned Location Expiry Warnings', error);
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

/**
 * Cleanup old user locations (older than 15 minutes) for privacy
 * 15m matches is_user_truly_visible 15m window so background-stationary
 * users (GPS throttled to 60s, Doze) stay visible/maps while FG dead.
 * Previously 5m caused visible to flap ~5m after screen-off.
 */
async function handleCleanupOldUserLocations(invocationId: string) {
  log(invocationId, 'Running Old User Locations Cleanup (privacy)...');
  try {
    const { data, error } = await supabase.rpc('cleanup_old_user_locations', {
      p_minutes_old: 15,
    });

    if (error) {
      logError(invocationId, 'Error during old user locations cleanup', error);
      throw error;
    }

    const deletedCount = data ?? 0;
    log(invocationId, `Old User Locations Cleanup completed. Deleted ${deletedCount} old location(s).`, {
      deletedCount,
    });
  } catch (error) {
    logError(invocationId, 'Error during Old User Locations Cleanup', error);
    throw error;
  }
}

/**
 * Expire pinned home-base locations past their time, then heartbeat the
 * remaining active pins so the 5-minute matching-pool gate keeps seeing
 * them with zero client GPS writes. Runs before matching + location cleanup.
 */
async function handleExpirePinnedLocations(invocationId: string) {
  log(invocationId, 'Expiring pinned locations past expiry...');
  try {
    const { data, error } = await supabase.rpc('expire_pinned_locations');

    if (error) {
      logError(invocationId, 'Error during pinned location expiry', error);
      throw error;
    }

    const expiredCount = data ?? 0;
    log(invocationId, `Pinned location expiry completed. Expired ${expiredCount} pin(s).`, {
      expiredCount,
    });
  } catch (error) {
    logError(invocationId, 'Error during Pinned Location Expiry', error);
    throw error;
  }
}

async function handleTouchPinnedLocations(invocationId: string) {
  log(invocationId, 'Touching active pinned locations (freshness heartbeat)...');
  try {
    const { data, error } = await supabase.rpc('touch_active_pinned_locations');

    if (error) {
      logError(invocationId, 'Error during pinned location touch', error);
      throw error;
    }

    const touchedCount = data ?? 0;
    log(invocationId, `Pinned location touch completed. Touched ${touchedCount} pin(s).`, {
      touchedCount,
    });
  } catch (error) {
    logError(invocationId, 'Error during Pinned Location Touch', error);
    throw error;
  }
}

/**
 * Cleanup expired offline trail (per-user retention) for privacy.
 * Honors each user's own chosen time — see cleanup_expired_offline_trail().
 */
async function handleCleanupExpiredOfflineTrail(invocationId: string) {
  log(invocationId, 'Running Expired Offline Trail Cleanup (privacy)...');
  try {
    const { data, error } = await supabase.rpc('cleanup_expired_offline_trail');

    if (error) {
      logError(invocationId, 'Error during expired offline trail cleanup', error);
      throw error;
    }

    const deletedCount = data ?? 0;
    log(invocationId, `Expired Offline Trail Cleanup completed. Deleted ${deletedCount} point(s).`, {
      deletedCount,
    });
  } catch (error) {
    logError(invocationId, 'Error during Expired Offline Trail Cleanup', error);
    throw error;
  }
}

/**
 * Cleanup orphan sponsored ad images from storage that are no longer referenced by any ad creative
 */
async function handleCleanupOrphanSponsoredAdImages(invocationId: string) {
  log(invocationId, 'Starting cleanup of orphan sponsored ad images...');
  try {
    // Find all image URLs currently referenced by ad_creatives
    const { data: creatives, error: creativesError } = await supabase
      .from('ad_creatives')
      .select('image_url')
      .not('image_url', 'is', null);

    if (creativesError) {
      logError(invocationId, 'Failed to fetch ad creatives for image cleanup', creativesError);
      throw creativesError;
    }

    // Extract unique image paths from URLs (including subdirectories like campaigns/xxx/filename.jpg)
    const referencedImages = new Set<string>();
    for (const creative of (creatives || [])) {
      if (creative.image_url) {
        try {
          const url = new URL(creative.image_url);
          const pathname = url.pathname;
          // Extract full path from sponsored-ad-images/ onward (e.g., campaigns/xxx/filename.jpg)
          const match = pathname.match(/sponsored-ad-images\/(.+)$/);
          if (match && match[1]) {
            referencedImages.add(match[1]);
          }
        } catch {
          // If URL parsing fails, extract path after sponsored-ad-images/
          const sponsoredMatch = creative.image_url.match(/sponsored-ad-images\/(.+)$/);
          if (sponsoredMatch && sponsoredMatch[1]) {
            referencedImages.add(sponsoredMatch[1]);
          } else {
            // Fallback: just extract the filename
            const parts = creative.image_url.split('/');
            const filename = parts[parts.length - 1];
            if (filename && filename.includes('.')) {
              referencedImages.add(filename);
            }
          }
        }
      }
    }

    log(invocationId, 'Found referenced sponsored ad images', { count: referencedImages.size, sample: Array.from(referencedImages).slice(0, 5) });

    // List all objects in the sponsored-ad-images bucket (root level and campaigns/ subdir)
    const allStorageObjects: Array<{ name: string; created_at?: string | null }> = [];

    // List root level objects
    const { data: rootObjects, error: rootListError } = await supabase
      .storage
      .from('sponsored-ad-images')
      .list('', { limit: 1000 });

    if (rootListError) {
      logError(invocationId, 'Failed to list sponsored-ad-images bucket root', rootListError);
      throw rootListError;
    }

    // Add root level files (not folders)
    for (const obj of (rootObjects || [])) {
      // Folders have id === null, files have a UUID id
      const isFolder = obj.id === null;

      if (!isFolder) {
        allStorageObjects.push(obj);
      } else if (obj.name === 'campaigns' || obj.name === 'campaigns/') {
        // List files in campaigns/ subdirectory
        const { data: campaignObjects, error: campaignListError } = await supabase
          .storage
          .from('sponsored-ad-images')
          .list('campaigns', { limit: 1000 });

        if (campaignListError) {
          logError(invocationId, 'Failed to list campaigns/ subdirectory', campaignListError);
        } else {
          for (const campaignFolder of (campaignObjects || [])) {
            const isCampaignFolder = campaignFolder.id === null;
            if (isCampaignFolder) {
              // List files in each campaign subdirectory
              const campaignName = campaignFolder.name.replace(/\/$/, '');
              const { data: campaignFiles, error: campaignFilesError } = await supabase
                .storage
                .from('sponsored-ad-images')
                .list(`campaigns/${campaignName}`, { limit: 1000 });

              if (!campaignFilesError && campaignFiles) {
                for (const file of campaignFiles) {
                  const isFile = file.id !== null;
                  if (isFile) {
                    allStorageObjects.push({
                      name: `campaigns/${campaignName}/${file.name}`,
                      created_at: file.created_at,
                    });
                  }
                }
              }
            }
          }
        }
      }
    }

    log(invocationId, 'Listed storage objects', { totalObjects: allStorageObjects.length, sample: allStorageObjects.slice(0, 5).map(o => o.name) });

    // Find orphan objects (not referenced by any ad creative)
    //
    // GRACE PERIOD — critical: between an admin uploading an image and
    // clicking Save, the new file is intentionally unreferenced (creatives
    // still point at the previous URL until the save lands). Without a grace
    // period this task deleted freshly uploaded images in that window,
    // leaving live campaigns pointing at dead URLs (404s). Only objects that
    // stayed unreferenced for 24h are true orphans.
    const orphanMinAgeMs = 24 * 60 * 60 * 1000;
    const nowMs = Date.now();
    const orphanObjects = allStorageObjects.filter(obj => {
      if (referencedImages.has(obj.name)) {
        return false;
      }
      const createdAtMs = obj.created_at ? Date.parse(obj.created_at) : NaN;
      if (Number.isNaN(createdAtMs) || nowMs - createdAtMs < orphanMinAgeMs) {
        return false;
      }
      log(invocationId, 'Found orphan object', { name: obj.name, createdAt: obj.created_at });
      return true;
    });

    if (orphanObjects.length === 0) {
      log(invocationId, 'No orphan sponsored ad images found');
      return;
    }

    log(invocationId, 'Found orphan sponsored ad images', { count: orphanObjects.length });

    // Delete orphan objects in batches
    const batchSize = 100;
    let deletedCount = 0;
    const errors: string[] = [];

    for (let i = 0; i < orphanObjects.length; i += batchSize) {
      const batch = orphanObjects.slice(i, i + batchSize);
      const pathsToDelete = batch.map(obj => obj.name);

      const { data: deleteResult, error: deleteError } = await supabase
        .storage
        .from('sponsored-ad-images')
        .remove(pathsToDelete);

      if (deleteError) {
        logError(invocationId, 'Failed to delete batch of orphan images', deleteError, {
          batchIndex: i / batchSize,
          batchSize: pathsToDelete.length,
        });
        errors.push(deleteError.message);
      } else {
        deletedCount += pathsToDelete.length;
        log(invocationId, 'Deleted batch of orphan sponsored ad images', {
          batchIndex: i / batchSize,
          deleted: pathsToDelete.length,
        });
      }
    }

    log(invocationId, 'Orphan sponsored ad images cleanup completed', {
      deletedCount,
      totalOrphans: orphanObjects.length,
      errors: errors.length,
    });
  } catch (error) {
    logError(invocationId, 'Error during orphan sponsored ad images cleanup', error);
    throw error;
  }
}

/**
 * Cleanup old edge_function_invocations records (older than 7 days)
 */
async function handleCleanupEdgeFunctionInvocations(invocationId: string) {
  log(invocationId, 'Running Edge Function Invocations Cleanup...');
  try {
    const { data, error } = await supabase.rpc('cleanup_edge_function_invocations');

    if (error) {
      logError(invocationId, 'Error during edge function invocations cleanup', error);
      throw error;
    }

    const deletedCount = data?.[0]?.deleted_count ?? 0;
    log(invocationId, 'Edge Function Invocations Cleanup completed.', { deletedCount });
  } catch (error) {
    logError(invocationId, 'Error during Edge Function Invocations Cleanup', error);
    throw error;
  }
}

/**
 * Cleanup incomplete signup users (never completed profile, older than 7 days)
 */
async function handleProcessPendingReferrals(invocationId: string) {
  log(invocationId, 'Processing pending referrals...');
  try {
    // Find referrals that are pending, where the referee has a complete profile,
    // and the referral was created >1 hour ago (gives client time to call completeReferral).
    const { data: referrals, error } = await supabase
      .from('referrals')
      .select('id, referee_id')
      .eq('status', 'pending')
      .lt('created_at', new Date(Date.now() - 3600000).toISOString());

    if (error) throw error;

    const rows = (referrals ?? []) as Array<{ id: string; referee_id: string }>;
    if (rows.length === 0) {
      log(invocationId, 'No pending referrals to process.');
      return;
    }

    let completedCount = 0;
    for (const referral of rows) {
      // Check if referee has completed their profile
      const { data: userData } = await supabase
        .from('users')
        .select('is_profile_complete')
        .eq('id', referral.referee_id)
        .single();

      if ((userData as Record<string, unknown> | null)?.is_profile_complete === true) {
        // Complete the referral server-side
        const { error: completeError } = await supabase.rpc('complete_referral', {
          p_user_id: referral.referee_id,
        });

        if (completeError) {
          logError(invocationId, 'Failed to auto-complete referral', completeError, {
            referralId: referral.id,
            refereeId: referral.referee_id,
          });
          continue;
        }
        completedCount++;
        log(invocationId, 'Auto-completed pending referral', {
          referralId: referral.id,
          refereeId: referral.referee_id,
        });
      }
    }

    log(invocationId, 'Pending referral processing completed.', {
      processed: rows.length,
      completed: completedCount,
    });
  } catch (error) {
    logError(invocationId, 'Error processing pending referrals', error);
    throw error;
  }
}

async function handleCleanupStaleProfilePhotoRefs(invocationId: string) {
  log(invocationId, 'Running Stale Profile Photo References Cleanup...');
  try {
    const limit = 100;
    let offset = 0;
    let totalCleaned = 0;
    let totalUsers = 0;

    for (;;) {
      const { data: profiles, error: profilesError } = await supabase
        .from('user_profiles')
        .select('user_id, photos, approved_primary_photos')
        .not('photos', 'is', null)
        .range(offset, offset + limit - 1);

      if (profilesError) throw profilesError;
      if (!profiles || profiles.length === 0) break;

      for (const profile of profiles) {
        const photos: string[] = Array.isArray((profile as Record<string, unknown>).photos)
          ? ((profile as Record<string, unknown>).photos as string[])
          : [];
        if (photos.length === 0) {
          totalUsers++;
          continue;
        }

        const userId = String((profile as Record<string, unknown>).user_id ?? '');
        if (!userId) {
          totalUsers++;
          continue;
        }

        // List files that actually exist in this user's storage folder
        const { data: storageFiles, error: listError } = await supabase
          .storage
          .from('profile-photos')
          .list(userId, { limit: 100 });

        if (listError) {
          logError(invocationId, `Failed to list storage folder for user ${tokenPrefix(userId)}`, listError);
          totalUsers++;
          continue;
        }

        // Build a set of existing filenames (just the filename, not the full path)
        const existingFiles = new Set<string>();
        for (const f of (storageFiles || [])) {
          const isFolder = f.id === null;
          if (!isFolder) {
            const name = String(f.name ?? '');
            if (name) existingFiles.add(name);
          }
        }

        // Filter photos: keep only those whose filename exists in storage
        const originalCount = photos.length;
        const cleanedPhotos = photos.filter((path: string) => {
          const slashIdx = path.lastIndexOf('/');
          const filename = slashIdx >= 0 ? path.substring(slashIdx + 1) : path;
          return existingFiles.has(filename);
        });

        if (cleanedPhotos.length === originalCount) {
          totalUsers++;
          continue;
        }

        // Build DB update payload
        const updatePayload: Record<string, unknown> = {
          photos: cleanedPhotos,
        };

        // Also clean up approved_primary_photos if any referenced photo is stale
        const approvedPrimary: string[] = Array.isArray(
          (profile as Record<string, unknown>).approved_primary_photos,
        )
          ? ((profile as Record<string, unknown>).approved_primary_photos as string[])
          : [];
        if (approvedPrimary.length > 0) {
          const cleanedApproved = approvedPrimary.filter((path: string) => {
            const slashIdx = path.lastIndexOf('/');
            const filename = slashIdx >= 0 ? path.substring(slashIdx + 1) : path;
            return existingFiles.has(filename);
          });
          if (cleanedApproved.length !== approvedPrimary.length) {
            updatePayload.approved_primary_photos = cleanedApproved;
          }
        }

        // Update the user_profiles row
        const { error: updateError } = await supabase
          .from('user_profiles')
          .update(updatePayload)
          .eq('user_id', userId);

        if (updateError) {
          logError(invocationId, `Failed to update user ${tokenPrefix(userId)}`, updateError);
        } else {
          totalCleaned += originalCount - cleanedPhotos.length;
          log(invocationId, `Cleaned ${originalCount - cleanedPhotos.length} stale photo ref(s) for user ${tokenPrefix(userId)}`, {
            userId: tokenPrefix(userId),
            before: originalCount,
            after: cleanedPhotos.length,
          });
        }
        totalUsers++;
      }

      if (profiles.length < limit) break;
      offset += limit;
    }

    log(invocationId, 'Stale Profile Photo References Cleanup completed.', {
      usersChecked: totalUsers,
      staleRefsRemoved: totalCleaned,
    });
  } catch (error) {
    logError(invocationId, 'Error during Stale Profile Photo References Cleanup', error);
    throw error;
  }
}

async function handleCleanupIncompleteSignupUsers(invocationId: string) {
  log(invocationId, 'Running Incomplete Signup Users Cleanup...');
  try {
    const { data, error } = await supabase.rpc('cleanup_incomplete_signup_users');

    if (error) {
      logError(invocationId, 'Error during incomplete signup users cleanup', error);
      throw error;
    }

    const deletedCount = data?.[0]?.deleted_count ?? 0;
    log(invocationId, 'Incomplete Signup Users Cleanup completed.', { deletedCount });
  } catch (error) {
    logError(invocationId, 'Error during Incomplete Signup Users Cleanup', error);
    throw error;
  }
}

/**
 * Cleanup old profile edit requests (approved/rejected, older than 30 days)
 */
async function handleCleanupOldProfileEditRequests(invocationId: string) {
  log(invocationId, 'Running Old Profile Edit Requests Cleanup...');
  try {
    const { data, error } = await supabase.rpc('cleanup_old_profile_edit_requests');

    if (error) {
      logError(invocationId, 'Error during old profile edit requests cleanup', error);
      throw error;
    }

    const deletedCount = data?.[0]?.deleted_count ?? 0;
    log(invocationId, 'Old Profile Edit Requests Cleanup completed.', { deletedCount });
  } catch (error) {
    logError(invocationId, 'Error during Old Profile Edit Requests Cleanup', error);
    throw error;
  }
}

const DISPOSABLE_EMAIL_SYNC_SOURCE_DEFAULT_URL =
  'https://raw.githubusercontent.com/disposable-email-domains/disposable-email-domains/main/disposable_email_blocklist.conf';

type DisposableEmailSyncSettings = {
  enabled: boolean;
  intervalMinutes: number;
  timeoutMs: number;
  sourceUrl: string;
};

async function getDisposableEmailSyncSettings(): Promise<DisposableEmailSyncSettings> {
  const [
    enabledValue,
    intervalValue,
    timeoutValue,
    sourceUrlValue,
  ] = await Promise.all([
    getAppConfigValue('disposable_email.sync_enabled'),
    getAppConfigValue('disposable_email.sync_interval_minutes'),
    getAppConfigValue('disposable_email.sync_timeout_ms'),
    getAppConfigValue('disposable_email.sync_source_url'),
  ]);

  return {
    enabled: configBoolean(enabledValue, true),
    intervalMinutes: Math.max(60, Math.round(configNumber(intervalValue, 1440))),
    timeoutMs: Math.max(3000, Math.min(60000, Math.round(configNumber(timeoutValue, 15000)))),
    sourceUrl: configString(sourceUrlValue, DISPOSABLE_EMAIL_SYNC_SOURCE_DEFAULT_URL).trim() ||
      DISPOSABLE_EMAIL_SYNC_SOURCE_DEFAULT_URL,
  };
}

function normalizeDisposableSyncDomain(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const domain = value.trim().toLowerCase();
  if (!domain || domain.length > 253) return null;
  if (!/^[a-z0-9]([a-z0-9.-]{0,61}[a-z0-9])?\.[a-z]{2,}$/.test(domain)) return null;
  return domain;
}

/**
 * Refresh the disposable email domains blocklist from the community source.
 * Invoked every minute like all cron tasks, but performs a network sync at most
 * once per `disposable_email.sync_interval_minutes` (default daily). Failures are
 * recorded in sync state and retried after the interval — the static bundled
 * blocklists and Disify/IPQS fallbacks keep covering signup screening meanwhile.
 */
async function handleDisposableEmailDomainsSync(invocationId: string) {
  const settings = await getDisposableEmailSyncSettings();
  if (!settings.enabled) {
    log(invocationId, 'Disposable email domains sync skipped; disabled in app_config.');
    return;
  }

  const { data: stateRow, error: stateError } = await supabase
    .from('disposable_email_sync_state')
    .select('last_sync_at')
    .eq('id', 1)
    .maybeSingle();
  if (stateError) throw stateError;

  const lastSyncAt = (() => {
    try {
      const raw = (stateRow as { last_sync_at?: unknown } | null)?.last_sync_at;
      if (typeof raw === 'string' && raw) {
        const dt = new Date(raw);
        return Number.isNaN(dt.getTime()) ? null : dt;
      }
    } catch {
      // Ignore malformed sync state and proceed with a sync.
    }
    return null;
  })();
  if (lastSyncAt && Date.now() - lastSyncAt.getTime() < settings.intervalMinutes * 60_000) {
    log(invocationId, 'Disposable email domains sync skipped; blocklist is still fresh.', {
      lastSyncAt: lastSyncAt.toISOString(),
      intervalMinutes: settings.intervalMinutes,
    });
    return;
  }

  const syncStartIso = new Date().toISOString();
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), settings.timeoutMs);
    let sourceText: string;
    try {
      const response = await fetch(settings.sourceUrl, { signal: controller.signal });
      if (!response.ok) {
        throw new Error(`Blocklist source HTTP ${response.status}`);
      }
      sourceText = await response.text();
    } finally {
      clearTimeout(timeoutId);
    }

    const domains = Array.from(new Set(
      sourceText.split('\n')
        .map(normalizeDisposableSyncDomain)
        .filter((d): d is string => !!d),
    ));
    if (domains.length === 0) {
      throw new Error('Blocklist source returned no valid domains; keeping existing data.');
    }
    if (domains.length > 100000) {
      throw new Error(`Blocklist unexpectedly large (${domains.length}); aborting to avoid overload.`);
    }

    let upserted = 0;
    const chunkSize = 1000;
    for (let i = 0; i < domains.length; i += chunkSize) {
      const { data, error } = await supabase.rpc('upsert_disposable_email_domains_batch', {
        p_domains: domains.slice(i, i + chunkSize),
        p_source: 'community-blocklist',
      });
      if (error) throw error;
      upserted += Number(data ?? 0);
    }

    const { data: pruned, error: pruneError } = await supabase.rpc('prune_disposable_email_domains', {
      p_older_than: syncStartIso,
    });
    if (pruneError) throw pruneError;

    const { error: syncStateError } = await supabase
      .from('disposable_email_sync_state')
      .upsert({
        id: 1,
        last_sync_at: syncStartIso,
        last_count: domains.length,
        last_source: settings.sourceUrl,
        last_error: null,
        updated_at: syncStartIso,
      }, { onConflict: 'id' });
    if (syncStateError) throw syncStateError;

    log(invocationId, 'Disposable email domains synced successfully.', {
      fetched: domains.length,
      upserted,
      pruned: Number(pruned ?? 0),
    });
  } catch (error) {
    // Record the failure so retries back off until the next interval instead of
    // hammering a broken source every minute.
    try {
      await supabase
        .from('disposable_email_sync_state')
        .upsert({
          id: 1,
          last_sync_at: new Date().toISOString(),
          last_error: error instanceof Error ? error.message : String(error),
          updated_at: new Date().toISOString(),
        }, { onConflict: 'id' });
    } catch {
      // Ignore state-write failures; the original error is what matters.
    }
    throw error;
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

serve(async (req: Request) => {
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

  // Shared-secret gate: when MATCHME_INTERNAL_SECRET is configured (the
  // pg_cron/pg_net schedule passes it as the x-matchme-internal header),
  // reject unauthenticated invocations — the function triggers all 28 tasks
  // and can send real FCM pushes. When the env var is unset, fall open so
  // legacy dashboard-configured schedules keep working.
  const internalSecret = (Deno.env.get("MATCHME_INTERNAL_SECRET") ?? "").trim();
  if (internalSecret !== "") {
    const provided = (req.headers.get("x-matchme-internal") ?? "").trim();
    if (provided !== internalSecret) {
      console.log(`[${functionName}] rejected: missing/invalid x-matchme-internal header`);
      return new Response(JSON.stringify({ error: "Forbidden" }), {
        status: 403,
        headers: { "Content-Type": "application/json" },
      });
    }
  }

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
      await runCronTask(invocationId, 'cleanup_stale_online_users', () => cleanupStaleOnlineUsers()),
      await runCronTask(invocationId, 'cleanup_old_presence_events', () => cleanupOldPresenceEvents()),
      await runCronTask(invocationId, 'invisibility_schedules', () => handleInvisibilitySchedules()),
      await runCronTask(invocationId, 'cleanup_expired_matches', () => cleanupExpiredMatches()),
      await runCronTask(invocationId, 'expire_pinned_locations', () => handleExpirePinnedLocations(invocationId)),
      await runCronTask(invocationId, 'touch_active_pinned_locations', () => handleTouchPinnedLocations(invocationId)),
      await runCronTask(invocationId, 'cleanup_old_user_locations', () => handleCleanupOldUserLocations(invocationId)),
      await runCronTask(invocationId, 'cleanup_expired_offline_trail', () => handleCleanupExpiredOfflineTrail(invocationId)),
      await runCronTask(invocationId, 'currency_exchange_rates_refresh', () => handleCurrencyExchangeRateRefresh(invocationId)),
      await runCronTask(invocationId, 'continuous_event_matching', () => handleContinuousEventMatching()),
      await runCronTask(invocationId, 'continuous_user_matching', () => handleContinuousUserMatching()),
      await runCronTask(invocationId, 'cleanup_orphan_profile_photos', () => handleCleanupOrphanProfilePhotos(invocationId)),
      await runCronTask(invocationId, 'cleanup_stale_profile_photo_refs', () => handleCleanupStaleProfilePhotoRefs(invocationId)),
      await runCronTask(invocationId, 'cleanup_orphan_sponsored_ad_images', () => handleCleanupOrphanSponsoredAdImages(invocationId)),
      await runCronTask(invocationId, 'scheduled_admin_broadcasts', () => handleScheduledAdminBroadcasts(invocationId)),
      await runCronTask(invocationId, 'birthday_broadcast_automations', () => handleBirthdayBroadcastAutomations(invocationId)),
      await runCronTask(invocationId, 'profile_completion_reminders', () => handleProfileCompletionReminders(invocationId)),
      await runCronTask(invocationId, 'match_expiry_warnings', () => handleMatchExpiryWarnings(invocationId)),
      await runCronTask(invocationId, 'pinned_location_expiry_warnings', () => handlePinnedExpiryWarnings(invocationId)),
      await runCronTask(invocationId, 'notification_queue_processing', () => handleNotificationQueueProcessing(invocationId)),
      await runCronTask(invocationId, 'cleanup_expired_email_codes', () => handleCleanupExpiredEmailCodes(invocationId)),
      await runCronTask(invocationId, 'cleanup_pending_email_changes', () => handleCleanupPendingEmailChanges(invocationId)),
      await runCronTask(invocationId, 'ai_quota_monitoring', () => handleAiQuotaMonitoring(invocationId)),
      await runCronTask(invocationId, 'cleanup_edge_function_invocations', () => handleCleanupEdgeFunctionInvocations(invocationId)),
      await runCronTask(invocationId, 'cleanup_incomplete_signup_users', () => handleCleanupIncompleteSignupUsers(invocationId)),
      await runCronTask(invocationId, 'cleanup_old_profile_edit_requests', () => handleCleanupOldProfileEditRequests(invocationId)),
      await runCronTask(invocationId, 'process_pending_referrals', () => handleProcessPendingReferrals(invocationId)),
      await runCronTask(invocationId, 'disposable_email_domains_sync', () => handleDisposableEmailDomainsSync(invocationId)),
      await runCronTask(invocationId, 'health_sampler', () => handleHealthSampler()),
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
    return new Response(JSON.stringify({ success: false, error: errorMessage }), {
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
