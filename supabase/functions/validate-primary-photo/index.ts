import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";
import { buildGeminiUrl, resolveVisionModels } from "../_shared/gemini_config.ts";

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

function normalizeStorageObjectPath(path: string, bucketName: string): string {
  const trimmed = path.trim().replace(/^\/+/, "");
  const bucketPrefix = `${bucketName}/`;
  return trimmed.startsWith(bucketPrefix)
    ? trimmed.slice(bucketPrefix.length)
    : trimmed;
}

interface IdentityDescriptor {
  version: number;
  model: string;
  generatedAt: string;
  faceVisible: boolean;
  quality: number;
  featureLabels: string[];
  featureVector: number[];
  reasoning: string;
}

const identityDescriptorFeatureLabels = [
  "face_length_width_ratio",
  "forehead_width_ratio",
  "cheekbone_width_ratio",
  "jaw_width_ratio",
  "chin_height_ratio",
  "eye_spacing_ratio",
  "eye_size_ratio",
  "eye_tilt",
  "brow_height_ratio",
  "brow_thickness",
  "nose_length_ratio",
  "nose_width_ratio",
  "mouth_width_ratio",
  "upper_lip_fullness",
  "lower_lip_fullness",
  "philtrum_length_ratio",
];

function normalizeIdentityDescriptor(value: unknown): IdentityDescriptor | null {
  const obj = value && typeof value === "object"
    ? (value as Record<string, unknown>)
    : null;
  if (!obj) return null;
  const vector = Array.isArray(obj.featureVector)
    ? obj.featureVector
      .map((item) => typeof item === "number" ? item : Number(item))
      .map((item) => Number.isFinite(item) ? Math.max(0, Math.min(1, item)) : 0)
    : [];
  if (vector.length !== identityDescriptorFeatureLabels.length) return null;
  return {
    version: typeof obj.version === "number" ? obj.version : 1,
    model: typeof obj.model === "string" ? obj.model : "unknown",
    generatedAt: typeof obj.generatedAt === "string" ? obj.generatedAt : new Date(0).toISOString(),
    faceVisible: obj.faceVisible === true,
    quality: typeof obj.quality === "number"
      ? Math.max(0, Math.min(1, obj.quality))
      : 0,
    featureLabels: Array.isArray(obj.featureLabels) &&
        obj.featureLabels.length === identityDescriptorFeatureLabels.length
      ? obj.featureLabels.map((item) => String(item))
      : [...identityDescriptorFeatureLabels],
    featureVector: vector,
    reasoning: typeof obj.reasoning === "string" ? obj.reasoning : "",
  };
}

function cosineSimilarity(a: number[], b: number[]): number {
  if (a.length !== b.length || a.length === 0) return 0;
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA <= 0 || normB <= 0) return 0;
  return dot / (Math.sqrt(normA) * Math.sqrt(normB));
}

function compareIdentityDescriptors(
  reference: IdentityDescriptor,
  candidate: IdentityDescriptor,
): {
  decision: "match" | "mismatch" | "inconclusive";
  similarity: number;
  confidence: number;
  cosine: number;
  averageDifference: number;
} {
  const cosine = Math.max(
    0,
    Math.min(1, cosineSimilarity(reference.featureVector, candidate.featureVector)),
  );
  const averageDifference = reference.featureVector.reduce(
    (sum, value, index) => sum + Math.abs(value - candidate.featureVector[index]),
    0,
  ) / reference.featureVector.length;
  const consistency = Math.max(0, 1 - averageDifference);
  const similarity = Math.max(
    0,
    Math.min(100, ((cosine * 0.7) + (consistency * 0.3)) * 100),
  );
  const confidence = Math.max(
    0,
    Math.min(100, ((reference.quality + candidate.quality) / 2) * 100),
  );

  if (
    reference.faceVisible &&
    candidate.faceVisible &&
    confidence >= 55 &&
    cosine >= 0.965 &&
    averageDifference <= 0.12
  ) {
    return { decision: "match", similarity, confidence, cosine, averageDifference };
  }

  if (
    !candidate.faceVisible ||
    confidence < 35 ||
    cosine <= 0.88 ||
    averageDifference >= 0.2
  ) {
    return { decision: "mismatch", similarity, confidence, cosine, averageDifference };
  }

  return { decision: "inconclusive", similarity, confidence, cosine, averageDifference };
}

