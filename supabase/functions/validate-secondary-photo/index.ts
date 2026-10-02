import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";
import { buildGeminiUrl, resolveVisionModels } from "../_shared/gemini_config.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function uint8ArrayToBase64(bytes: Uint8Array): string {
  const chunkSize = 0x8000;
  let binary = "";
  for (let index = 0; index < bytes.length; index += chunkSize) {
    const chunk = bytes.subarray(index, index + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}

function normalizeStorageObjectPath(path: string, bucketName: string): string {
  const trimmed = path.trim().replace(/^\/+/, "");
  const bucketPrefix = `${bucketName}/`;
  return trimmed.startsWith(bucketPrefix)
    ? trimmed.slice(bucketPrefix.length)
    : trimmed;
}

function translationKeyForSecondaryPhotoReasonCode(
  reasonCode: string | null | undefined,
): string {
  switch (reasonCode) {
    case "NO_FACE_OR_BODY":
      return "secondaryPhotoVerificationErrorNoFaceOrBody";
    case "TEXT_SCREENSHOT_OR_WATERMARK":
      return "secondaryPhotoVerificationErrorTextScreenshotOrWatermark";
    case "BAD_CONTENT":
      return "secondaryPhotoVerificationErrorBadContent";
    case "SYSTEM_ERROR":
      return "secondaryPhotoVerificationErrorSystem";
    default:
      return "secondaryPhotoVerificationErrorGeneral";
  }
}

function extractJsonText(decoded: any): string {
  const candidate =
    decoded?.candidates?.[0]?.content?.parts?.find((part: any) =>
      typeof part?.text === "string"
    )?.text ?? "";
  return typeof candidate === "string" ? candidate.trim() : "";
}

const allowedIssueLabels = new Set(["text", "watermark", "screenshot", "meme"]);

const clamp01 = (n: unknown): number => {
  const v = typeof n === "number" ? n : Number(n);
  return Number.isFinite(v) ? Math.max(0, Math.min(1, v)) : 0;
};

function normalizeIssueBoxes(value: unknown): Array<
  { x: number; y: number; w: number; h: number; label: string }
> {
  if (!Array.isArray(value)) return [];
  const out: Array<{ x: number; y: number; w: number; h: number; label: string }> = [];
  for (const item of value) {
    const obj = item && typeof item === "object" ? (item as Record<string, unknown>) : null;
    if (!obj) continue;
    const w = clamp01(obj.w);
    const h = clamp01(obj.h);
    if (w <= 0 || h <= 0) continue;
    const rawLabel = typeof obj.label === "string" ? obj.label.trim().toLowerCase() : "";
    out.push({
      x: clamp01(obj.x),
      y: clamp01(obj.y),
      w,
      h,
      label: allowedIssueLabels.has(rawLabel) ? rawLabel : "text",
    });
  }
  return out;
}

function truncate(value: string, max = 4000): string {
  return value.length <= max ? value : `${value.slice(0, max)}…(truncated)`;
}

function isRetryableStatus(status: number): boolean {
  return status === 408 || status === 429 || status >= 500;
}

function backoffMsForAttempt(attempt: number): number {
  return [400, 900, 1600][attempt] ?? 1600;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getGeminiApiKey(): string | null {
  const candidates = [
    Deno.env.get("GOOGLE_AI_API_KEY"),
    Deno.env.get("GOOGLE_GEMINI_API_KEY"),
  ];
  for (const candidate of candidates) {
    const trimmed = candidate?.trim();
    if (trimmed) {
      return trimmed;
    }
  }
  return null;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const requestId = crypto.randomUUID();
  const startedAt = Date.now();
  const functionName = "validate-secondary-photo";
  let aiUsed = false;
  let aiModel: string | null = null;
  const aiProvider = "google_gemini";
  const aiTask = "secondary_photo_validation";

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
    logEdgeFunctionInvocation({
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

  let ownerId: string | null = null;

  try {
    const body = await req.json();
    const photoPath = typeof body?.photoPath === "string"
      ? body.photoPath.trim()
      : "";
    console.log("[validate-secondary-photo] request:start", {
      requestId,
      hasPhotoPath: photoPath.length > 0,
      photoPath,
      hasAuthorization: !!req.headers.get("Authorization"),
    });

    if (!photoPath) {
      return await jsonResponse(
        {
          allow: false,
          action: "REJECT",
          reasonCode: "SYSTEM_ERROR",
          translationKey: translationKeyForSecondaryPhotoReasonCode(
            "SYSTEM_ERROR",
          ),
          message: "Missing photoPath.",
        },
        400,
        { success: false, errorType: "bad_request", errorMessage: "Missing photoPath" },
      );
    }

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
    const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const API_KEY = getGeminiApiKey();
    if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !API_KEY) {
      const missingConfig: string[] = [];
      if (!SUPABASE_URL) {
        missingConfig.push("SUPABASE_URL");
      }
      if (!SERVICE_ROLE_KEY) {
        missingConfig.push("SUPABASE_SERVICE_ROLE_KEY");
      }
      if (!API_KEY) {
        missingConfig.push("GOOGLE_AI_API_KEY|GOOGLE_GEMINI_API_KEY");
      }
      console.error(
        "[validate-secondary-photo] Missing required environment configuration:",
        missingConfig,
      );
      return await jsonResponse(
        {
          allow: false,
          action: "REJECT",
          reasonCode: "SYSTEM_ERROR",
          translationKey: translationKeyForSecondaryPhotoReasonCode(
            "SYSTEM_ERROR",
          ),
          message: "Server misconfiguration.",
        },
        500,
        {
          success: false,
          errorType: "server_config",
          errorMessage: `Missing required configuration: ${missingConfig.join(", ")}`,
          meta: {
            missingConfig,
            hasGoogleAiApiKey: !!Deno.env.get("GOOGLE_AI_API_KEY")?.trim(),
            hasGoogleGeminiApiKey: !!Deno.env.get("GOOGLE_GEMINI_API_KEY")?.trim(),
          },
        },
      );
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { persistSession: false },
      global: authHeader ? { headers: { Authorization: authHeader } } : undefined,
    });

    if (authHeader) {
      const token = authHeader.replace(/^Bearer\s+/i, "").trim();
      if (token) {
        const userResp = await admin.auth.getUser(token);
        ownerId = userResp.data.user?.id ?? null;
        console.log("[validate-secondary-photo] auth:resolved-user", {
          requestId,
          ownerId,
        });
      }
    }

    const bucketName = "profile-photos";
    const objectPath = normalizeStorageObjectPath(photoPath, bucketName);
    console.log("[validate-secondary-photo] storage:download:start", {
      requestId,
      bucketName,
      objectPath,
      ownerId,
    });
    const { data: bytes, error: downloadError } = await admin.storage
      .from(bucketName)
      .download(objectPath);

    if (downloadError || !bytes) {
      console.error("[validate-secondary-photo] storage:download:failed", {
        requestId,
        objectPath,
        ownerId,
        error: downloadError?.message ?? "Photo not found",
      });
      return await jsonResponse(
        {
          allow: false,
          action: "REJECT",
          reasonCode: "SYSTEM_ERROR",
          translationKey: translationKeyForSecondaryPhotoReasonCode(
            "SYSTEM_ERROR",
          ),
          message: "Unable to access photo.",
        },
        404,
        {
          success: false,
          errorType: "download_failed",
          errorMessage: downloadError?.message ?? "Photo not found",
          userId: ownerId,
        },
      );
    }

    const photoBytes = new Uint8Array(await bytes.arrayBuffer());
    const photoBase64 = uint8ArrayToBase64(photoBytes);
    const mimeType = bytes.type?.trim()
      ? bytes.type
      : "image/jpeg";
    console.log("[validate-secondary-photo] storage:download:success", {
      requestId,
      objectPath,
      ownerId,
      mimeType,
      byteLength: photoBytes.byteLength,
      base64Length: photoBase64.length,
    });
    const prompt = `
You are a strict dating-app profile gallery photo reviewer.
Decide whether this image is acceptable as a NON-PRIMARY profile photo.

Accept only if:
- the image contains at least one recognizable real human face or real human body,
  whether it is one person or a group and whether they are close-up or distant, and
- the image does not contain restricted sexual or otherwise inappropriate content.

Reject if:
- no real person is visible, or
- neither a face nor a body is clearly visible, or
- the image only contains an unrecognizable fragment of a person (for example,
  part of a head) and no recognizable face or body, or
- the image is explicit, sexual, shows nudity, fetish content, or suggests minors, or
- the image is graphic, hateful, or otherwise unsafe for a dating profile, or
- the image is an advertisement, meme, screenshot, text-only image, AI-generated
  or synthetic image, cartoon, collage, materially photo-manipulated image, or
  product shot without a real visible person, or
- it contains a watermark, marketing material, URL, handle, phone number, or
  visible obscene/profane text.

Return ONLY valid JSON matching this schema:
{
  "allow": boolean,
  "action": "ALLOW" | "REJECT",
  "reasonCode": "NO_FACE_OR_BODY" | "TEXT_SCREENSHOT_OR_WATERMARK" | "BAD_CONTENT" | "OK",
  "containsFace": boolean,
  "containsBody": boolean,
  "isScreenshot": boolean,
  "isMeme": boolean,
  "hasProminentText": boolean,
  "hasWatermark": boolean,
  "confidence": number,
  "message": string,
  "sexualContent": "none" | "suggestive" | "explicit",
  "issueBoxes": Array<{"x": number, "y": number, "w": number, "h": number, "label": "text" | "watermark" | "screenshot" | "meme"}>
}

Rules:
- confidence must be a number from 0 to 1
- message must be short and user-friendly
- if allow is true, action must be "ALLOW", reasonCode must be "OK", and sexualContent must be "none"
- if sexualContent is "suggestive" or "explicit", action must be "REJECT" and reasonCode must be "BAD_CONTENT"
- if the image is a screenshot, meme, text-only image, or has prominent overlaid text or a watermark, action must be "REJECT" and reasonCode must be "TEXT_SCREENSHOT_OR_WATERMARK"
- if containsFace is false and containsBody is false, action must be "REJECT" and reasonCode must be "NO_FACE_OR_BODY"
- Count any recognizable real face or body at any distance as visible. Do not reject
  a real group, distant person, close-up, or ordinary crop merely because it is
  not the dominant subject. Do reject an unrecognizable human fragment.
- When rejecting with reasonCode "TEXT_SCREENSHOT_OR_WATERMARK", you MUST provide
  issueBoxes tightly locating every problem region (each watermark, text block,
  URL/handle, or the screenshot frame), so the app can highlight them for the user.
- issueBoxes: x,y,w,h are normalized floats 0..1 relative to the full image, with
  x,y the top-left corner. When the rejection is not region-specific (for example
  BAD_CONTENT), return an empty array.
`;

    const requestBody = JSON.stringify({
      contents: [{
        parts: [
          { text: prompt },
          {
            inline_data: {
              mime_type: mimeType,
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

    const visionModels = await resolveVisionModels(API_KEY);
    const geminiUrls = visionModels.map(m => ({ model: m, url: buildGeminiUrl(m, API_KEY) }));

    let decoded: any = null;
    let lastStatus: number | null = null;
    let lastErrText: string | null = null;

    for (let attempt = 0; attempt < 3; attempt++) {
      const target = geminiUrls[Math.min(attempt, geminiUrls.length - 1)];
      aiUsed = true;
      aiModel = target.model;
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 30000);
      console.log("[validate-secondary-photo] gemini:attempt:start", {
        requestId,
        attempt: attempt + 1,
        model: target.model,
        ownerId,
        objectPath,
      });

      try {
        const resp = await fetch(target.url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: requestBody,
          signal: controller.signal,
        });

        if (resp.ok) {
          decoded = await resp.json();
          lastStatus = resp.status;
          lastErrText = null;
          console.log("[validate-secondary-photo] gemini:attempt:success", {
            requestId,
            attempt: attempt + 1,
            model: target.model,
            status: resp.status,
          });
          break;
        }

        lastStatus = resp.status;
        lastErrText = await resp.text();
        console.error("[validate-secondary-photo] gemini:attempt:failed", {
          requestId,
          attempt: attempt + 1,
          model: target.model,
          status: resp.status,
          error: truncate(lastErrText),
        });
        if (!isRetryableStatus(resp.status) || attempt === 2) {
          break;
        }
      } catch (error) {
        lastStatus = null;
        lastErrText = error instanceof Error ? error.message : String(error);
        console.error("[validate-secondary-photo] gemini:attempt:error", {
          requestId,
          attempt: attempt + 1,
          model: target.model,
          error: lastErrText,
        });
        if (attempt === 2) {
          break;
        }
      } finally {
        clearTimeout(timeoutId);
      }

      await sleep(backoffMsForAttempt(attempt));
    }

    if (!decoded) {
      return await jsonResponse(
        {
          allow: false,
          action: "REJECT",
          reasonCode: "SYSTEM_ERROR",
          translationKey: translationKeyForSecondaryPhotoReasonCode(
            "SYSTEM_ERROR",
          ),
          message: "Unable to verify your photo right now. Please try again.",
          geminiStatus: lastStatus,
        },
        503,
        {
          success: false,
          errorType: "gemini_unavailable",
          errorMessage: truncate(lastErrText ?? "Gemini unavailable"),
          userId: ownerId,
          meta: { geminiStatus: lastStatus },
        },
      );
    }

    let parsed: Record<string, unknown> | null = null;
    try {
      const text = extractJsonText(decoded);
      console.log("[validate-secondary-photo] gemini:response:text", {
        requestId,
        model: aiModel,
        text: truncate(text, 1000),
      });
      parsed = JSON.parse(text);
    } catch (error) {
      console.error("[validate-secondary-photo] gemini:response:parse-failed", {
        requestId,
        model: aiModel,
        error: error instanceof Error ? error.message : String(error),
      });
      return await jsonResponse(
        {
          allow: false,
          action: "REJECT",
          reasonCode: "SYSTEM_ERROR",
          translationKey: translationKeyForSecondaryPhotoReasonCode(
            "SYSTEM_ERROR",
          ),
          message: "Unable to verify your photo right now. Please try again.",
        },
        502,
        {
          success: false,
          errorType: "invalid_ai_response",
          errorMessage: error instanceof Error ? error.message : String(error),
          userId: ownerId,
        },
      );
    }

    const containsFace = parsed?.containsFace === true;
    const containsBody = parsed?.containsBody === true;
    const isScreenshot = parsed?.isScreenshot === true;
    const isMeme = parsed?.isMeme === true;
    const hasProminentText = parsed?.hasProminentText === true;
    const hasWatermark = parsed?.hasWatermark === true;
    const issueBoxes = normalizeIssueBoxes(parsed?.issueBoxes);
    const sexualContent = typeof parsed?.sexualContent === "string"
      ? parsed.sexualContent
      : "none";
    const confidence = typeof parsed?.confidence === "number"
      ? Math.max(0, Math.min(1, parsed.confidence))
      : 0;

    let reasonCode = typeof parsed?.reasonCode === "string"
      ? parsed.reasonCode
      : "OK";
    let allow = parsed?.allow === true;
    let action = parsed?.action === "ALLOW" ? "ALLOW" : "REJECT";

    if (sexualContent !== "none") {
      allow = false;
      action = "REJECT";
      reasonCode = "BAD_CONTENT";
    } else if (isScreenshot || isMeme || hasProminentText || hasWatermark) {
      allow = false;
      action = "REJECT";
      reasonCode = "TEXT_SCREENSHOT_OR_WATERMARK";
    } else if (!containsFace && !containsBody) {
      allow = false;
      action = "REJECT";
      reasonCode = "NO_FACE_OR_BODY";
    } else if (allow) {
      action = "ALLOW";
      reasonCode = "OK";
    }

    console.log("[validate-secondary-photo] decision", {
      requestId,
      ownerId,
      objectPath,
      allow,
      action,
      reasonCode,
      containsFace,
      containsBody,
      isScreenshot,
      isMeme,
      hasProminentText,
      hasWatermark,
      sexualContent,
      confidence,
      issueBoxesCount: issueBoxes.length,
      model: aiModel,
    });

    return await jsonResponse(
      {
        allow,
        action,
        reasonCode,
        translationKey: allow
          ? null
          : translationKeyForSecondaryPhotoReasonCode(reasonCode),
        containsFace,
        containsBody,
        isScreenshot,
        isMeme,
        hasProminentText,
        hasWatermark,
        confidence,
        message: typeof parsed?.message === "string"
          ? parsed.message
          : allow
          ? "Photo accepted."
          : "Photo rejected.",
        sexualContent,
        issueBoxes: allow ? [] : issueBoxes,
      },
      200,
      {
        success: true,
        userId: ownerId,
        meta: {
          containsFace,
          containsBody,
          isScreenshot,
          isMeme,
          hasProminentText,
          hasWatermark,
          confidence,
          reasonCode,
          allow,
          issueBoxesCount: issueBoxes.length,
        },
      },
    );
  } catch (error) {
    console.error("[validate-secondary-photo] unhandled_exception", {
      requestId,
      ownerId,
      error: error instanceof Error ? error.message : String(error),
      stack: error instanceof Error ? error.stack ?? null : null,
    });
    return await jsonResponse(
      {
        allow: false,
        action: "REJECT",
        reasonCode: "SYSTEM_ERROR",
        translationKey: translationKeyForSecondaryPhotoReasonCode(
          "SYSTEM_ERROR",
        ),
        message: "Unable to verify your photo right now. Please try again.",
      },
      500,
      {
        success: false,
        errorType: "unhandled_exception",
        errorMessage: error instanceof Error ? error.message : String(error),
        userId: ownerId,
      },
    );
  }
});
