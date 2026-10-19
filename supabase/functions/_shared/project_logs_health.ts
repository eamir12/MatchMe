// Shared core for project-level health data sourced from the Supabase
// Management API: ClickHouse auth logs (sign-ins, auth errors), disk
// utilization, and API request counts.
//
// Used by two callers:
//  - the `project-logs-health` edge function (admin app live probes; passes
//    detail=true to also fetch the latest auth-error message; usually served
//    from 30-minute snapshots instead of calling the Management API), and
//  - the `health_sampler` task inside `cron-jobs` (30-minute snapshots for
//    the System Health History screen; detail=false to save one API call).
//
// Requires the MANAGEMENT_API_TOKEN secret. Never throws: failures are
// reported as `warnings[]` entries with null metric fields.

export const AUTH_WINDOW_MS = 15 * 60 * 1000;
export const FETCH_TIMEOUT_MS = 10_000;

export interface ProjectLogsHealthPayload {
  configured: boolean;
  checked_at: string;
  signins_15m: number | null;
  signins_last_at: string | null;
  auth_errors_15m: number | null;
  auth_last_error_at: string | null;
  auth_last_error_message: string | null;
  auth_last_error_action: string | null;
  disk_used_bytes: number | null;
  disk_size_bytes: number | null;
  disk_avail_bytes: number | null;
  api_requests_count: number | null;
  warnings: string[];
}

export interface ProjectLogsHealthOptions {
  supabaseUrl: string;
  managementToken: string;
  /** Fetch the latest auth-error detail row when errors exist (default true). */
  detail?: boolean;
}

export function projectRefFromUrl(supabaseUrl: string): string | null {
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
    // ClickHouse max(timestamp) over an empty set returns epoch 0 — that
    // means "no rows", never a real 1970 event.
    if (ms <= 0) return null;
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
  if (Number.isNaN(parsed.getTime()) || parsed.getTime() === 0) return null;
  return parsed.toISOString();
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
  supabaseUrl: string,
  managementToken: string,
): Promise<LogsQueryOutcome> {
  const ref = projectRefFromUrl(supabaseUrl);
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

/** Collect the project's sign-ins, auth failures, disk, and API usage.
 * Never throws; per-source failures land in `warnings[]`. */
export async function collectProjectLogsHealth(
  opts: ProjectLogsHealthOptions,
): Promise<ProjectLogsHealthPayload> {
  const { supabaseUrl, managementToken } = opts;
  const wantDetail = opts.detail !== false;
  const now = new Date();
  const start = new Date(now.getTime() - AUTH_WINDOW_MS);
  const warnings: string[] = [];
  const payload: ProjectLogsHealthPayload = {
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

  const ref = projectRefFromUrl(supabaseUrl);
  if (!managementToken || !ref) {
    warnings.push(
      managementToken ? "project_ref_unavailable" : "management_api_token_missing",
    );
    return payload;
  }
  payload.configured = true;

  const startStr = clickhouseTime(start);
  const failurePredicate =
    `severity_text = 'ERROR' or toInt32OrZero(log_attributes['status']) >= 500`;
  const failureFilter =
    `where source = 'auth_logs'\n` +
    `  and timestamp >= '${startStr}'\n` +
    `  and (${failurePredicate})`;

  // ONE combined query for sign-ins + errors. Each ClickHouse call scans the
  // whole requested window, and this module is invoked by the admin live
  // probe AND the sampler, so the former two queries doubled the project's
  // log-query byte usage for every probe. countIf/maxIf give both metrics
  // from a single scan.
  const loginPredicate =
    `log_attributes['auth_event.action'] = 'login' and severity_text != 'ERROR'`;
  const combined = await runLogsQuery(
    `select ` +
      `countIf(${loginPredicate}) as signins_n, ` +
      `maxIf(timestamp, ${loginPredicate}) as signins_last_at, ` +
      `countIf(${failurePredicate}) as errors_n, ` +
      `maxIf(timestamp, ${failurePredicate}) as errors_last_at\n` +
      `from logs\n` +
      `where source = 'auth_logs'\n` +
      `  and timestamp >= '${startStr}'`,
    ["signins_n", "signins_last_at", "errors_n", "errors_last_at"],
    start,
    now,
    supabaseUrl,
    managementToken,
  );
  if (combined.error) warnings.push(`auth_logs_query_failed: ${combined.error}`);
  const combinedRow = combined.rows[0];
  let errorCount = 0;
  if (combinedRow) {
    payload.signins_15m = numOrNull(combinedRow.signins_n) ?? 0;
    payload.signins_last_at = isoOrNull(combinedRow.signins_last_at);
    errorCount = numOrNull(combinedRow.errors_n) ?? 0;
    payload.auth_errors_15m = errorCount;
    payload.auth_last_error_at = isoOrNull(combinedRow.errors_last_at);
  } else if (!combined.error) {
    warnings.push("auth_logs_query_returned_no_row");
  }

  if (wantDetail && errorCount > 0) {
    const detail = await runLogsQuery(
      `select timestamp as at, event_message, ` +
        `log_attributes['auth_event.action'] as action, ` +
        `log_attributes['status'] as status\n` +
        `from logs\n${failureFilter}\n` +
        `order by timestamp desc\nlimit 1`,
      ["at", "event_message", "action", "status"],
      start,
      now,
      supabaseUrl,
      managementToken,
    );
    if (detail.error) warnings.push(`auth_error_detail_query_failed: ${detail.error}`);
    const detailRow = detail.rows[0];
    if (detailRow) {
      payload.auth_last_error_at =
        isoOrNull(detailRow.at) ?? payload.auth_last_error_at;
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

  return payload;
}