function translationKeyForPrimaryPhotoReasonCode(reasonCode: string | null | undefined): string {
  switch (reasonCode) {
    case "NO_PERSON":
      return "primaryPhotoVerificationErrorNoPerson";
    case "FACE_NOT_VISIBLE":
      return "primaryPhotoVerificationErrorFaceNotVisible";
    case "BAD_CONTENT":
      return "primaryPhotoVerificationErrorBadContent";
    case "MULTIPLE_PEOPLE":
      return "primaryPhotoVerificationErrorMultipleFaces";
    case "BODY_SHOT":
      return "primaryPhotoVerificationErrorBodyNotAllowed";
    case "VERIFIED_SELFIE_MISMATCH":
      return "primaryPhotoVerificationErrorVerifiedMismatch";
    case "VERIFIED_REFERENCE_EXPIRED":
      return "primaryPhotoVerificationErrorReferenceExpired";
    case "SYSTEM_ERROR":
      return "primaryPhotoVerificationErrorSystem";
    default:
      return "primaryPhotoVerificationErrorGeneral";
  }
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
          translationKey: translationKeyForPrimaryPhotoReasonCode("SYSTEM_ERROR"),
          message: "Unable to verify your photo right now. Please try again.",
        },
        500,
        { success: false, errorType: "config_missing", errorMessage: "Missing GOOGLE_AI_API_KEY" },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);
    const generateIdentityDescriptor = async (
      imageBuffer: ArrayBuffer,
      purpose: "verification_reference" | "primary_candidate",
    ): Promise<{ descriptor: IdentityDescriptor | null; modelUsed: string | null }> => {
      const imageBase64 = arrayBufferToBase64(imageBuffer);
      const descriptorPrompt = `
Return ONLY valid JSON with this exact structure:
{
  "faceVisible": boolean,
  "quality": number,
  "featureVector": [number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number],
  "reasoning": string
}

You are generating a privacy-preserving identity descriptor for one person's face.

Rules:
- Use ONLY stable facial geometry and proportion cues visible in the image.
- Do NOT include age, race, ethnicity, gender, clothing, hairstyle, makeup, background, or expression-specific details.
- If there is not exactly one clear face, set "faceVisible" to false, "quality" to 0, and all 16 numbers in "featureVector" to 0.
- "quality" must be a number from 0 to 1.
- Every number in "featureVector" must be a normalized float from 0 to 1.
- Keep "reasoning" brief and neutral.

The 16 featureVector dimensions, in order, must be:
1. face_length_width_ratio
2. forehead_width_ratio
3. cheekbone_width_ratio
4. jaw_width_ratio
5. chin_height_ratio
6. eye_spacing_ratio
7. eye_size_ratio
8. eye_tilt
9. brow_height_ratio
10. brow_thickness
11. nose_length_ratio
12. nose_width_ratio
13. mouth_width_ratio
14. upper_lip_fullness
15. lower_lip_fullness
16. philtrum_length_ratio
`;
      const descriptorBody = JSON.stringify({
        contents: [{
          parts: [
            { text: descriptorPrompt },
            {
              inline_data: {
                mime_type: "image/jpeg",
                data: imageBase64,
              },
            },
          ],
        }],
        generationConfig: {
          responseMimeType: "application/json",
          temperature: 0,
        },
      });

      for (const modelName of await resolveVisionModels(API_KEY)) {
        aiUsed = true;
        aiModel = modelName;
        try {
          const descriptorResp = await fetch(
            buildGeminiUrl(modelName, API_KEY),
            {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: descriptorBody,
            },
          );
          if (!descriptorResp.ok) {
            console.error(
              `[validate-primary-photo:${requestId}] Identity descriptor HTTP ${descriptorResp.status} purpose=${purpose} model=${modelName}`,
            );
            continue;
          }
          const descriptorDecoded = await descriptorResp.json();
          const descriptorText =
            descriptorDecoded?.candidates?.[0]?.content?.parts?.[0]?.text?.trim?.();
          if (!descriptorText) {
            continue;
          }
          const descriptorParsed = JSON.parse(
            descriptorText.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim(),
          );
          const normalizedDescriptor = normalizeIdentityDescriptor({
            ...descriptorParsed,
            model: modelName,
            generatedAt: new Date().toISOString(),
            featureLabels: identityDescriptorFeatureLabels,
          });
          if (!normalizedDescriptor || !normalizedDescriptor.faceVisible) {
            return { descriptor: null, modelUsed: modelName };
          }
          return { descriptor: normalizedDescriptor, modelUsed: modelName };
        } catch (descriptorError) {
          console.error(
            `[validate-primary-photo:${requestId}] Identity descriptor error purpose=${purpose} model=${modelName} error=${descriptorError instanceof Error ? descriptorError.message : String(descriptorError)}`,
          );
        }
      }

      return { descriptor: null, modelUsed: null };
    };

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
          translationKey: translationKeyForPrimaryPhotoReasonCode("SYSTEM_ERROR"),
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
- the face is complete, fully inside the frame, and large enough to be the
  obvious subject of the image.

