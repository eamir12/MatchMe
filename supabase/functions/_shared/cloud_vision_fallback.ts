// Cloud Vision fallback for photo validation Edge Functions.
//
// Used only when the Gemini vision chain is exhausted (e.g. HTTP 503 demand
// spikes). Decisions are intentionally conservative: Cloud Vision gives
// deterministic face boxes, text regions and SafeSearch labels, but cannot
// judge shot composition, memes or synthetic imagery, so anything ambiguous
// rejects with the closest reasonCode instead of allowing.
//
// Authentication, in priority order:
//   1. GOOGLE_CLOUD_VISION_API_KEY — plain API key (vision.googleapis.com).
//   2. GOOGLE_CLOUD_VISION_SERVICE_ACCOUNT_JSON — service-account JSON key
//      (raw JSON or base64-encoded), exchanged for an OAuth2 access token via
//      JWT. Use this on projects where API key creation is blocked by org
//      policy. The service account needs a Vision role (e.g. Cloud Vision
//      Admin) on the project.
// Cost: 3 units per image (one per feature); first 1,000 units/feature/month free.

const CLOUD_VISION_ENDPOINT = "https://vision.googleapis.com/v1/images:annotate";
const OAUTH_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
// Budgeted alongside the Gemini retries: the primary-photo client aborts the
// whole request after 30s, so the fallback must fit in what the retry chain
// leaves over (see per-function retryBudgetMs).
const CLOUD_VISION_TIMEOUT_MS = 8_000;
const MIN_FACE_DETECTION_CONFIDENCE = 0.5;
// Text regions covering more area than this, or more than this many regions,
// count as "prominent text" for secondary photos (Cloud Vision reads even
// incidental text like shirt prints, so unfiltered detection would over-reject).
const PROMINENT_TEXT_AREA = 0.10;
const PROMINENT_TEXT_MAX_BOXES = 2;

interface ServiceAccountKey {
  client_email: string;
  private_key: string;
}

export type CloudVisionCredential =
  | { kind: "apiKey"; apiKey: string }
  | { kind: "serviceAccount"; serviceAccount: ServiceAccountKey };

export function getCloudVisionCredential(): CloudVisionCredential | null {
  const apiKey = Deno.env.get("GOOGLE_CLOUD_VISION_API_KEY")?.trim();
  if (apiKey) return { kind: "apiKey", apiKey };
  const serviceAccountRaw = Deno.env.get("GOOGLE_CLOUD_VISION_SERVICE_ACCOUNT_JSON")?.trim();
  if (serviceAccountRaw) {
    const serviceAccount = parseServiceAccountJson(serviceAccountRaw);
    if (serviceAccount) return { kind: "serviceAccount", serviceAccount };
  }
  return null;
}

function parseServiceAccountJson(raw: string): ServiceAccountKey | null {
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    if (
      typeof parsed.client_email === "string" &&
      typeof parsed.private_key === "string"
    ) {
      return {
        client_email: parsed.client_email,
        private_key: parsed.private_key,
      };
    }
  } catch (_) {
    // Not raw JSON — try base64 (multiline JSON is awkward in `supabase secrets set`).
    try {
      const decoded = JSON.parse(new TextDecoder().decode(base64ToBytes(raw))) as Record<
        string,
        unknown
      >;
      if (
        typeof decoded.client_email === "string" &&
        typeof decoded.private_key === "string"
      ) {
        return {
          client_email: decoded.client_email,
          private_key: decoded.private_key,
        };
      }
    } catch (_) {
      console.error("[cloud_vision] service account JSON is neither valid JSON nor base64 JSON");
    }
  }
  console.error("[cloud_vision] service account JSON missing client_email/private_key");
  return null;
}

function base64ToBytes(base64: string): Uint8Array {
  const normalized = base64.replace(/-/g, "+").replace(/_/g, "/").replace(/\s/g, "");
  const binary = atob(normalized);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8ArrayBuffer(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "");
  return base64ToBytes(body).slice().buffer as ArrayBuffer;
}

// One access token per isolate; refreshed 60s before expiry.
let _cachedToken: { token: string; expiresAt: number } | null = null;

