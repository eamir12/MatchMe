import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { withInvocationLogging } from "../_shared/edge_function_logger.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const managementToken = (Deno.env.get("SUPABASE_ACCESS_TOKEN") ?? "").trim();

const svc =
  supabaseUrl && serviceRoleKey
    ? createClient(supabaseUrl, serviceRoleKey, {
        auth: { persistSession: false },
      })
    : null;

const AUTH_WINDOW_MS = 15 * 60 * 1000;
const FETCH_TIMEOUT_MS = 10_000;

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function projectRef(): string | null {
  try {
    const host = new URL(supabaseUrl).hostname;
    const ref = host.split(".")[0] ?? "";
    return ref.length > 0 ? ref : null;
  } catch {
    return null;
  }
}

function clickhouseTime(d: Date): string {
  return d.toISOString().slice(0, 19).replace("T", " ");
}

function isoOrNull(value: unknown): string | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    const ms = value < 1e12 ? value * 1000 : value;
    const parsed = new Date(ms);
    return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
  }
  if (typeof value !== "string") return null;
  const raw = value.trim();
  if (!raw) return null;
  const hasZone = /Z$|[+-]\d{2}:?\d{2}$/.test(raw);
  const candidate = hasZone
    ? raw
    : raw.includes("T")
    ? `${raw}Z`
    : `${raw.replace(" ", "T")}Z`;
  const parsed = new Date(candidate);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
}

