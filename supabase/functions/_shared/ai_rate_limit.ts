// Shared AI rate limiting for edge functions that send user content to an
// AI service (Gemini, Cloud Vision, DeepL). One unit is consumed per
// function invocation that will reach an AI call; dedupe/prescreen-style
// short-circuits run BEFORE consuming so free paths stay free.
//
// Limits are configured per task via the app_config table (editable in the
// admin app):
//   ai.rate_limit.<task>.hourly
//   ai.rate_limit.<task>.daily
// A limit <= 0 disables that window's gate. Values are cached for 5 minutes.
// Counter windows are fixed (hour/day) in ai_rate_limit_usage, incremented
// atomically by the consume_ai_rate_limit Postgres function. Any config or
// counter failure fails OPEN (request allowed) — availability over strictness.

const CONFIG_TTL_MS = 5 * 60 * 1000;

export type AiTaskType =
  | "primary_photo_validation"
  | "secondary_photo_validation"
  | "verification_face_comparison"
  | "bio_moderation"
  | "event_file_parse"
  | "event_metadata"
  | "translation";

interface WindowLimits {
  hourly: number;
  daily: number;
}

// Built-in defaults; mirrored by the seed rows in migration
// 20262093000000_ai_rate_limiting.sql.
const DEFAULT_LIMITS: Record<AiTaskType, WindowLimits> = {
  primary_photo_validation: { hourly: 20, daily: 100 },
  secondary_photo_validation: { hourly: 40, daily: 200 },
  verification_face_comparison: { hourly: 10, daily: 50 },
  bio_moderation: { hourly: 30, daily: 150 },
  event_file_parse: { hourly: 10, daily: 30 },
  event_metadata: { hourly: 30, daily: 150 },
  translation: { hourly: 100, daily: 500 },
};

export const AI_RATE_LIMIT_CONFIG_PREFIX = "ai.rate_limit.";

const TASKS = Object.keys(DEFAULT_LIMITS) as AiTaskType[];

const CONFIG_KEYS = TASKS.flatMap((task) => [
  `${AI_RATE_LIMIT_CONFIG_PREFIX}${task}.hourly`,
  `${AI_RATE_LIMIT_CONFIG_PREFIX}${task}.daily`,
]);

interface ConfigCache {
  values: Map<string, number>;
  at: number;
}

let _configCache: ConfigCache | null = null;
let _configInflight: Promise<Map<string, number>> | null = null;

// Minimal structural type for a Supabase client (rpc returns a
// PostgrestFilterBuilder, which is thenable — hence PromiseLike).
interface AiSupabaseClient {
  from: (table: string) => any;
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<any>;
}

async function loadConfigOverrides(
  supabase: AiSupabaseClient,
): Promise<Map<string, number>> {
  if (_configCache && Date.now() - _configCache.at < CONFIG_TTL_MS) {
    return _configCache.values;
  }
  if (!_configInflight) {
    _configInflight = (async () => {
      const values = new Map<string, number>();
      try {
        const { data, error } = await (supabase as any)
          .from("app_config")
          .select("config_key, config_value")
          .in("config_key", CONFIG_KEYS);
        if (!error && Array.isArray(data)) {
          for (const row of data) {
            // config_value is JSONB — supabase-js surfaces numbers as numbers,
            // but tolerate string-encoded values too.
            const raw = row.config_value;
            const parsed = typeof raw === "number"
              ? raw
              : Number.parseInt(String(raw ?? ""), 10);
            if (Number.isFinite(parsed)) values.set(String(row.config_key), parsed);
          }
        }
      } catch (_) {
        // Keep defaults on failure.
      }
      return values;
    })().finally(() => {
      _configInflight = null;
    });
    const values = await _configInflight;
    _configCache = { values, at: Date.now() };
    return values;
  }
  return _configInflight;
}

async function hashIdentifier(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest))
    .slice(0, 16)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export function getClientIp(req: Request): string | null {
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) {
    const first = forwarded.split(",")[0]?.trim();
    if (first) return first;
  }
  return req.headers.get("cf-connecting-ip");
}

export interface AiRateLimitOptions {
  task: AiTaskType;
  /** Authenticated user id, when the request has one. */
  userId?: string | null;
  /** Client IP for tasks without user context; hashed before storage. */
  ip?: string | null;
  requestId?: string;
}

export interface AiRateLimitResult {
  allowed: boolean;
  retryAfterSeconds: number;
  hourlyLimit: number;
  dailyLimit: number;
}

/**
 * Consumes one unit of quota for the task. Call only on paths that will
 * reach an AI service. Fails open on any internal error.
 */
export async function consumeAiRateLimit(
  supabase: AiSupabaseClient,
  opts: AiRateLimitOptions,
): Promise<AiRateLimitResult> {
  const defaults = DEFAULT_LIMITS[opts.task];
  const failOpen: AiRateLimitResult = {
    allowed: true,
    retryAfterSeconds: 0,
    hourlyLimit: defaults.hourly,
    dailyLimit: defaults.daily,
  };
  try {
    const overrides = await loadConfigOverrides(supabase);
    const hourly =
      overrides.get(`${AI_RATE_LIMIT_CONFIG_PREFIX}${opts.task}.hourly`) ?? defaults.hourly;
    const daily =
      overrides.get(`${AI_RATE_LIMIT_CONFIG_PREFIX}${opts.task}.daily`) ?? defaults.daily;
    const limits = { hourly, daily };

    if (hourly <= 0 && daily <= 0) {
      return { ...failOpen, hourlyLimit: hourly, dailyLimit: daily };
    }

    const identifier = opts.userId
      ? opts.userId
      : opts.ip
      ? `ip:${await hashIdentifier(opts.ip)}`
      : null;
    if (!identifier) return { ...failOpen, hourlyLimit: hourly, dailyLimit: daily };

    const { data, error } = await supabase.rpc("consume_ai_rate_limit", {
      p_identifier: identifier,
      p_task: opts.task,
      p_hourly_limit: hourly,
      p_daily_limit: daily,
    });
    if (error) {
      console.warn(
        `[ai_rate_limit] consume failed (failing open): ${error.message ?? String(error)}`,
      );
      return { ...failOpen, hourlyLimit: hourly, dailyLimit: daily };
    }
    const row = Array.isArray(data) ? data[0] : data;
    return {
      allowed: row?.allowed !== false,
      retryAfterSeconds: typeof row?.retry_after_seconds === "number"
        ? row.retry_after_seconds
        : 0,
      hourlyLimit: hourly,
      dailyLimit: daily,
    };
  } catch (e) {
    console.warn(
      `[ai_rate_limit] unexpected error (failing open): ${e instanceof Error ? e.message : String(e)}`,
    );
    return failOpen;
  }
}