async function getAccessToken(
  serviceAccount: ServiceAccountKey,
): Promise<string | null> {
  if (_cachedToken && Date.now() < _cachedToken.expiresAt - 60_000) {
    return _cachedToken.token;
  }
  const nowSeconds = Math.floor(Date.now() / 1000);
  const encode = (value: unknown) =>
    bytesToBase64Url(new TextEncoder().encode(JSON.stringify(value)));
  const unsignedJwt = `${encode({ alg: "RS256", typ: "JWT" })}.${encode({
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/cloud-platform",
    aud: OAUTH_TOKEN_ENDPOINT,
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  })}`;
  try {
    const privateKey = await crypto.subtle.importKey(
      "pkcs8",
      pemToPkcs8ArrayBuffer(serviceAccount.private_key),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signature = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      privateKey,
      new TextEncoder().encode(unsignedJwt),
    );
    const res = await fetch(OAUTH_TOKEN_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: `${unsignedJwt}.${bytesToBase64Url(new Uint8Array(signature))}`,
      }),
    });
    if (!res.ok) {
      console.error(
        `[cloud_vision] token exchange HTTP ${res.status}: ${(await res.text()).slice(0, 500)}`,
      );
      return null;
    }
    const data = await res.json();
    if (typeof data.access_token !== "string") {
      console.error("[cloud_vision] token exchange returned no access_token");
      return null;
    }
    _cachedToken = {
      token: data.access_token,
      expiresAt: Date.now() + (typeof data.expires_in === "number" ? data.expires_in * 1000 : 3_600_000),
    };
    return _cachedToken.token;
  } catch (e) {
    console.error(
      `[cloud_vision] token exchange failed: ${e instanceof Error ? e.message : String(e)}`,
    );
    return null;
  }
}

type Likelihood =
  | "UNKNOWN"
  | "VERY_UNLIKELY"
  | "UNLIKELY"
  | "POSSIBLE"
  | "LIKELY"
  | "VERY_LIKELY";

interface CloudVisionRawResponse {
  responses?: Array<{
    faceAnnotations?: Array<{
      fdBoundingPoly?: { vertices?: Array<{ x?: number; y?: number }> };
      detectionConfidence?: number;
    }>;
    textAnnotations?: Array<{
      description?: string;
      boundingPoly?: { vertices?: Array<{ x?: number; y?: number }> };
    }>;
    safeSearchAnnotation?: {
      adult?: Likelihood;
      racy?: Likelihood;
      violence?: Likelihood;
      spoof?: Likelihood;
      medical?: Likelihood;
    };
    error?: { code?: number; message?: string };
  }>;
}

interface NormalizedBox {
  x: number;
  y: number;
  w: number;
  h: number;
  // Raw (unclamped) extents, for edge-touch tolerance checks: a face that
  // merely touches the frame edge is complete; only a box extending well
  // beyond the frame is genuinely cropped.
  rawX: number;
  rawY: number;
  rawW: number;
  rawH: number;
}

interface CloudVisionAnalysis {
  faces: Array<{ box: NormalizedBox; confidence: number }>;
  textBoxes: NormalizedBox[];
  adult: Likelihood;
  racy: Likelihood;
}

export type CloudVisionPrecheck = CloudVisionAnalysis;

const clamp01 = (n: number) => Math.max(0, Math.min(1, n));

function polyToNormalizedBox(
  vertices: Array<{ x?: number; y?: number }> | undefined,
  imgWidth: number,
  imgHeight: number,
): NormalizedBox | null {
  if (!vertices || vertices.length === 0 || !imgWidth || !imgHeight) return null;
  const xs = vertices.map((v) => (typeof v.x === "number" ? v.x : 0));
  const ys = vertices.map((v) => (typeof v.y === "number" ? v.y : 0));
  const rawX = Math.min(...xs) / imgWidth;
  const rawY = Math.min(...ys) / imgHeight;
  const rawW = (Math.max(...xs) - Math.min(...xs)) / imgWidth;
  const rawH = (Math.max(...ys) - Math.min(...ys)) / imgHeight;
  if (!Number.isFinite(rawW) || !Number.isFinite(rawH) || rawW <= 0 || rawH <= 0) return null;
  return {
    x: clamp01(rawX),
    y: clamp01(rawY),
    w: clamp01(rawW),
    h: clamp01(rawH),
    rawX,
    rawY,
    rawW,
    rawH,
  };
}