function numOrNull(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function truncateMessage(value: unknown, max = 300): string | null {
  if (value == null) return null;
  const text = typeof value === "string" ? value : String(value);
  if (!text.trim()) return null;
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

type LogsQueryOutcome = { rows: Record<string, unknown>[]; error: string | null };

async function runLogsQuery(
  sql: string,
  columns: string[],
  start: Date,
  end: Date,
): Promise<LogsQueryOutcome> {
  const ref = projectRef();
  if (!ref) return { rows: [], error: "project_ref_unavailable" };
  const params = new URLSearchParams({
    sql,
    iso_timestamp_start: start.toISOString(),
    iso_timestamp_end: end.toISOString(),
  });
  let res: Response;
  try {
    res = await fetch(
      `https://api.supabase.com/v1/projects/${ref}/analytics/endpoints/logs?${params.toString()}`,
      {
        headers: {
          Authorization: `Bearer ${managementToken}`,
          Accept: "application/json",
        },
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      },
    );
  } catch (e) {
    return {
      rows: [],
      error: `logs_fetch_failed: ${e instanceof Error ? e.message : String(e)}`,
    };
  }
  const body = (await res.json().catch(() => null)) as Record<string, unknown> |
    null;
  if (!res.ok) return { rows: [], error: `logs_http_${res.status}` };
  const remoteError =
    typeof body?.error === "string" && body.error.trim().length > 0
      ? body.error.trim()
      : null;
  if (remoteError) return { rows: [], error: remoteError };
  const rawResult = body?.result;
  if (!Array.isArray(rawResult)) return { rows: [], error: "logs_unexpected_shape" };
  const rows: Record<string, unknown>[] = [];
  for (const entry of rawResult) {
    if (entry && typeof entry === "object" && !Array.isArray(entry)) {
      rows.push(entry as Record<string, unknown>);
      continue;
    }
    if (Array.isArray(entry)) {
      const row: Record<string, unknown> = {};
      columns.forEach((column, index) => {
        row[column] = entry[index];
      });
      rows.push(row);
    }
  }
  return { rows, error: null };
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

  const now = new Date();
  const start = new Date(now.getTime() - AUTH_WINDOW_MS);
  const warnings: string[] = [];
  const payload: Record<string, unknown> = {
    configured: false,
    checked_at: now.toISOString(),
    signins_15m: null,
    signins_last_at: null,
    auth_errors_15m: null,
    auth_last_error_at: null,
    auth_last_error_message: null,
    auth_last_error_action: null,
    disk_used_bytes: null,
    disk_size_bytes: null,
    disk_avail_bytes: null,
    api_requests_count: null,
    warnings,
  };

  const ref = projectRef();
  if (!managementToken || !ref) {
    warnings.push(
      managementToken ? "project_ref_unavailable" : "supabase_access_token_missing",
    );
    return jsonResponse(payload);
  }
  payload.configured = true;

  const startStr = clickhouseTime(start);
  const failureFilter =
    `where source = 'auth_logs'\n` +
    `  and timestamp >= '${startStr}'\n` +
    `  and (severity_text = 'ERROR' or toInt32OrZero(log_attributes['status']) >= 500)`;

  const signins = await runLogsQuery(
    `select count() as n, max(timestamp) as last_at\n` +
      `from logs\n` +
      `where source = 'auth_logs'\n` +
      `  and timestamp >= '${startStr}'\n` +
      `  and log_attributes['auth_event.action'] = 'login'\n` +
      `  and severity_text != 'ERROR'`,
    ["n", "last_at"],
    start,
    now,
  );
  if (signins.error) warnings.push(`signins_query_failed: ${signins.error}`);
  const signinRow = signins.rows[0];
  if (signinRow) {
    payload.signins_15m = numOrNull(signinRow.n) ?? 0;
    payload.signins_last_at = isoOrNull(signinRow.last_at);
  } else if (!signins.error) {
    warnings.push("signins_query_returned_no_row");
  }

  const failures = await runLogsQuery(
    `select count() as n, max(timestamp) as last_at\nfrom logs\n${failureFilter}`,
    ["n", "last_at"],
    start,
    now,
  );
  if (failures.error) warnings.push(`auth_error_query_failed: ${failures.error}`);
  const failureRow = failures.rows[0];
  let errorCount = 0;
  if (failureRow) {
    errorCount = numOrNull(failureRow.n) ?? 0;
    payload.auth_errors_15m = errorCount;
    payload.auth_last_error_at = isoOrNull(failureRow.last_at);
  } else if (!failures.error) {
    warnings.push("auth_error_query_returned_no_row");
  }

  if (errorCount > 0) {
    const detail = await runLogsQuery(
      `select timestamp as at, event_message, ` +
        `log_attributes['auth_event.action'] as action, ` +
        `log_attributes['status'] as status\n` +
        `from logs\n${failureFilter}\n` +
        `order by timestamp desc\nlimit 1`,
      ["at", "event_message", "action", "status"],
      start,
      now,
    );
    if (detail.error) warnings.push(`auth_error_detail_query_failed: ${detail.error}`);
    const detailRow = detail.rows[0];
    if (detailRow) {
      payload.auth_last_error_at =
        isoOrNull(detailRow.at) ?? (payload.auth_last_error_at as string | null);
      payload.auth_last_error_message = truncateMessage(detailRow.event_message);
      payload.auth_last_error_action =
        typeof detailRow.action === "string" && detailRow.action.trim()
          ? detailRow.action.trim()
          : null;
    }
  }

  const mgmtHeaders = {
    Authorization: `Bearer ${managementToken}`,
    Accept: "application/json",
  };

  try {
    const diskRes = await fetch(
      `https://api.supabase.com/v1/projects/${ref}/config/disk/util`,
      {
        headers: mgmtHeaders,
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      },
    );
    const diskBody = (await diskRes.json().catch(() => null)) as Record<
      string,
      unknown
    > | null;
    if (diskRes.ok && diskBody && typeof diskBody === "object") {
      const metrics = (diskBody.metrics ?? {}) as Record<string, unknown>;
      payload.disk_used_bytes = numOrNull(metrics.fs_used_bytes);
      payload.disk_size_bytes = numOrNull(metrics.fs_size_bytes);
      payload.disk_avail_bytes = numOrNull(metrics.fs_avail_bytes);
      if (
        payload.disk_used_bytes == null &&
        payload.disk_size_bytes == null
      ) {
        warnings.push("disk_util_unexpected_shape");
      }
    } else {
      warnings.push(`disk_util_http_${diskRes.status}`);
    }
  } catch (e) {
    warnings.push(
      `disk_util_failed: ${e instanceof Error ? e.message : String(e)}`,
    );
  }

  try {
    const apiRes = await fetch(
      `https://api.supabase.com/v1/projects/${ref}/analytics/endpoints/usage.api-requests-count`,
      {
        headers: mgmtHeaders,
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      },
    );
    const apiBody = (await apiRes.json().catch(() => null)) as Record<
      string,
      unknown
    > | null;
    if (apiRes.ok && apiBody && typeof apiBody === "object") {
      const rows = apiBody.result;
      const first = Array.isArray(rows)
        ? (rows[0] as Record<string, unknown> | null)
        : null;
      payload.api_requests_count = first ? numOrNull(first.count) : null;
      if (payload.api_requests_count == null) {
        warnings.push("api_requests_unexpected_shape");
      }
    } else {
      warnings.push(`api_requests_http_${apiRes.status}`);
    }
  } catch (e) {
    warnings.push(
      `api_requests_failed: ${e instanceof Error ? e.message : String(e)}`,
    );
  }

  return jsonResponse(payload);
}));