Reject if:
- it is a body shot (full body or upper body without clear focus on face), OR
- there are multiple people in the photo, OR
- no person is visible, OR
- the face is not clearly visible, OR
- the face is tiny compared with the image, partially outside the frame, or
  the image is mostly a room, object, scenery, ceiling, or background, OR
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
- When action is "REJECT", also provide faceBox (if any face is visible) and
  textBoxes for every visible text, watermark, or handle region, so the app can
  highlight the problem areas for the user. Omit boxes only when nothing relevant is detectable.
- sexualContent must be "none" for acceptable images. If sexualContent is "suggestive" or "explicit", action MUST be "REJECT" and reasonCode MUST be "BAD_CONTENT".
- If there is not exactly one clear face, set action to "REJECT" and choose the best reasonCode.
- A partial face at any image edge, or a face that is not the prominent subject, is FACE_NOT_VISIBLE.
- When action is ALLOW, faceBox is required and must tightly describe the one complete face.
- For faceBox and textBoxes: x,y,w,h are normalized floats 0..1, with x,y the top-left corner.
`;


    const visionModels = await resolveVisionModels(API_KEY);
    const geminiUrls = visionModels.map(m => ({ model: m, url: buildGeminiUrl(m, API_KEY) }));

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
      `[validate-primary-photo:${requestId}] Gemini request models=[${visionModels.join(",")}] promptChars=${prompt.length} requestBytes=${requestBody.length}`,
    );
    const maxAttempts = 3;
    let decoded: any | null = null;
    let lastErrText: string | null = null;
    let lastStatus: number | null = null;
    let lastErrorType: "http" | "network" | "timeout" | null = null;

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 12000);
      const target = geminiUrls[Math.min(attempt, geminiUrls.length - 1)];
      aiUsed = true;
      aiModel = target.model;
      try {
        console.log(
          `[validate-primary-photo:${requestId}] Gemini attempt ${attempt + 1}/${maxAttempts} sending request to ${target.model}`,
        );
        const resp = await fetch(target.url, {
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
          translationKey: translationKeyForPrimaryPhotoReasonCode("SYSTEM_ERROR"),
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
          translationKey: translationKeyForPrimaryPhotoReasonCode("SYSTEM_ERROR"),
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
    // Do not accept an AI "face" classification for a tiny or cropped face.
    // This check makes the server-side decision match the native prescreen
    // even when a local detector was unavailable.
    const faceBoxIsUsable = faceBox !== null &&
      faceBox.w * faceBox.h >= 0.10 &&
      faceBox.x > 0.02 && faceBox.y > 0.02 &&
      faceBox.x + faceBox.w < 0.98 && faceBox.y + faceBox.h < 0.98;
    const rejectedForUnusableFaceBox = allow && normalizedShotType === "face" &&
      !hasSexual && !faceBoxIsUsable;
    const effectiveAllow = allow && (normalizedShotType === "face") && !hasSexual && faceBoxIsUsable;
    const normalizedAction = actionRaw === "ALLOW" || actionRaw === "REJECT" || actionRaw === "SANITIZE"
      ? actionRaw
      : effectiveAllow
      ? "ALLOW"
      : "REJECT";
    const effectiveAction = hasSexual || rejectedForUnusableFaceBox ? "REJECT" : normalizedAction;
    const effectiveReasonCode = hasSexual
      ? "BAD_CONTENT"
      : rejectedForUnusableFaceBox
      ? "FACE_NOT_VISIBLE"
      : reasonCode;
    const effectiveMessage = rejectedForUnusableFaceBox
      ? "Please use a clear photo with your full face visible."
      : message;

    console.log(
      `[validate-primary-photo:${requestId}] Decision action=${effectiveAction} allow=${effectiveAllow} shotType=${normalizedShotType} confidence=${normalizedConfidence} reasonCode=${effectiveReasonCode} sexual=${sexualContent} textBoxes=${textBoxes.length}`,
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
            translationKey: translationKeyForPrimaryPhotoReasonCode("SYSTEM_ERROR"),
            message: "Unable to verify your photo right now. Please try again.",
          },
          400,
          { success: false, errorType: "bad_request", errorMessage: "Invalid ownerId derived from photoPath" },
        );
      }

      const { data: row, error: fetchErr } = await supabase
        .from("users")
        .select(
          "is_verified, verification_photo_path, verification_reference_artifact, verification_reference_generated_at, verification_photo_retention_until",
        )
        .eq("id", ownerId)
        .maybeSingle();
      if (fetchErr || !row) {
        console.error(
          `[validate-primary-photo:${requestId}] Failed to load verification data error=${truncate(safeStringify(fetchErr))}`,
        );
        return await jsonResponse(
          {
            allow: false,
            translationKey: translationKeyForPrimaryPhotoReasonCode("SYSTEM_ERROR"),
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

      // approved_primary_photos is now on user_profiles
      const { data: profileRow } = await supabase
        .from("user_profiles")
        .select("approved_primary_photos")
        .eq("user_id", ownerId)
        .maybeSingle();

      const existing = Array.isArray((profileRow as any)?.approved_primary_photos)
        ? ((profileRow as any).approved_primary_photos as unknown[]).map((v) => String(v))
        : [];
      const isVerified = (row as any).is_verified === true;
      const verificationReferenceArtifact =
        (row as any).verification_reference_artifact &&
          typeof (row as any).verification_reference_artifact === "object"
          ? (row as any).verification_reference_artifact as Record<string, unknown>
          : null;
      const verificationPhotoPathRaw = typeof (row as any).verification_photo_path === "string"
        ? (row as any).verification_photo_path.trim()
        : "";
      const verificationPhotoRetentionUntilRaw =
        typeof (row as any).verification_photo_retention_until === "string"
          ? (row as any).verification_photo_retention_until.trim()
          : "";
      const verificationPhotoRetentionUntilMs = verificationPhotoRetentionUntilRaw.length > 0
        ? Date.parse(verificationPhotoRetentionUntilRaw)
        : Number.NaN;
      const verificationPhotoRetentionActive =
        verificationPhotoRetentionUntilRaw.length === 0 ||
        (
          Number.isFinite(verificationPhotoRetentionUntilMs) &&
          verificationPhotoRetentionUntilMs > Date.now()
        );
      const sendReverifyRequired = async (
        meta: Record<string, unknown>,
      ) =>
        await jsonResponse(
          {
            allow: false,
            action: "REJECT",
            shotType: normalizedShotType,
            reasonCode: "VERIFIED_REFERENCE_EXPIRED",
            translationKey: translationKeyForPrimaryPhotoReasonCode("VERIFIED_REFERENCE_EXPIRED"),
            confidence: normalizedConfidence,
            message:
              "Please re-verify your profile before changing your primary photo.",
            faceBox: faceBox,
            textBoxes: textBoxes,
            sexualContent: sexualContent,
          },
          200,
          {
            success: true,
            userId: ownerId,
            meta: {
              action: "REJECT",
              shotType: normalizedShotType,
              sexualContent,
              textBoxesCount: textBoxes.length,
              ...meta,
            },
          },
        );
      let storedIdentityDescriptor = normalizeIdentityDescriptor(
        verificationReferenceArtifact?.identityDescriptor,
      );
      let verificationBuffer: ArrayBuffer | null = null;
      const loadVerificationBuffer = async () => {
        if (verificationBuffer) {
          return verificationBuffer;
        }
        if (verificationPhotoPathRaw.length === 0) {
          return null;
        }
        const verificationPhotoPath = normalizeStorageObjectPath(
          verificationPhotoPathRaw,
          "verification-photos",
        );
        const verificationResp = await supabase.storage.from("verification-photos").download(
          verificationPhotoPath,
        );
        if (verificationResp.error || !verificationResp.data) {
          console.error(
            `[validate-primary-photo:${requestId}] Failed to download stored verification photo: ${truncate(safeStringify(verificationResp.error ?? "unknown"))}`,
          );
          return null;
        }
        verificationBuffer = await verificationResp.data.arrayBuffer();
        return verificationBuffer;
      };

      if (
        isVerified &&
        !storedIdentityDescriptor &&
        verificationPhotoPathRaw.length > 0 &&
        verificationPhotoRetentionActive
      ) {
        const retainedVerificationBuffer = await loadVerificationBuffer();
        if (retainedVerificationBuffer) {
          const { descriptor: backfilledDescriptor } = await generateIdentityDescriptor(
            retainedVerificationBuffer,
            "verification_reference",
          );
          if (backfilledDescriptor) {
            storedIdentityDescriptor = backfilledDescriptor;
            const nextReferenceArtifact = {
              ...(verificationReferenceArtifact ?? {}),
              version: 2,
              kind: "verification_reference_artifact",
              source: "verification_selfie",
              generatedAt: backfilledDescriptor.generatedAt,
              identityDescriptor: backfilledDescriptor,
              descriptorStatus: "ready",
            };
            const { error: backfillUpdateErr } = await supabase
              .from("users")
              .update({
                verification_reference_artifact: nextReferenceArtifact,
                verification_reference_generated_at: backfilledDescriptor.generatedAt,
              })
              .eq("id", ownerId);
            if (backfillUpdateErr) {
              console.error(
                `[validate-primary-photo:${requestId}] Failed to backfill identity descriptor: ${truncate(safeStringify(backfillUpdateErr))}`,
              );
            }
          }
        }
      }

      if (isVerified && verificationPhotoPathRaw.length > 0 && verificationPhotoRetentionActive) {
        const retainedVerificationBuffer = await loadVerificationBuffer();
        if (retainedVerificationBuffer) {
          const verificationBase64 = arrayBufferToBase64(retainedVerificationBuffer);
          const candidateBase64 = arrayBufferToBase64(photoBuffer);
          const identityPrompt = `