// Parses intrinsic pixel dimensions from PNG or JPEG bytes so Cloud Vision's
// absolute-pixel bounding polys can be normalized to 0..1. Returns null when
// the format is unrecognized — callers then skip the fallback entirely.
export function getImageDimensions(
  bytes: Uint8Array,
): { width: number; height: number } | null {
  if (bytes.length > 24 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    const width = ((bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19]) >>> 0;
    const height = ((bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23]) >>> 0;
    if (width > 0 && height > 0) return { width, height };
    return null;
  }
  if (bytes.length > 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2;
    while (offset + 9 < bytes.length) {
      if (bytes[offset] !== 0xff) {
        offset++;
        continue;
      }
      const marker = bytes[offset + 1];
      if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        offset += 2;
        continue;
      }
      const segmentLength = ((bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        const height = ((bytes[offset + 5] << 8) | bytes[offset + 6]) >>> 0;
        const width = ((bytes[offset + 7] << 8) | bytes[offset + 8]) >>> 0;
        if (width > 0 && height > 0) return { width, height };
        return null;
      }
      if (segmentLength < 2) return null;
      offset += 2 + segmentLength;
    }
  }
  return null;
}

const LIKELIHOOD_RANK: Record<Likelihood, number> = {
  UNKNOWN: 0,
  VERY_UNLIKELY: 0,
  UNLIKELY: 1,
  POSSIBLE: 2,
  LIKELY: 3,
  VERY_LIKELY: 4,
};

/**
 * Deterministic pre-Gemini gate: one Cloud Vision annotate call combining
 * SafeSearch, FACE_DETECTION and TEXT_DETECTION. Unlike Gemini's model chain
 * this is fast, stable, and — critically for text — script-agnostic: Cloud
 * Vision reads Hebrew, Arabic, Cyrillic, Thai, Greek and 100+ other scripts
 * that on-device ML Kit OCR cannot (ML Kit bundled v2 covers Latin/CJK/
 * Devanagari only). The validators use it to reject explicit content and
 * text/card-over-face photos without a Gemini round-trip. Returns null on any
 * failure (callers continue to Gemini).
 */
export async function cloudVisionContentPrecheck(
  image: { base64: string; width: number | null; height: number | null },
  credential: CloudVisionCredential,
): Promise<CloudVisionPrecheck | null> {
  return analyzeWithCloudVision(
    image.base64,
    image.width,
    image.height,
    credential,
  );
}

/** True when Cloud Vision SafeSearch classifies the image as explicit. */
export function isExplicitLikelihood(adult: Likelihood | undefined): boolean {
  return (LIKELIHOOD_RANK[adult ?? "UNKNOWN"] ?? 0) >= 3;
}

/**
 * True when any text box overlaps the face box enough to be a card/document
 * held over the face (or any occluding text). Intersection is measured
 * against the text box area so large incidental captions don't dominate the
 * verdict, with a minimum text size filter to skip OCR specks.
 */
export function textBoxOverlapsFace(
  face: { x: number; y: number; w: number; h: number },
  textBoxes: Array<{ x: number; y: number; w: number; h: number }>,
): boolean {
  return textBoxes.some((tb) => {
    if (tb.w * tb.h < 0.004) return false;
    const ix = Math.max(0, Math.min(face.x + face.w, tb.x + tb.w) - Math.max(face.x, tb.x));
    const iy = Math.max(0, Math.min(face.y + face.h, tb.y + tb.h) - Math.max(face.y, tb.y));
    const intersection = ix * iy;
    const tbArea = tb.w * tb.h;
    return tbArea > 0 && intersection / tbArea >= 0.25;
  });
}

function sexualContentFromSafeSearch(
  adult: Likelihood | undefined,
  racy: Likelihood | undefined,
): "none" | "suggestive" | "explicit" {
  const adultRank = LIKELIHOOD_RANK[adult ?? "UNKNOWN"] ?? 0;
  const racyRank = LIKELIHOOD_RANK[racy ?? "UNKNOWN"] ?? 0;
  if (adultRank >= 3) return "explicit";
  if (adultRank >= 2 || racyRank >= 3) return "suggestive";
  return "none";
}

