// health_sampler — 30-minute snapshots of system-health metrics for the
// admin System Health History screen (admin_health_snapshots table).
//
// Runs inside the cron-jobs edge function (invoked every minute by pg_cron).
// A stateless gate skips all work until the newest snapshot is ~29.5 minutes
// old, so the effective sampling cadence is ~30 minutes regardless of the
// 1-minute trigger. The admin live probe (`project-logs-health`) serves
// these snapshots with a 40-minute TTL, so a missing run is retried by the
// next cron minute and still covered. Each source is collected
// independently; a failing source simply omits its row (a gap in history,
// never a cron-jobs task failure — this task never throws).
//
// Sources per sample:
//  db        — timed health_check() RPC (latency, success)
//  queue     — get_notification_queue_health() RPC (full payload)
//  errors    — admin_get_health_errors() RPC (rolling 15m/1h counts)
//  statuspage— status.supabase.com summary.json (indicator + incidents)
//  auth      — ClickHouse sign-ins / auth errors (shared module, detail off)
//  usage     — disk utilization + API request count (Management API)
//
// After a successful write the sampler prunes rows older than 7 days.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  collectProjectLogsHealth,
  FETCH_TIMEOUT_MS,
} from "../_shared/project_logs_health.ts";

const SAMPLE_INTERVAL_MS = 29.5 * 60 * 1000;

type SnapshotRow = {
  source: "db" | "queue" | "statuspage" | "usage" | "auth" | "errors";
  payload: Record<string, unknown>;
  overall: string | null;
};

function log(msg: string, extra?: Record<string, unknown>) {
  console.log(
    `[health-sampler] ${msg}${extra ? ` ${JSON.stringify(extra)}` : ""}`,
  );
}

async function shouldSkip(supabase: SupabaseClient): Promise<boolean> {
  const { data, error } = await supabase
    .from("admin_health_snapshots")
    .select("captured_at")
    .order("captured_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) {
    // Table missing or unreadable — skip rather than spam failing inserts.
    log("gate query failed; skipping this run", { error: error.message });
    return true;
  }
  if (!data?.captured_at) return false; // first sample ever — run now
  const last = new Date(String(data.captured_at)).getTime();
  if (!Number.isFinite(last)) return false;
  return Date.now() - last < SAMPLE_INTERVAL_MS;
}

async function collectDb(supabase: SupabaseClient): Promise<SnapshotRow | null> {
  const started = Date.now();
  let ok = false;
  let error: string | null = null;
  try {
    const res = await supabase.rpc("health_check");
    if (res.error) {
      ok = false;
      error = res.error.message;
    } else if (res.data && typeof res.data === "object") {
      const map = res.data as Record<string, unknown>;
      ok = map.ok !== false;
      if (!ok) error = String(map.error ?? "health_check returned ok=false");
    } else {
      ok = true;
    }
  } catch (e) {
    ok = false;
    error = e instanceof Error ? e.message : String(e);
  }
  return {
    source: "db",
    payload: {
      ok,
      latency_ms: Date.now() - started,
      error,
    },
    overall: ok ? "ok" : "down",
  };
}

async function collectQueue(supabase: SupabaseClient): Promise<SnapshotRow | null> {
  try {
    const res = await supabase.rpc("get_notification_queue_health");
    if (res.error || !res.data || typeof res.data !== "object") return null;
    return {
      source: "queue",
      payload: res.data as Record<string, unknown>,
      overall: null,
    };
  } catch (e) {
    log("queue collection failed", { error: e instanceof Error ? e.message : String(e) });
    return null;
  }
}

async function collectErrors(supabase: SupabaseClient): Promise<SnapshotRow | null> {
  try {
    const res = await supabase.rpc("admin_get_health_errors");
    if (res.error || !res.data || typeof res.data !== "object") return null;
    return {
      source: "errors",
      payload: res.data as Record<string, unknown>,
      overall: null,
    };
  } catch (e) {
    log("errors collection failed", { error: e instanceof Error ? e.message : String(e) });
    return null;
  }
}

async function collectStatuspage(): Promise<SnapshotRow | null> {
  try {
    const res = await fetch("https://status.supabase.com/api/v2/summary.json", {
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) return null;
    const body = (await res.json().catch(() => null)) as Record<string, unknown> | null;
    if (!body || typeof body !== "object") return null;
    const status = (body.status ?? {}) as Record<string, unknown>;
    const incidents = Array.isArray(body.incidents) ? body.incidents.length : 0;
    const indicator = typeof status.indicator === "string" ? status.indicator : null;
    return {
      source: "statuspage",
      payload: {
        indicator,
        description: typeof status.description === "string" ? status.description : null,
        incidents_active: incidents,
      },
      overall: indicator === "none" || indicator == null ? "ok" : "degraded",
    };
  } catch (e) {
    log("statuspage collection failed", { error: e instanceof Error ? e.message : String(e) });
    return null;
  }
}

function splitLogsPayload(
  logs: Awaited<ReturnType<typeof collectProjectLogsHealth>>,
): SnapshotRow[] {
  const rows: SnapshotRow[] = [];
  rows.push({
    source: "auth",
    payload: {
      configured: logs.configured,
      signins_15m: logs.signins_15m,
      signins_last_at: logs.signins_last_at,
      auth_errors_15m: logs.auth_errors_15m,
      auth_last_error_at: logs.auth_last_error_at,
      warnings: logs.warnings.filter((w) => w.startsWith("signins") || w.startsWith("auth")),
    },
    overall: null,
  });
  rows.push({
    source: "usage",
    payload: {
      configured: logs.configured,
      disk_used_bytes: logs.disk_used_bytes,
      disk_size_bytes: logs.disk_size_bytes,
      disk_avail_bytes: logs.disk_avail_bytes,
      api_requests_count: logs.api_requests_count,
      warnings: logs.warnings.filter((w) => w.startsWith("disk") || w.startsWith("api") || w.startsWith("management")),
    },
    overall: null,
  });
  return rows;
}

export async function handleHealthSampler(): Promise<void> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const managementToken = (Deno.env.get("MANAGEMENT_API_TOKEN") ?? "").trim();
  if (!supabaseUrl || !serviceRoleKey) {
    log("missing env (SUPABASE_URL / service role); skipping");
    return;
  }
  const supabase: SupabaseClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  if (await shouldSkip(supabase)) return;

  const rows: SnapshotRow[] = [];

  const db = await collectDb(supabase);
  if (db) rows.push(db);
  const queue = await collectQueue(supabase);
  if (queue) rows.push(queue);
  const errors = await collectErrors(supabase);
  if (errors) rows.push(errors);
  const statuspage = await collectStatuspage();
  if (statuspage) rows.push(statuspage);

  try {
    const logs = await collectProjectLogsHealth({
      supabaseUrl,
      managementToken,
      detail: false,
    });
    rows.push(...splitLogsPayload(logs));
  } catch (e) {
    log("logs collection failed", { error: e instanceof Error ? e.message : String(e) });
  }

  if (rows.length === 0) {
    log("no sources collected; skipping insert");
    return;
  }

  const nowIso = new Date().toISOString();
  const { error: insertError } = await supabase.from("admin_health_snapshots").insert(
    rows.map((r) => ({
      captured_at: nowIso,
      source: r.source,
      payload: r.payload,
      overall: r.overall,
    })),
  );
  if (insertError) {
    log("insert failed", { error: insertError.message });
    return;
  }
  log("sample written", { sources: rows.map((r) => r.source) });

  const { error: pruneError } = await supabase.rpc("prune_admin_health_snapshots");
  if (pruneError) log("prune failed", { error: pruneError.message });
}
