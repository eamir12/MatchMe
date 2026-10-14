import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

export type EdgeFunctionInvocationLog = {
  requestId: string;
  functionName: string;
  durationMs?: number;
  success: boolean;
  httpStatus?: number;
  errorType?: string | null;
  errorMessage?: string | null;
  userId?: string | null;
  aiUsed?: boolean;
  aiProvider?: string | null;
  aiModel?: string | null;
  aiTask?: string | null;
  meta?: Record<string, unknown>;
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const client =
  SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY
    ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    : null;

export function truncateText(input: unknown, max = 2000): string | null {
  if (input == null) return null;
  const s = typeof input === "string" ? input : String(input);
  if (s.length <= max) return s;
  return `${s.slice(0, max)}…(truncated)`;
}

export async function logEdgeFunctionInvocation(
  entry: EdgeFunctionInvocationLog,
): Promise<void> {
  if (!client) return;
  try {
    const res = await client.rpc("log_edge_function_invocation", {
      p_request_id: entry.requestId,
      p_function_name: entry.functionName,
      p_duration_ms: entry.durationMs ?? null,
      p_success: entry.success,
      p_http_status: entry.httpStatus ?? null,
      p_error_type: entry.errorType ?? null,
      p_error_message: truncateText(entry.errorMessage ?? null, 4000),
      p_user_id: entry.userId ?? null,
      p_ai_used: entry.aiUsed ?? false,
      p_ai_provider: entry.aiProvider ?? null,
      p_ai_model: entry.aiModel ?? null,
      p_ai_task: entry.aiTask ?? null,
      p_meta: entry.meta ?? {},
    });
    if (res.error) {
      throw new Error(res.error.message);
    }
  } catch (e) {
    console.error(
      `[edge_function_logger] Failed to write log function=${entry.functionName} requestId=${entry.requestId} err=${truncateText(e instanceof Error ? e.message : String(e))}`,
    );
  }
}

// Wraps a handler so every invocation is recorded in
/// `edge_function_invocations` without touching the handler's body.
// - CORS preflights (OPTIONS) are passed through unlogged.
// - `success = status < 500`: expected client rejections (wrong OTP,
//   invalid input → 4xx) are NOT project failures; only 5xx and
//   unhandled exceptions count (the System Health "Project errors"
//   card thresholds over these).
export function withInvocationLogging(
  functionName: string,
  handler: (req: Request) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return handler(req);
    const requestId = crypto.randomUUID();
    const startedAt = Date.now();
    let response: Response;
    try {
      response = await handler(req);
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      await logEdgeFunctionInvocation({
        requestId,
        functionName,
        durationMs: Date.now() - startedAt,
        success: false,
        httpStatus: 500,
        errorType: e instanceof Error ? e.name : "Error",
        errorMessage: message,
        meta: { method: req.method },
      });
      return new Response(
        JSON.stringify({ error: "unhandled_exception", message }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
    await logEdgeFunctionInvocation({
      requestId,
      functionName,
      durationMs: Date.now() - startedAt,
      success: response.status < 500,
      httpStatus: response.status,
      errorType: response.status < 500 ? null : "HttpError",
      errorMessage: response.status < 500 ? null : `HTTP ${response.status}`,
      meta: { method: req.method },
    });
    return response;
  };
}