async function analyzeWithCloudVision(
  imageBase64: string,
  imgWidth: number | null,
  imgHeight: number | null,
  credential: CloudVisionCredential,
): Promise<CloudVisionAnalysis | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), CLOUD_VISION_TIMEOUT_MS);
  try {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    let url = CLOUD_VISION_ENDPOINT;
    if (credential.kind === "apiKey") {
      url = `${CLOUD_VISION_ENDPOINT}?key=${credential.apiKey}`;
    } else {
      const accessToken = await getAccessToken(credential.serviceAccount);
      if (!accessToken) return null;
      headers["Authorization"] = `Bearer ${accessToken}`;
    }
    const res = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify({
        requests: [{
          image: { content: imageBase64 },
          features: [
            { type: "FACE_DETECTION" },
            { type: "TEXT_DETECTION" },
            { type: "SAFE_SEARCH_DETECTION" },
          ],
        }],
      }),
      signal: controller.signal,
    });
    if (!res.ok) {
      console.error(
        `[cloud_vision] HTTP ${res.status}: ${(await res.text()).slice(0, 500)}`,
      );
      return null;
    }
    const data: CloudVisionRawResponse = await res.json();
    const r = data.responses?.[0];
    if (!r) {
      console.error("[cloud_vision] empty responses array");
      return null;
    }
    if (r.error) {
      console.error(
        `[cloud_vision] annotate error code=${r.error.code} message=${r.error.message}`,
      );
      return null;
    }
    if (imgWidth == null || imgHeight == null) {
      console.error("[cloud_vision] unknown image dimensions, cannot normalize boxes");
      return null;
    }
    const faces = (r.faceAnnotations ?? [])
      .map((face) => ({
        box: polyToNormalizedBox(face.fdBoundingPoly?.vertices, imgWidth, imgHeight),
        confidence: typeof face.detectionConfidence === "number"
          ? face.detectionConfidence
          : 0,
      }))
      .filter((face): face is { box: NormalizedBox; confidence: number } => face.box !== null)
      .sort((a, b) => b.confidence - a.confidence);
    // textAnnotations[0] is the aggregated text of the whole image; entries 1+
    // are individual regions. When only the aggregate exists, use its poly.
    const textAnnotations = r.textAnnotations ?? [];
    const textSources = textAnnotations.length > 1
      ? textAnnotations.slice(1)
      : textAnnotations.slice(0, 1);
    const textBoxes = textSources
      .map((t) => polyToNormalizedBox(t.boundingPoly?.vertices, imgWidth, imgHeight))
      .filter((box): box is NormalizedBox => box !== null);
    return {
      faces,
      textBoxes,
      adult: r.safeSearchAnnotation?.adult ?? "UNKNOWN",
      racy: r.safeSearchAnnotation?.racy ?? "UNKNOWN",
    };
  } catch (e) {
    const isTimeout = e instanceof DOMException && e.name === "AbortError";
    console.error(
      `[cloud_vision] ${isTimeout ? "timeout" : "network"} error: ${e instanceof Error ? e.message : String(e)}`,
    );
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function buildPrimaryDecision(a: CloudVisionAnalysis): Record<string, unknown> | null {
  const sexualContent = sexualContentFromSafeSearch(a.adult, a.racy);
  if (sexualContent !== "none") {
    return {
      action: "REJECT",
      allow: false,
      shotType: "neither",
      reasonCode: "BAD_CONTENT",
      confidence: 0.9,
      message: "Please use an appropriate profile photo.",
      faceBox: null,
      textBoxes: [],
      sexualContent,
    };
  }
  if (a.faces.length === 0) {
    return {
      action: "REJECT",
      allow: false,
      shotType: "neither",
      reasonCode: "NO_PERSON",
      confidence: 0.7,
      message: "No clear face detected. Please use a clear photo of yourself.",
      faceBox: null,
      textBoxes: [],
      sexualContent: "none",
    };
  }
  if (a.faces.length > 1) {
    return {
      action: "REJECT",
      allow: false,
      shotType: "multiple_people",
      reasonCode: "MULTIPLE_PEOPLE",
      confidence: 0.8,
      message: "Please use a photo with only you in it.",
      faceBox: null,
      textBoxes: [],
      sexualContent: "none",
    };
  }
  const face = a.faces[0];
  if (face.confidence < MIN_FACE_DETECTION_CONFIDENCE) {
    return {
      action: "REJECT",
      allow: false,
      shotType: "face",
      reasonCode: "FACE_NOT_VISIBLE",
      confidence: face.confidence,
      message: "Please use a clear photo with your full face visible.",
      faceBox: face.box,
      textBoxes: [],
      sexualContent: "none",
    };
  }
  const box = face.box;
  const faceBoxIsUsable = box.w * box.h >= 0.10 &&
    box.rawX > -0.02 && box.rawY > -0.02 &&
    box.rawX + box.rawW < 1.02 && box.rawY + box.rawH < 1.02;
  if (!faceBoxIsUsable) {
    return {
      action: "REJECT",
      allow: false,
      shotType: "face",
      reasonCode: "FACE_NOT_VISIBLE",
      confidence: face.confidence,
      message: "Please use a clear photo with your full face visible.",
      faceBox: box,
      textBoxes: [],
      sexualContent: "none",
    };
  }
  // Text overlapping the face region is a card/document or occlusion signal:
  // reject outright, never auto-sanitize (mirrors the client prescreen and
  // the Gemini-path geometric guard).
  if (textBoxOverlapsFace(box, a.textBoxes)) {
    return {
      action: "REJECT",
      allow: false,
      shotType: "face",
      reasonCode: "DOCUMENT_DETECTED",
      confidence: face.confidence,
      message: "ID cards and documents are not allowed in photos. Please retake it without covering your face.",
      faceBox: box,
      textBoxes: a.textBoxes,
      sexualContent: "none",
    };
  }
  if (a.textBoxes.length > 0) {
    return {
      action: "SANITIZE",
      allow: false,
      shotType: "face",
      reasonCode: "OK",
      confidence: face.confidence,
      message: "Visible text detected. Please crop to your face.",
      faceBox: box,
      textBoxes: a.textBoxes,
      sexualContent: "none",
    };
  }
  return {
    action: "ALLOW",
    allow: true,
    shotType: "face",
    reasonCode: "OK",
    confidence: face.confidence,
    message: "OK",
    faceBox: box,
    textBoxes: [],
    sexualContent: "none",
  };
}

function buildSecondaryDecision(a: CloudVisionAnalysis): Record<string, unknown> | null {
  const sexualContent = sexualContentFromSafeSearch(a.adult, a.racy);
  const containsFace = a.faces.length > 0;
  const issueBoxes = a.textBoxes.map((box) => ({ ...box, label: "text" }));
  const hasProminentText = a.textBoxes.some((box) => box.w * box.h >= PROMINENT_TEXT_AREA) ||
    issueBoxes.length > PROMINENT_TEXT_MAX_BOXES;
  const confidence = containsFace
    ? Math.max(...a.faces.map((f) => f.confidence))
    : 0.6;

  if (sexualContent !== "none") {
    return {
      allow: false,
      action: "REJECT",
      reasonCode: "BAD_CONTENT",
      containsFace,
      containsBody: false,
      isScreenshot: false,
      isMeme: false,
      hasProminentText: false,
      hasWatermark: false,
      confidence: 0.9,
      message: "Please use an appropriate photo.",
      sexualContent,
      issueBoxes: [],
    };
  }
  if (hasProminentText) {
    return {
      allow: false,
      action: "REJECT",
      reasonCode: "TEXT_SCREENSHOT_OR_WATERMARK",
      containsFace,
      containsBody: containsFace,
      isScreenshot: false,
      isMeme: false,
      hasProminentText: true,
      hasWatermark: false,
      confidence,
      message: "Please use a photo without large text or watermarks.",
      sexualContent: "none",
      issueBoxes,
    };
  }
  if (!containsFace) {
    return {
      allow: false,
      action: "REJECT",
      reasonCode: "NO_FACE_OR_BODY",
      containsFace: false,
      containsBody: false,
      isScreenshot: false,
      isMeme: false,
      hasProminentText: false,
      hasWatermark: false,
      confidence,
      message: "No recognizable person detected in this photo.",
      sexualContent: "none",
      issueBoxes: [],
    };
  }
  return {
    allow: true,
    action: "ALLOW",
    reasonCode: "OK",
    containsFace: true,
    containsBody: true,
    isScreenshot: false,
    isMeme: false,
    hasProminentText: false,
    hasWatermark: false,
    confidence,
    message: "Photo accepted.",
    sexualContent: "none",
    issueBoxes: [],
  };
}

/**
 * Produces the same decision JSON shape the Gemini path returns, so the
 * validate-primary-photo / validate-secondary-photo functions can feed it
 * straight into their existing normalization. Returns null when Cloud Vision
 * is unavailable — callers keep their existing Gemini-unavailable error path.
 */
export async function cloudVisionPhotoDecision(
  kind: "primary" | "secondary",
  image: { base64: string; width: number | null; height: number | null },
  credential: CloudVisionCredential,
): Promise<Record<string, unknown> | null> {
  const analysis = await analyzeWithCloudVision(
    image.base64,
    image.width,
    image.height,
    credential,
  );
  if (!analysis) return null;
  const decision = kind === "primary"
    ? buildPrimaryDecision(analysis)
    : buildSecondaryDecision(analysis);
  if (decision) {
    console.log(
      `[cloud_vision] decision kind=${kind} faces=${analysis.faces.length} textBoxes=${analysis.textBoxes.length} adult=${analysis.adult} racy=${analysis.racy} action=${decision.action ?? decision.allow}`,
    );
  }
  return decision;
}
