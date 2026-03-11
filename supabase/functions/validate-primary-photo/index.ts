import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  const binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  return btoa(binary);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const requestId = crypto.randomUUID();
  const startedAt = Date.now();
  const functionName = "validate-primary-photo";
  let aiUsed = false;
  let aiModel: string | null = null;
  const aiProvider = "google_gemini";
  const aiTask = "primary_photo_validation";

  const jsonResponse = async (
    payload: Record<string, unknown>,
    status = 200,
    opts?: {
      success?: boolean;
      errorType?: string | null;
      errorMessage?: string | null;
      userId?: string | null;
      meta?: Record<string, unknown>;
    },
  ) => {
    await logEdgeFunctionInvocation({
      requestId,
      functionName,
      durationMs: Date.now() - startedAt,
      success: opts?.success ?? (status < 500),
      httpStatus: status,
      errorType: opts?.errorType ?? null,
      errorMessage: opts?.errorMessage ?? null,
      userId: opts?.userId ?? null,
      aiUsed,
      aiProvider: aiUsed ? aiProvider : null,
      aiModel,
      aiTask,
      meta: opts?.meta ?? {},
    });

    return new Response(JSON.stringify(payload), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  };

  const clamp01 = (n: number) => Math.max(0, Math.min(1, n));
  const toNumber = (v: unknown) =>
    typeof v === "number"
      ? v
      : typeof v === "string" && v.trim().length > 0 && Number.isFinite(Number(v))
      ? Number(v)
      : null;
  const normalizeBox = (value: unknown) => {
    const obj = value && typeof value === "object"
      ? (value as Record<string, unknown>)
      : null;
    if (!obj) return null;
    const x = toNumber(obj.x);
    const y = toNumber(obj.y);
    const w = toNumber(obj.w);
    const h = toNumber(obj.h);
    if (x == null || y == null || w == null || h == null) return null;
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(w) ||
      !Number.isFinite(h)) return null;
    if (w <= 0 || h <= 0) return null;
    return {
      x: clamp01(x),
      y: clamp01(y),
      w: clamp01(w),
      h: clamp01(h),
    };
  };
  const normalizeBoxes = (value: unknown) => {
    if (!Array.isArray(value)) return [];
    const out: Array<{ x: number; y: number; w: number; h: number }> = [];
    for (const item of value) {
      const b = normalizeBox(item);
      if (b) out.push(b);
    }
    return out;
  };

  const truncate = (s: string, max = 4000) =>
    s.length <= max ? s : `${s.slice(0, max)}…(truncated)`;
  const safeStringify = (value: unknown) => {
    try {
      return JSON.stringify(value);
    } catch (e) {
      return JSON.stringify({
        error: "stringify_failed",
        message: e instanceof Error ? e.message : String(e),
      });
    }
  };
  const summarizeGeminiDecoded = (decoded: any) => {
    const candidates = decoded?.candidates;
    const candidate0 = Array.isArray(candidates) ? candidates[0] : undefined;
    const parts = candidate0?.content?.parts;
    const part0 = Array.isArray(parts) ? parts[0] : undefined;
    return {
      topLevelKeys: decoded && typeof decoded === "object" ? Object.keys(decoded) : [],
      hasCandidates: Array.isArray(candidates),
      candidatesLength: Array.isArray(candidates) ? candidates.length : 0,
      candidate0Keys: candidate0 && typeof candidate0 === "object" ? Object.keys(candidate0) : [],
      candidate0FinishReason: candidate0?.finishReason,
      candidate0PartsLength: Array.isArray(parts) ? parts.length : 0,
      candidate0Part0Keys: part0 && typeof part0 === "object" ? Object.keys(part0) : [],
      hasText: typeof part0?.text === "string" && part0.text.trim().length > 0,
      promptFeedback: decoded?.promptFeedback,
    };
  };
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
  const isRetryableStatus = (status: number) =>
    status === 408 || status === 429 || (status >= 500 && status <= 599);
  const backoffMsForAttempt = (attemptIndex: number) => {
    const base = 300 * (2 ** attemptIndex);
    const jitter = Math.floor(Math.random() * 200);
    return Math.min(2500, base + jitter);
  };

  try {
    console.log(
      `[validate-primary-photo:${requestId}] Request start method=${req.method} url=${req.url} content-type=${req.headers.get("content-type") ?? "n/a"}`,
    );
    const API_KEY = Deno.env.get("GOOGLE_AI_API_KEY");
    if (!API_KEY) {
      console.error(`[validate-primary-photo:${requestId}] Missing GOOGLE_AI_API_KEY`);
      return await jsonResponse(
        {
          allow: false,
          message: "Unable to verify your photo right now. Please try again.",
        },
        500,
        { success: false, errorType: "config_missing", errorMessage: "Missing GOOGLE_AI_API_KEY" },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const body = (await req.json()) as { photoPath?: string };
    const photoPath = (body.photoPath ?? "").toString().trim();
    const ownerId = photoPath.split("/")[0] ?? "";

    if (!photoPath) {
      return await jsonResponse(
        {
          allow: false,
          message: "photoPath is required",
        },
        400,
        { success: false, errorType: "bad_request", errorMessage: "photoPath is required" },
      );
    }

    console.log(
      `[validate-primary-photo:${requestId}] Downloading profile photo from storage path=${photoPath}`,
    );
    const photoResp = await supabase.storage.from("profile-photos").download(
      photoPath,
    );
    if (photoResp.error || !photoResp.data) {
      console.error(
        `[validate-primary-photo:${requestId}] Failed to download photo: ${truncate(JSON.stringify(photoResp.error ?? "unknown"))}`,
      );
      return await jsonResponse(
        {
          allow: false,
          message: "Unable to verify your photo right now. Please try again.",
        },
        500,
        {
          success: false,
          errorType: "storage_download_failed",
          errorMessage: truncate(safeStringify(photoResp.error ?? "unknown")),
          userId: ownerId,
        },
      );
    }

    const photoBuffer = await photoResp.data.arrayBuffer();
    console.log(
      `[validate-primary-photo:${requestId}] Photo downloaded byteLength=${photoBuffer.byteLength}`,
    );
    const photoBase64 = arrayBufferToBase64(photoBuffer);

    const prompt = `
You are a strict dating-app profile photo reviewer.
Your job: decide whether this image is acceptable as the user's PRIMARY profile photo.

Accept ONLY if the photo is:
- a clear face shot of a SINGLE person (the user).

Reject if:
- it is a body shot (full body or upper body without clear focus on face), OR
- there are multiple people in the photo, OR
- no person is visible, OR
- the face is not clearly visible, OR
- the image is a meme, screenshot, collage, text-only, cartoon, AI art, or heavily filtered, OR
- the image is explicit/sexual, shows nudity, or suggests minors.

Additionally, if the photo contains any visible text (including phone numbers, @handles, websites, QR codes, or any other text), it must NOT be accepted as-is.
Instead, request sanitization so the app can crop tightly to the face and pixelate any remaining text.

Return ONLY valid JSON matching this schema:
{
  "action": "ALLOW" | "REJECT" | "SANITIZE",
  "allow": boolean,
  "shotType": "face" | "body" | "multiple_people" | "neither",
  "reasonCode": "NO_PERSON" | "FACE_NOT_VISIBLE" | "BAD_CONTENT" | "MULTIPLE_PEOPLE" | "BODY_SHOT" | "OK",
  "confidence": number,
  "message": string,
  "faceBox": {"x": number, "y": number, "w": number, "h": number} | null,
  "textBoxes": Array<{"x": number, "y": number, "w": number, "h": number}>,
  "sexualContent": "none" | "suggestive" | "explicit"
}

Rules:
- If allow is true, shotType must be "face"
- confidence must be a number from 0 to 1
- message must be short and user-friendly (no explicit content descriptions)
- reasonCode must be one of the specified values. If allow is true, reasonCode must be "OK".
- If the image contains ANY visible text, set action to "SANITIZE" (not "ALLOW"), allow must be false, shotType must still reflect what you see.
- If action is "SANITIZE", you MUST provide faceBox (normalized to 0..1 relative to full image) and any detected textBoxes (also normalized).
- sexualContent must be "none" for acceptable images. If sexualContent is "suggestive" or "explicit", action MUST be "REJECT" and reasonCode MUST be "BAD_CONTENT".
- If there is not exactly one clear face, set action to "REJECT" and choose the best reasonCode.
- For faceBox and textBoxes: x,y,w,h are normalized floats 0..1, with x,y the top-left corner.
`;


    const geminiUrlPrimary = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=${API_KEY}`;
    const geminiUrlBackup = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${API_KEY}`;

    const requestBody = JSON.stringify({
      contents: [{
        parts: [
          { text: prompt },
          {
            inline_data: {
              mime_type: "image/jpeg",
              data: photoBase64,
            },
          },
        ],
      }],
      generationConfig: {
        responseMimeType: "application/json",
        temperature: 0,
      },
    });

    console.log(
      `[validate-primary-photo:${requestId}] Gemini request model=gemini-3-flash-preview promptChars=${prompt.length} requestBytes=${requestBody.length}`,
    );
    const maxAttempts = 3;
    let decoded: any | null = null;
    let lastErrText: string | null = null;
    let lastStatus: number | null = null;
    let lastErrorType: "http" | "network" | "timeout" | null = null;

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 12000);
      const currentGeminiUrl = attempt === 0 ? geminiUrlPrimary : geminiUrlBackup;
      aiUsed = true;
      aiModel = attempt === 0 ? "gemini-3-flash-preview" : "gemini-2.5-flash";
      try {
        console.log(
          `[validate-primary-photo:${requestId}] Gemini attempt ${attempt + 1}/${maxAttempts} sending request to ${attempt === 0 ? 'Primary' : 'Backup'}`,
        );
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
          console.log(
            `[validate-primary-photo:${requestId}] Gemini OK status=${resp.status} content-type=${resp.headers.get("content-type") ?? "n/a"} summary=${truncate(safeStringify(summarizeGeminiDecoded(decoded)))}`,
          );
          break;
        }

        lastStatus = resp.status;
        lastErrorType = "http";
        lastErrText = await resp.text();
        console.error(
          `[validate-primary-photo:${requestId}] Gemini HTTP ${resp.status} (attempt ${attempt + 1}/${maxAttempts}): ${truncate(lastErrText)}`,
        );

        if (!isRetryableStatus(resp.status) || attempt === maxAttempts - 1) {
          break;
        }
      } catch (e) {
        const isTimeout = e instanceof DOMException && e.name === "AbortError";
        lastErrorType = isTimeout ? "timeout" : "network";
        lastErrText = e instanceof Error ? e.message : String(e);
        console.error(
          `[validate-primary-photo:${requestId}] Gemini ${lastErrorType} error (attempt ${attempt + 1}/${maxAttempts}): ${truncate(lastErrText)}`,
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
      console.error(
        `[validate-primary-photo:${requestId}] Gemini unavailable (status=${lastStatus ?? "n/a"} type=${lastErrorType ?? "n/a"})`,
      );
      return await jsonResponse(
        {
          allow: false,
          message: "Unable to verify your photo right now. Please try again.",
          geminiStatus: lastStatus,
        },
        503,
        {
          success: false,
          errorType: lastErrorType ?? "unknown",
          errorMessage: truncate(lastErrText ?? "Gemini unavailable"),
          userId: ownerId,
          meta: { geminiStatus: lastStatus },
        },
      );
    }

    const text = decoded?.candidates?.[0]?.content?.parts?.[0]?.text?.trim?.();
    if (!text) {
      console.error(
        `[validate-primary-photo:${requestId}] Gemini response missing candidates text summary=${truncate(safeStringify(summarizeGeminiDecoded(decoded)))}`,
      );
      console.error(
        `[validate-primary-photo:${requestId}] Gemini raw decoded=${truncate(safeStringify(decoded))}`,
      );
      return await jsonResponse(
        {
          allow: false,
          message: "Unable to verify your photo right now. Please try again.",
        },
        500,
        {
          success: false,
          errorType: "ai_response_invalid",
          errorMessage: truncate(safeStringify(summarizeGeminiDecoded(decoded))),
          userId: ownerId,
        },
      );
    }

    console.log(
      `[validate-primary-photo:${requestId}] Gemini candidates[0].text length=${text.length} preview=${truncate(text, 800)}`,
    );
    const cleaned = text
      .replace(/^```(?:json)?\s*/i, "")
      .replace(/\s*```$/, "")
      .trim();

    let parsed: unknown = null;
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
      }
    }

    const obj = parsed && typeof parsed === "object"
      ? (parsed as Record<string, unknown>)
      : null;

    const allow = obj?.allow === true;
    const actionRaw = typeof obj?.action === "string" ? obj.action : null;
    const shotType = typeof obj?.shotType === "string" ? obj.shotType : "neither";
    const confidence = typeof obj?.confidence === "number" ? obj.confidence : 0;
    const reasonCode = typeof obj?.reasonCode === "string"
      ? obj.reasonCode
      : (allow ? "OK" : "GENERAL_ERROR");
    const message =
      typeof obj?.message === "string" && obj.message.trim().length > 0
        ? obj.message.trim()
        : allow
        ? "OK"
        : "Please use a clear face photo.";

    const sexualContent = typeof obj?.sexualContent === "string"
      ? obj.sexualContent
      : "none";
    const faceBox = normalizeBox(obj?.faceBox);
    const textBoxes = normalizeBoxes(obj?.textBoxes);

    const normalizedShotType = ["face", "body", "multiple_people", "neither"].includes(shotType)
      ? shotType
      : "neither";
    const normalizedConfidence = Number.isFinite(confidence)
      ? Math.max(0, Math.min(1, confidence))
      : 0;

    const hasSexual = sexualContent === "suggestive" || sexualContent === "explicit";
    const effectiveAllow = allow && (normalizedShotType === "face") && !hasSexual;
    const normalizedAction = actionRaw === "ALLOW" || actionRaw === "REJECT" || actionRaw === "SANITIZE"
      ? actionRaw
      : effectiveAllow
      ? "ALLOW"
      : "REJECT";
    const effectiveAction = hasSexual ? "REJECT" : normalizedAction;

    console.log(
      `[validate-primary-photo:${requestId}] Decision action=${effectiveAction} allow=${effectiveAllow} shotType=${normalizedShotType} confidence=${normalizedConfidence} reasonCode=${reasonCode} sexual=${sexualContent} textBoxes=${textBoxes.length}`,
    );

    if (effectiveAllow) {
      const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
      if (!uuidRe.test(ownerId)) {
        console.error(
          `[validate-primary-photo:${requestId}] Invalid ownerId derived from photoPath ownerId=${ownerId} photoPath=${photoPath}`,
        );
        return await jsonResponse(
          {
            allow: false,
            message: "Unable to verify your photo right now. Please try again.",
          },
          400,
          { success: false, errorType: "bad_request", errorMessage: "Invalid ownerId derived from photoPath" },
        );
      }

      const { data: row, error: fetchErr } = await supabase
        .from("users")
        .select("approved_primary_photos")
        .eq("id", ownerId)
        .maybeSingle();
      if (fetchErr || !row) {
        console.error(
          `[validate-primary-photo:${requestId}] Failed to load approved_primary_photos error=${truncate(safeStringify(fetchErr))}`,
        );
        return await jsonResponse(
          {
            allow: false,
            message: "Unable to verify your photo right now. Please try again.",
          },
          500,
          {
            success: false,
            errorType: "db_read_failed",
            errorMessage: truncate(safeStringify(fetchErr)),
            userId: ownerId,
          },
        );
      }

      const existing = Array.isArray((row as any).approved_primary_photos)
        ? ((row as any).approved_primary_photos as unknown[]).map((v) => String(v))
        : [];
      const next = Array.from(new Set([...existing, photoPath]));
      const { error: updateErr } = await supabase
        .from("users")
        .update({ approved_primary_photos: next })
        .eq("id", ownerId);
      if (updateErr) {
        console.error(
          `[validate-primary-photo:${requestId}] Failed to persist approved_primary_photos error=${truncate(safeStringify(updateErr))}`,
        );
        return await jsonResponse(
          {
            allow: false,
            message: "Unable to verify your photo right now. Please try again.",
          },
          500,
          {
            success: false,
            errorType: "db_write_failed",
            errorMessage: truncate(safeStringify(updateErr)),
            userId: ownerId,
          },
        );
      }
    }

    return await jsonResponse(
      {
        allow: effectiveAllow,
        action: effectiveAction,
        shotType: normalizedShotType,
        reasonCode: hasSexual ? "BAD_CONTENT" : reasonCode,
        confidence: normalizedConfidence,
        message: effectiveAllow ? "OK" : message,
        faceBox: faceBox,
        textBoxes: textBoxes,
        sexualContent: sexualContent,
      },
      200,
      {
        success: true,
        userId: ownerId,
        meta: {
          action: effectiveAction,
          shotType: normalizedShotType,
          sexualContent,
          textBoxesCount: textBoxes.length,
        },
      },
    );
  } catch (e) {
    console.error(
      `[validate-primary-photo:${requestId}] Unhandled error: ${e instanceof Error ? e.message : String(e)}`,
    );
    return await jsonResponse(
      {
        allow: false,
        message: "Unable to verify your photo right now. Please try again.",
      },
      500,
      { success: false, errorType: "exception", errorMessage: e instanceof Error ? e.message : String(e), userId: ownerId },
    );
  }
});