Compare these two private images:
- Image A: the user's stored verification selfie
- Image B: a new candidate primary profile photo

Decide whether they CLEARLY show the same real person.

Return ONLY valid JSON matching this schema:
{
  "isMatch": boolean,
  "similarity": number,
  "confidence": number,
  "reasoning": string
}

Rules:
- similarity must be a number from 0 to 100
- confidence must be a number from 0 to 100
- Return isMatch false if the faces clearly appear to be different people
- Return isMatch false if either image does not show one clear face well enough to compare
- Keep reasoning brief and neutral
`;

          const identityRequestBody = JSON.stringify({
            contents: [{
              parts: [
                { text: identityPrompt },
                {
                  inline_data: {
                    mime_type: "image/jpeg",
                  data: verificationBase64,
                  },
                },
                {
                  inline_data: {
                    mime_type: "image/jpeg",
                    data: candidateBase64,
                  },
                },
              ],
            }],
            generationConfig: {
              responseMimeType: "application/json",
              temperature: 0,
            },
          });

          let identityDecoded: any | null = null;
          for (const modelName of await resolveVisionModels(API_KEY)) {
            aiUsed = true;
            aiModel = modelName;
            const identityUrl = buildGeminiUrl(modelName, API_KEY);
            try {
              const identityResp = await fetch(identityUrl, {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: identityRequestBody,
              });
              if (!identityResp.ok) {
                console.error(
                  `[validate-primary-photo:${requestId}] Verified identity compare HTTP ${identityResp.status} model=${modelName}`,
                );
                continue;
              }
              identityDecoded = await identityResp.json();
              break;
            } catch (identityError) {
              console.error(
                `[validate-primary-photo:${requestId}] Verified identity compare failed model=${modelName} error=${identityError instanceof Error ? identityError.message : String(identityError)}`,
              );
            }
          }

          const identityText = identityDecoded?.candidates?.[0]?.content?.parts?.[0]?.text?.trim?.();
          if (identityText) {
            const identityCleaned = identityText
              .replace(/^```(?:json)?\s*/i, "")
              .replace(/\s*```$/, "")
              .trim();
            let identityParsed: unknown = null;
            try {
              identityParsed = JSON.parse(identityCleaned);
            } catch (_) {
              const identityJsonMatch = identityCleaned.match(/\{[\s\S]*\}/);
              if (identityJsonMatch) {
                try {
                  identityParsed = JSON.parse(identityJsonMatch[0]);
                } catch (_) {
                  identityParsed = null;
                }
              }
            }

            const identityObj = identityParsed && typeof identityParsed === "object"
              ? (identityParsed as Record<string, unknown>)
              : null;
            const identityIsMatch = typeof identityObj?.isMatch === "boolean"
              ? identityObj.isMatch
              : null;
            const identitySimilarity = typeof identityObj?.similarity === "number"
              ? Math.max(0, Math.min(100, identityObj.similarity))
              : 0;
            const identityConfidence = typeof identityObj?.confidence === "number"
              ? Math.max(0, Math.min(100, identityObj.confidence))
              : 0;

            if (
              identityIsMatch === false &&
              (identitySimilarity <= 45 || identityConfidence >= 80)
            ) {
              console.warn(
                `[validate-primary-photo:${requestId}] Rejected primary photo for verified identity mismatch similarity=${identitySimilarity} confidence=${identityConfidence}`,
              );
              return await jsonResponse(
                {
                  allow: false,
                  action: "REJECT",
                  shotType: normalizedShotType,
                  reasonCode: "VERIFIED_SELFIE_MISMATCH",
                  translationKey: translationKeyForPrimaryPhotoReasonCode("VERIFIED_SELFIE_MISMATCH"),
                  confidence: Math.max(normalizedConfidence, identityConfidence / 100),
                  message: "Your primary photo must match your verified identity.",
                  faceBox: faceBox,
                  textBoxes: textBoxes,
                  sexualContent: sexualContent,
                },
                200,
                {
                  success: true,
                  userId: ownerId,
                  meta: {
                    action: "REJECT",
                    shotType: normalizedShotType,
                    sexualContent,
                    textBoxesCount: textBoxes.length,
                    verifiedIdentityMatch: false,
                    verifiedIdentitySimilarity: identitySimilarity,
                    verifiedIdentityConfidence: identityConfidence,
                  },
                },
              );
            }
          }
        }
      } else if (isVerified) {
        if (!storedIdentityDescriptor) {
          console.warn(
            `[validate-primary-photo:${requestId}] No derived identity descriptor available for user=${ownerId}`,
          );
          return await sendReverifyRequired({
            verifiedReferenceExpired: true,
            derivedIdentityAvailable: false,
          });
        }

        const { descriptor: candidateIdentityDescriptor } = await generateIdentityDescriptor(
          photoBuffer,
          "primary_candidate",
        );
        if (!candidateIdentityDescriptor) {
          console.warn(
            `[validate-primary-photo:${requestId}] Candidate descriptor unavailable for user=${ownerId}`,
          );
          return await sendReverifyRequired({
            verifiedReferenceExpired: false,
            derivedIdentityAvailable: true,
            derivedIdentityDecision: "candidate_unavailable",
          });
        }

        const derivedIdentityComparison = compareIdentityDescriptors(
          storedIdentityDescriptor,
          candidateIdentityDescriptor,
        );
        console.log(
          `[validate-primary-photo:${requestId}] Derived identity comparison decision=${derivedIdentityComparison.decision} similarity=${derivedIdentityComparison.similarity.toFixed(2)} confidence=${derivedIdentityComparison.confidence.toFixed(2)} cosine=${derivedIdentityComparison.cosine.toFixed(4)} avgDiff=${derivedIdentityComparison.averageDifference.toFixed(4)}`,
        );

        if (derivedIdentityComparison.decision === "mismatch") {
          return await jsonResponse(
            {
              allow: false,
              action: "REJECT",
              shotType: normalizedShotType,
              reasonCode: "VERIFIED_SELFIE_MISMATCH",
              translationKey: translationKeyForPrimaryPhotoReasonCode("VERIFIED_SELFIE_MISMATCH"),
              confidence: Math.max(
                normalizedConfidence,
                derivedIdentityComparison.confidence / 100,
              ),
              message: "Your primary photo must match your verified identity.",
              faceBox: faceBox,
              textBoxes: textBoxes,
              sexualContent: sexualContent,
            },
            200,
            {
              success: true,
              userId: ownerId,
              meta: {
                action: "REJECT",
                shotType: normalizedShotType,
                sexualContent,
                textBoxesCount: textBoxes.length,
                verifiedIdentityMatch: false,
                verifiedIdentitySimilarity: derivedIdentityComparison.similarity,
                verifiedIdentityConfidence: derivedIdentityComparison.confidence,
                derivedIdentityMethod: "descriptor",
              },
            },
          );
        }

        if (derivedIdentityComparison.decision === "inconclusive") {
          return await sendReverifyRequired({
            verifiedReferenceExpired: false,
            derivedIdentityAvailable: true,
            derivedIdentityDecision: "inconclusive",
            derivedIdentitySimilarity: derivedIdentityComparison.similarity,
          });
        }
      }

      const next = Array.from(new Set([...existing, photoPath]));
      const { error: updateErr } = await supabase
        .from("user_profiles")
        .update({ approved_primary_photos: next })
        .eq("user_id", ownerId);
      if (updateErr) {
        console.error(
          `[validate-primary-photo:${requestId}] Failed to persist approved_primary_photos error=${truncate(safeStringify(updateErr))}`,
        );
        return await jsonResponse(
          {
            allow: false,
            translationKey: translationKeyForPrimaryPhotoReasonCode("SYSTEM_ERROR"),
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
        reasonCode: effectiveReasonCode,
        translationKey: effectiveAllow
          ? null
          : translationKeyForPrimaryPhotoReasonCode(effectiveReasonCode),
        confidence: normalizedConfidence,
        message: effectiveAllow ? "OK" : effectiveMessage,
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
        translationKey: translationKeyForPrimaryPhotoReasonCode("SYSTEM_ERROR"),
        message: "Unable to verify your photo right now. Please try again.",
      },
      500,
      { success: false, errorType: "exception", errorMessage: e instanceof Error ? e.message : String(e), userId: ownerId },
    );
  }
});
