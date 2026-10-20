import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { withInvocationLogging } from "../_shared/edge_function_logger.ts";
import { collectProjectLogsHealth } from "../_shared/project_logs_health.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const managementToken = (Deno.env.get("MANAGEMENT_API_TOKEN") ?? "").trim();

// Serve from the health_sampler snapshots when they are fresh.
//
// Every live probe used to run 2-3 ClickHouse log queries (15-minute window
// each) plus Management API calls. With the admin dashboard + keep-alive
// polling that accumulated to ~1.4 TB/day of log-query bytes on a Free-plan
// project. The sampler now writes `auth` / `usage` snapshots every ~30
// minutes, so a 40-minute TTL covers the gap between samples (plus one missed
// run). Values are at most as old as `checked_at` (the snapshot timestamp),
// and `?force=true` (or `{"force": true}` in a JSON body) still collects
// fresh numbers on demand.
const SNAPSHOT_CACHE_TTL_MS = 40 * 60 * 1000;

const MONITORING_ENABLED_CONFIG_KEY = "admin.supabase_monitoring.enabled";

const svc =
  supabaseUrl && serviceRoleKey
    ? createClient(supabaseUrl, serviceRoleKey, {
        auth: { persistSession: false },
      })
    : null;

type SnapshotRow = {
  source: string;
  payload: Record<string, unknown> | null;
  captured_at: string;
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function configBoolean(value: unknown, fallback: boolean): boolean {
  if (value == null) return fallback;
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value !== 0;
  const normalized = String(value)
    .trim()
    .replace(/^"|"$/g, "")
    .toLowerCase();
  if (["true", "1", "yes", "on"].includes(normalized)) return true;
  if (["false", "0", "no", "off"].includes(normalized)) return false;
  return fallback;
}

/// Refuse to spend Management API / ClickHouse queries when the admin app's
/// System Health feature is disabled. Older admin clients may still poll this
/// endpoint, so the switch is enforced server-side as well.
async function isMonitoringEnabled(): Promise<boolean> {
  if (!svc) return true;
  try {
    const { data, error } = await svc
      .from("app_config")
      .select("config_value")
      .eq("config_key", MONITORING_ENABLED_CONFIG_KEY)
      .maybeSingle();
    if (error) return true;
    return configBoolean(data?.config_value, true);
  } catch (_) {
    return true;
  }
}

function isFresh(capturedAt: string): boolean {
  const ms = new Date(capturedAt).getTime();
  return Number.isFinite(ms) && Date.now() - ms <= SNAPSHOT_CACHE_TTL_MS;
}

function asWarnings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((w): w is string => typeof w === "string")
    : [];
}

async function payloadFromSnapshots(): Promise<Record<string, unknown> | null> {
  if (!svc) return null;
  const { data, error } = await svc
    .from("admin_health_snapshots")
    .select("source, payload, captured_at")
    .in("source", ["auth", "usage"])
    .order("captured_at", { ascending: false })
    .limit(20);
  if (error || !Array.isArray(data)) return null;
  const rows = data as unknown as SnapshotRow[];
  const newestFor = (source: string): SnapshotRow | undefined =>
    rows.find((r) => r.source === source);
  const auth = newestFor("auth");
  const usage = newestFor("usage");
  if (!auth || !usage) return null;
  if (!isFresh(auth.captured_at) || !isFresh(usage.captured_at)) return null;
  const authPayload = (auth.payload ?? {}) as Record<string, unknown>;
  const usagePayload = (usage.payload ?? {}) as Record<string, unknown>;
  return {
    configured:
      authPayload.configured === true || usagePayload.configured === true,
    checked_at: auth.captured_at,
    signins_15m: authPayload.signins_15m ?? null,
    signins_last_at: authPayload.signins_last_at ?? null,
    auth_errors_15m: authPayload.auth_errors_15m ?? null,
    auth_last_error_at: authPayload.auth_last_error_at ?? null,
    auth_last_error_message: null,
    auth_last_error_action: null,
    disk_used_bytes: usagePayload.disk_used_bytes ?? null,
    disk_size_bytes: usagePayload.disk_size_bytes ?? null,
    disk_avail_bytes: usagePayload.disk_avail_bytes ?? null,
    api_requests_count: usagePayload.api_requests_count ?? null,
    warnings: [
      ...asWarnings(authPayload.warnings),
      ...asWarnings(usagePayload.warnings),
    ],
    served_from_snapshots: true,
  };
}

async function readForceFlag(req: Request): Promise<boolean> {
  try {
    const url = new URL(req.url);
    if ((url.searchParams.get("force") ?? "").toLowerCase() === "true") {
      return true;
    }
  } catch (_) {
    // Fall through to the body check.
  }
  if (req.method !== "POST") return false;
  try {
    const body = (await req.json()) as Record<string, unknown> | null;
    return body?.force === true;
  } catch (_) {
    return false;
  }
}

async function authorize(req: Request): Promise<boolean> {
  if (!svc) return false;
  const header = req.headers.get("Authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "").trim();
  if (!token) return false;
  if (serviceRoleKey && token === serviceRoleKey) return true;
  const { data, error } = await svc.auth.getUser(token);
  if (error || !data?.user) return false;
  const { data: profile, error: profileError } = await svc
    .from("users")
    .select("is_admin")
    .eq("id", data.user.id)
    .maybeSingle();
  if (profileError) throw profileError;
  return profile?.is_admin === true;
}

serve(withInvocationLogging("project-logs-health", async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (!svc) {
    return jsonResponse({ error: "SUPABASE_SERVICE_ROLE_KEY is not configured." }, 500);
  }
  const allowed = await authorize(req);
  if (!allowed) {
    return jsonResponse({ error: "forbidden" }, 403);
  }

  if (!(await isMonitoringEnabled())) {
    return jsonResponse({
      disabled: true,
      configured: false,
      checked_at: new Date().toISOString(),
      warnings: ["Supabase monitoring is disabled in app_config."],
    });
  }

  const force = await readForceFlag(req);
  if (!force) {
    const cached = await payloadFromSnapshots();
    if (cached) return jsonResponse(cached);
  }

  const payload = await collectProjectLogsHealth({
    supabaseUrl,
    managementToken,
    detail: true,
  });
  return jsonResponse({
    ...(payload as unknown as Record<string, unknown>),
    served_from_snapshots: false,
  });
}));
