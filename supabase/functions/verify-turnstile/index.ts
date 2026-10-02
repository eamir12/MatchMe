import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const requestId = crypto.randomUUID();
  const startedAt = Date.now();
  const functionName = "verify-turnstile";

  const jsonResponse = async (
    payload: Record<string, unknown>,
    status = 200,
    opts?: {
      success?: boolean;
      errorType?: string | null;
      errorMessage?: string | null;
      meta?: Record<string, unknown>;
    },
  ) => {
    await logEdgeFunctionInvocation({
      requestId,
      functionName,
      durationMs: Date.now() - startedAt,
      success: opts?.success ?? (status < 400),
      httpStatus: status,
      errorType: opts?.errorType ?? null,
      errorMessage: opts?.errorMessage ?? null,
      aiUsed: false,
      meta: opts?.meta ?? {},
    });

    return new Response(JSON.stringify(payload), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  };

  try {
    if (req.method !== "POST") {
      return await jsonResponse(
        { success: false, message: "Method not allowed." },
        405,
        { success: false, errorType: "method_not_allowed" },
      );
    }

    const secret = (Deno.env.get("TURNSTILE_SECRET_KEY") ?? "").trim();
    if (!secret) {
      return await jsonResponse(
        {
          success: false,
          message: "TURNSTILE_SECRET_KEY is not configured.",
        },
        500,
        {
          success: false,
          errorType: "config_missing",
          errorMessage: "Missing TURNSTILE_SECRET_KEY",
        },
      );
    }

    const body = await req.json() as { token?: string; action?: string };
    const token = (body.token ?? "").trim();
    const expectedAction = (body.action ?? "").trim();

    if (!token) {
      return await jsonResponse(
        { success: false, message: "Captcha token is required." },
        400,
        {
          success: false,
          errorType: "bad_request",
          errorMessage: "Missing captcha token",
        },
      );
    }

    const form = new URLSearchParams();
    form.set("secret", secret);
    form.set("response", token);
    form.set("idempotency_key", requestId);

    const remoteIp =
      req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "";
    if (remoteIp) {
      form.set("remoteip", remoteIp);
    }

    const verifyResp = await fetch(
      "https://challenges.cloudflare.com/turnstile/v0/siteverify",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: form.toString(),
      },
    );

    const decoded = await verifyResp.json() as Record<string, unknown>;
    const verified = decoded.success === true;
    const responseAction =
      typeof decoded.action === "string" ? decoded.action.trim() : "";
    const hostname =
      typeof decoded.hostname === "string" ? decoded.hostname.trim() : "";
    const errorCodes = Array.isArray(decoded["error-codes"])
      ? decoded["error-codes"].map((code) => String(code))
      : [];

    if (!verified) {
      return await jsonResponse(
        {
          success: false,
          message: "Security check failed. Please try again.",
          errorCodes,
        },
        422,
        {
          success: false,
          errorType: "turnstile_verification_failed",
          errorMessage: errorCodes.join(", "),
          meta: {
            expectedAction,
            responseAction,
            hostname,
          },
        },
      );
    }

    if (expectedAction.length > 0 &&
        responseAction.length > 0 &&
        responseAction !== expectedAction) {
      return await jsonResponse(
        {
          success: false,
          message: "Security check action mismatch.",
          expectedAction,
          responseAction,
        },
        422,
        {
          success: false,
          errorType: "turnstile_action_mismatch",
          errorMessage:
            `expected=${expectedAction} actual=${responseAction}`,
          meta: {
            expectedAction,
            responseAction,
            hostname,
          },
        },
      );
    }

    return await jsonResponse(
      {
        success: true,
        action: responseAction,
        hostname,
      },
      200,
      {
        success: true,
        meta: {
          expectedAction,
          responseAction,
          hostname,
        },
      },
    );
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return await jsonResponse(
      {
        success: false,
        message: "Unable to verify security check right now.",
      },
      500,
      {
        success: false,
        errorType: "exception",
        errorMessage: message,
      },
    );
  }
});
