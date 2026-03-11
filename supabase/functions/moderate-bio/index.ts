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
  const functionName = "moderate-bio";

  try {
    let aiUsed = false;
    let aiModel: string | null = null;

    const jsonResponse = async (
      payload: Record<string, unknown>,
      opts?: { success?: boolean; errorType?: string | null; errorMessage?: string | null },
    ) => {
      const success = opts?.success ?? true;
      await logEdgeFunctionInvocation({
        requestId,
        functionName,
        durationMs: Date.now() - startedAt,
        success,
        httpStatus: 200,
        errorType: opts?.errorType ?? null,
        errorMessage: opts?.errorMessage ?? null,
        aiUsed,
        aiProvider: aiUsed ? "google_gemini" : null,
        aiModel,
        aiTask: "bio_moderation",
      });

      return new Response(JSON.stringify(payload), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    };

    const truncate = (s: string, max = 4000) => (s.length <= max ? s : `${s.slice(0, max)}…(truncated)`);
    const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
    const isRetryableStatus = (status: number) => status === 408 || status === 429 || (status >= 500 && status <= 599);
    const backoffMsForAttempt = (attemptIndex: number) => {
      const base = 300 * (2 ** attemptIndex);
      const jitter = Math.floor(Math.random() * 200);
      return Math.min(2000, base + jitter);
    };

    const API_KEY = Deno.env.get("GOOGLE_AI_API_KEY");
    if (!API_KEY) {
      console.error(`[moderate-bio:${requestId}] Missing GOOGLE_AI_API_KEY`);
      return await jsonResponse(
        {
          allow: false,
          message: "Bio moderation is unavailable right now.",
        },
        { success: false, errorType: "config_missing", errorMessage: "Missing GOOGLE_AI_API_KEY" },
      );
    }

    const body = (await req.json()) as { bio?: string };
    const bio = (body.bio ?? "").toString().trim();

    if (!bio) {
      console.log(`[moderate-bio:${requestId}] Empty bio, auto-allow`);
      return await jsonResponse({ allow: true, message: "OK" });
    }

    const bioForLog = bio.replace(/\s+/g, " ").trim();
    console.log(`[moderate-bio:${requestId}] Moderating bio (length=${bio.length})`);
    console.log(`[moderate-bio:${requestId}] Bio: ${truncate(bioForLog, 500)}`);

    const prompt = `
You are a strict content moderator for a dating app user bio field.
Decide if the bio is allowed.

Disallow if it contains: hate/harassment, sexual content, minors, violence/threats, self-harm, illegal drugs, scams, solicitation, advertising, spam, or any contact info (phone, email, URLs, social handles).

Return ONLY valid JSON with this schema:
{"allow": boolean, "message": string}

"Do not include any other text (no preamble like 'Here is the JSON requested')."

"message" must be a short, user-friendly explanation (no quotes from the bio).

Bio:
${JSON.stringify(bio)}
`;

    const geminiUrlPrimary = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=${API_KEY}`;
    const geminiUrlBackup = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${API_KEY}`;

    const requestBody = JSON.stringify({
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: {
        responseMimeType: "application/json",
        temperature: 0,
        maxOutputTokens: 512,
      },
    });

    const maxAttempts = 3;
    let decoded: any | null = null;
    let lastErrText: string | null = null;
    let lastStatus: number | null = null;
    let lastErrorType: "http" | "network" | "timeout" | null = null;

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 9000);
      const currentGeminiUrl = attempt === 0 ? geminiUrlPrimary : geminiUrlBackup;
      aiUsed = true;
      aiModel = attempt === 0 ? "gemini-3-flash-preview" : "gemini-2.5-flash";
      try {
        console.log(`[moderate-bio:${requestId}] Sending request to ${attempt === 0 ? 'Primary' : 'Backup'}`);
        const resp = await fetch(currentGeminiUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: requestBody,
          signal: controller.signal,
        });

        if (resp.ok) {
          decoded = await resp.json();
          lastErrText = null;
          lastStatus = resp.status;
          lastErrorType = null;
          break;
        }

        lastStatus = resp.status;
        lastErrorType = "http";
        lastErrText = await resp.text();
        console.error(
          `[moderate-bio:${requestId}] Gemini HTTP ${resp.status} (attempt ${attempt + 1}/${maxAttempts}): ${truncate(lastErrText)}`,
        );

        if (!isRetryableStatus(resp.status) || attempt === maxAttempts - 1) {
          break;
        }
      } catch (e) {
        const isTimeout = e instanceof DOMException && e.name === "AbortError";
        lastErrorType = isTimeout ? "timeout" : "network";
        lastErrText = e instanceof Error ? e.message : String(e);
        console.error(
          `[moderate-bio:${requestId}] Gemini ${lastErrorType} error (attempt ${attempt + 1}/${maxAttempts}): ${truncate(lastErrText)}`,
        );
        if (attempt === maxAttempts - 1) {
          break;
        }
      } finally {
        clearTimeout(timeoutId);
      }

      await sleep(backoffMsForAttempt(attempt));
    }

    if (!decoded) {
      const retryable = lastStatus != null ? isRetryableStatus(lastStatus) : lastErrorType === "timeout" || lastErrorType === "network";
      if (retryable) {
        console.error(
          `[moderate-bio:${requestId}] Gemini unavailable, allowing bio after retries (status=${lastStatus ?? "n/a"} type=${lastErrorType ?? "n/a"})`,
        );
        return await jsonResponse(
          {
            allow: true,
            message: "OK",
            geminiUnavailable: true,
            geminiStatus: lastStatus,
          },
          { success: false, errorType: lastErrorType, errorMessage: lastErrText },
        );
      }

      return await jsonResponse(
        {
          allow: false,
          message: "Unable to verify your bio right now. Please try again.",
          geminiStatus: lastStatus,
        },
        { success: false, errorType: lastErrorType, errorMessage: lastErrText },
      );
    }

    console.log(`[moderate-bio:${requestId}] Gemini response: ${truncate(JSON.stringify(decoded))}`);
    const text = decoded?.candidates?.[0]?.content?.parts?.[0]?.text?.trim?.();
    if (!text) {
      console.error(`[moderate-bio:${requestId}] Gemini response missing candidates text`);
      return await jsonResponse(
        {
          allow: false,
          message: "Unable to verify your bio right now. Please try again.",
        },
        { success: false, errorType: "ai_response_invalid", errorMessage: "Missing candidates text" },
      );
    }

    const cleaned = text
      .replace(/^```(?:json)?\s*/i, "")
      .replace(/\s*```$/, "")
      .trim();

    console.log(`[moderate-bio:${requestId}] Gemini text: ${truncate(cleaned)}`);

    let parsed: unknown;
    try {
      parsed = JSON.parse(cleaned);
    } catch (_) {
      const jsonMatch = cleaned.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        try {
          parsed = JSON.parse(jsonMatch[0]);
        } catch (_) {
          parsed = null;
        }
      } else {
        parsed = null;
      }
    }

    const toBool = (v: unknown): boolean | null => {
      if (v === true) return true;
      if (v === false) return false;
      if (typeof v === "number") return v > 0;
      if (typeof v === "string") {
        const s = v.trim().toLowerCase();
        if (["true", "yes", "y", "allow", "allowed", "approve", "approved", "ok"].includes(s)) return true;
        if (["false", "no", "n", "deny", "denied", "reject", "rejected", "not_allowed", "not allowed"].includes(s)) return false;
      }
      return null;
    };

    const obj = parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : null;
    const allowValue =
      obj?.allow ??
      obj?.allowed ??
      obj?.approved ??
      obj?.ok ??
      obj?.isAllowed ??
      obj?.is_allowed ??
      null;
    const allow = toBool(allowValue) ?? false;
    const messageValue = obj ? obj.message : null;
    const message =
      typeof messageValue === "string" && messageValue.trim().length > 0
        ? messageValue.trim()
        : allow
        ? "OK"
        : "Your bio was not approved.";

    console.log(`[moderate-bio:${requestId}] Decision allow=${allow} message=${truncate(message, 500)}`);

    return await jsonResponse({ allow, message });
  } catch (e) {
    console.error(`[moderate-bio:${requestId}] Unhandled error: ${e instanceof Error ? e.message : String(e)}`);
    await logEdgeFunctionInvocation({
      requestId,
      functionName,
      durationMs: Date.now() - startedAt,
      success: false,
      httpStatus: 500,
      errorType: "exception",
      errorMessage: e instanceof Error ? e.message : String(e),
      aiUsed: false,
      aiProvider: null,
      aiModel: null,
      aiTask: "bio_moderation",
    });
    return new Response(
      JSON.stringify({
        allow: false,
        message: "Unable to verify your bio right now. Please try again.",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 500 },
    );
  }
});
