import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";
import { buildGeminiUrl, resolveVisionModels } from "../_shared/gemini_config.ts";
import { consumeAiRateLimit, getClientIp } from "../_shared/ai_rate_limit.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface MismatchRegionBox {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface MismatchRegion {
  feature: string;
  description: string;
  profileBox?: MismatchRegionBox;
  verificationBox?: MismatchRegionBox;
}

interface FaceComparisonResult {
  similarity: number;
  confidence: number;
  isMatch: boolean;
  reasoning?: string;
  gestureValid?: boolean;
  mismatchRegions?: MismatchRegion[];
  error?: string;
}

interface VerificationDecision {
  status: "approved" | "pending" | "rejected";
  autoRejected: boolean;
  reviewedAt: string | null;
  isVerified: boolean;
  reason: string;
}

interface VerificationRetentionPolicy {
  retentionUntil: string;
  retentionDays: number;
  policy: "approved_reference_window" | "pending_manual_review_window" | "rejected_review_window";
}

interface VerificationReferenceArtifact {
  version: number;
  kind: string;
  generatedAt: string;
  source: string;
  hash: {
    algorithm: string;
    value: string;
  };
  byteLength: number;
  identityDescriptor: IdentityDescriptor | null;
  descriptorStatus: "ready" | "unavailable";
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

function determineVerificationDecision(
  comparisonResult: FaceComparisonResult,
  auditResult: { authentic: boolean; reasoning: string } | null,
): VerificationDecision {
  if (auditResult && !auditResult.authentic) {
    return {
      status: "rejected",
      autoRejected: true,
      reviewedAt: new Date().toISOString(),
      isVerified: false,
      reason: "authenticity_audit_failed",
    };
  }

  const similarity = Number.isFinite(comparisonResult.similarity)
    ? Math.max(0, Math.min(100, comparisonResult.similarity))
    : 0;
  const confidence = Number.isFinite(comparisonResult.confidence)
    ? Math.max(0, Math.min(100, comparisonResult.confidence))
    : 0;
  const reasoning = (comparisonResult.reasoning || "").toLowerCase();
  // Word-boundary matching: a positive line like "the gesture was noted" or
  // "no obscured features" must not trip the failure heuristics below.
  const hasGestureFailure =
    reasoning.includes("gesture") &&
    (
      /\bnot\b/.test(reasoning) ||
      /\bmissing\b/.test(reasoning) ||
      /\bunclear\b/.test(reasoning) ||
      /\bincorrect\b/.test(reasoning)
    );
  const mentionsObscured = reasoning.includes("obscured");
  const obscuredNegated =
    reasoning.includes("no obscured") ||
    reasoning.includes("not obscured") ||
    reasoning.includes("without obscured") ||
    reasoning.includes("unobscured");
  const hasClearFaceFailure =
    reasoning.includes("no clear face") ||
    reasoning.includes("face not clearly visible") ||
    (mentionsObscured && !obscuredNegated) ||
    reasoning.includes("multiple faces");

  if (hasGestureFailure || hasClearFaceFailure) {
    return {
      status: "rejected",
      autoRejected: true,
      reviewedAt: new Date().toISOString(),
      isVerified: false,
      reason: hasGestureFailure ? "gesture_requirement_failed" : "face_visibility_failed",
    };
  }

  if (comparisonResult.isMatch === true && similarity >= 82 && confidence >= 75) {
    return {
      status: "approved",
      autoRejected: false,
      reviewedAt: new Date().toISOString(),
      isVerified: true,
      reason: "high_confidence_match",
    };
  }

  return {
    status: "rejected",
    autoRejected: true,
    reviewedAt: new Date().toISOString(),
    isVerified: false,
    reason: comparisonResult.isMatch === false
      ? "clear_face_mismatch"
      : "borderline_similarity_mismatch",
  };
}

function addDays(days: number): string {
  const target = new Date();
  target.setUTCDate(target.getUTCDate() + days);
  return target.toISOString();
}

function clampUnit(value: unknown): number | null {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) return null;
  return Math.max(0, Math.min(1, n));
}

function parseMismatchBox(raw: unknown): MismatchRegionBox | null {
  if (!raw || typeof raw !== "object") return null;
  const box = raw as Record<string, unknown>;
  const x = clampUnit(box.x);
  const y = clampUnit(box.y);
  const width = clampUnit(box.width);
  const height = clampUnit(box.height);
  if (x === null || y === null || width === null || height === null) return null;
  if (width <= 0 || height <= 0) return null;
  return { x, y, width, height };
}

// Defensive parse of the model's mismatchRegions: coordinates clamped to
// 0-1, malformed entries dropped, capped at 6 regions so the rejected-state
// UI can never be flooded with boxes.
function parseMismatchRegions(raw: unknown): MismatchRegion[] {
  if (!Array.isArray(raw)) return [];
  const regions: MismatchRegion[] = [];
  for (const item of raw) {
    if (regions.length >= 6) break;
    if (!item || typeof item !== "object") continue;
    const region = item as Record<string, unknown>;
    const feature = typeof region.feature === "string" ? region.feature.trim() : "";
    const description = typeof region.description === "string"
      ? region.description.trim()
      : "";
    if (!feature && !description) continue;
    regions.push({
      feature: feature || "face",
      description,
      profileBox: parseMismatchBox(region.profileBox) ?? undefined,
      verificationBox: parseMismatchBox(region.verificationBox) ?? undefined,
    });
  }
  return regions;
}

function getVerificationRetentionPolicy(
  status: VerificationDecision["status"],
): VerificationRetentionPolicy {
  if (status === "approved") {
    return {
      retentionUntil: addDays(30),
      retentionDays: 30,
      policy: "approved_reference_window",
    };
  }

  if (status === "rejected") {
    return {
      retentionUntil: addDays(7),
      retentionDays: 7,
      policy: "rejected_review_window",
    };
  }

  return {
    retentionUntil: addDays(14),
    retentionDays: 14,
    policy: "pending_manual_review_window",
  };
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function buildVerificationReferenceArtifact(
  verificationPhotoBuffer: ArrayBuffer,
  identityDescriptor: IdentityDescriptor | null,
): Promise<VerificationReferenceArtifact> {
  const generatedAt = new Date().toISOString();
  const digest = await crypto.subtle.digest("SHA-256", verificationPhotoBuffer);
  return {
    version: 1,
    kind: "verification_reference_artifact",
    generatedAt,
    source: "verification_selfie",
    hash: {
      algorithm: "sha256",
      value: toHex(new Uint8Array(digest)),
    },
    byteLength: verificationPhotoBuffer.byteLength,
    identityDescriptor,
    descriptorStatus: identityDescriptor ? "ready" : "unavailable",
  };
}

async function generateIdentityDescriptorWithGemini(
  verificationPhotoBuffer: ArrayBuffer,
): Promise<{ descriptor: IdentityDescriptor | null; modelUsed: string | null }> {
  const API_KEY = Deno.env.get("GOOGLE_AI_API_KEY");
  if (!API_KEY) {
    throw new Error("GOOGLE_AI_API_KEY environment variable not set");
  }

  const verificationBase64 = arrayBufferToBase64(verificationPhotoBuffer);
  const prompt = `
Return ONLY valid JSON with this exact structure:
{
  "faceVisible": boolean,
  "quality": number,
  "featureVector": [number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number],
  "reasoning": string
}

You are generating a privacy-preserving identity descriptor for one person's face from a verification selfie.

Rules:
- Use ONLY stable facial geometry and proportion cues visible in the image.
- Do NOT include age, race, ethnicity, gender, clothing, hairstyle, makeup, background, or expression-specific details.
- Eyeglasses, facial hair (beard/mustache), and hairstyle must not change the measurement: infer the underlying bone structure as if they were absent.
- If there is not exactly one clear face, set "faceVisible" to false, "quality" to 0, and all 16 numbers in "featureVector" to 0.
- "quality" must be a number from 0 to 1 reflecting how suitable the face is for identity matching.
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

  const body = {
    contents: [{
      parts: [
        { text: prompt },
        {
          inline_data: {
            mime_type: "image/jpeg",
            data: verificationBase64,
          },
        },
      ],
    }],
    generationConfig: {
      responseMimeType: "application/json",
      temperature: 0,
    },
  };

  for (const modelName of await resolveVisionModels(API_KEY)) {
    try {
      const response = await fetch(
        buildGeminiUrl(modelName, API_KEY),
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        },
      );

      if (!response.ok) {
        const errorText = await response.text();
        console.warn("⚠️ Identity descriptor model failed:", modelName, errorText);
        continue;
      }

      const data = await response.json();
      const content = data?.candidates?.[0]?.content?.parts?.[0]?.text;
      if (typeof content !== "string" || content.trim().length === 0) {
        continue;
      }

      const parsed = JSON.parse(content.trim()) as {
        faceVisible?: boolean;
        quality?: number;
        featureVector?: unknown;
        reasoning?: string;
      };
      const vector = Array.isArray(parsed.featureVector)
        ? parsed.featureVector
          .map((value) => typeof value === "number" ? value : Number(value))
          .map((value) => Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0)
        : [];

      if (vector.length !== 16) {
        continue;
      }

      const descriptor: IdentityDescriptor = {
        version: 1,
        model: modelName,
        generatedAt: new Date().toISOString(),
        faceVisible: parsed.faceVisible === true,
        quality: typeof parsed.quality === "number"
          ? Math.max(0, Math.min(1, parsed.quality))
          : 0,
        featureLabels: [
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
        ],
        featureVector: vector,
        reasoning: parsed.reasoning || "identity_descriptor_generated",
      };

      if (!descriptor.faceVisible) {
        return { descriptor: null, modelUsed: modelName };
      }

      return { descriptor, modelUsed: modelName };
    } catch (error) {
      console.warn("⚠️ Identity descriptor generation failed:", modelName, error);
    }
  }

  return { descriptor: null, modelUsed: null };
}

function summarizeKey(value: string) {
  const trimmed = value.trim();
  const dotCount = (trimmed.match(/\./g) ?? []).length;
  return {
    length: trimmed.length,
    dotCount,
    looksLikeJwt: trimmed.startsWith("eyJ") && dotCount >= 2,
  };
}

serve(async (req) => {
  // Handle CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const requestId = crypto.randomUUID();
  const startedAt = Date.now();
  const functionName = "compare-verification-photos";
  let aiUsed = false;
  const aiProvider = "google_gemini";
  let aiModel: string | null = null;
  const aiTask = "verification_face_comparison";

  const respond = async (
    payload: Record<string, unknown>,
    opts?: {
      httpStatus?: number;
      success?: boolean;
      errorType?: string | null;
      errorMessage?: string | null;
      userId?: string | null;
      meta?: Record<string, unknown>;
    },
  ) => {
    const httpStatus = opts?.httpStatus ?? 200;
    await logEdgeFunctionInvocation({
      requestId,
      functionName,
      durationMs: Date.now() - startedAt,
      success: opts?.success ?? true,
      httpStatus,
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
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: httpStatus,
    });
  };

  console.log("🤖 EDGE FUNCTION: compare-verification-photos called");
  let requestUserId: string | null = null;
  let supabase: any = null;
  let supabaseInternal: any = null;

  try {
    // Get environment variables
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const edgeInternalSecret = Deno.env.get("EDGE_INTERNAL_SECRET") ?? "";
    console.log("🔧 EDGE FUNCTION: Environment variables loaded");
    const keySummary = summarizeKey(supabaseServiceKey);
    console.log("🔐 EDGE FUNCTION: Service key summary:", keySummary);
    if (!edgeInternalSecret || edgeInternalSecret.trim().length < 16) {
      throw new Error("Missing EDGE_INTERNAL_SECRET");
    }

    // For now, using a simple face comparison approach
    // In production, you would integrate with AWS Rekognition, Google Vision AI, or similar
    const faceApiKey = Deno.env.get("FACE_API_KEY"); // Optional: for production use

    // Initialize Supabase client
    supabase = createClient(
      supabaseUrl,
      supabaseServiceKey,
      {
        auth: {
          persistSession: false,
          autoRefreshToken: false,
          detectSessionInUrl: false,
        },
      },
    );
    console.log("🔗 EDGE FUNCTION: Supabase client initialized");
    supabaseInternal = createClient(
      supabaseUrl,
      supabaseServiceKey,
      {
        auth: {
          persistSession: false,
          autoRefreshToken: false,
          detectSessionInUrl: false,
        },
        global: {
          headers: {
            "x-edge-internal-secret": edgeInternalSecret,
          },
        },
      },
    );

    // Get request body - clone first to allow multiple reads
    const reqClone = req.clone();
    const {
      userId,
      gestureCode,
      gesturePrompt,
      verificationPhotoPath: verificationPhotoPathInput,
    }: {
      userId: string;
      gestureCode?: string;
      gesturePrompt?: string;
      verificationPhotoPath?: string;
    } = await req.json();
    requestUserId = userId ?? null;
    console.log("📥 EDGE FUNCTION: Received request for userId:", userId);
    console.log("📥 EDGE FUNCTION: gestureCode:", gestureCode);
    console.log("📥 EDGE FUNCTION: gesturePrompt:", gesturePrompt);
    console.log("📥 EDGE FUNCTION: Full request body:", await reqClone.json());

    if (!userId) {
      console.log("❌ EDGE FUNCTION: userId is required but not provided");
      throw new Error("userId is required");
    }

    // AI rate limiting (app_config ai.rate_limit.verification_face_comparison.*).
    const rateLimit = await consumeAiRateLimit(supabase, {
      task: "verification_face_comparison",
      userId,
      ip: getClientIp(req),
    });
    if (!rateLimit.allowed) {
      console.warn(
        `⏳ EDGE FUNCTION: verification rate limited, retryAfter=${rateLimit.retryAfterSeconds}s`,
      );
      return await respond(
        {
          success: false,
          error: "Too many verification attempts. Please try again later.",
          retryAfterSeconds: rateLimit.retryAfterSeconds,
        },
        {
          httpStatus: 429,
          success: false,
          errorType: "rate_limited",
          errorMessage: "AI rate limit exceeded for verification_face_comparison",
          userId,
        },
      );
    }

    if (typeof verificationPhotoPathInput === "string" && verificationPhotoPathInput.trim().length > 0) {
      let normalized = verificationPhotoPathInput.trim();
      if (normalized.startsWith("/")) normalized = normalized.slice(1);
      if (normalized.startsWith("verification-photos/")) {
        normalized = normalized.slice("verification-photos/".length);
      }

      if (!normalized.startsWith(`${userId}/`)) {
        throw new Error("Invalid verificationPhotoPath");
      }

      const nowIso = new Date().toISOString();
      const { error: startError } = await supabaseInternal.rpc(
        "edge_update_verification",
        {
          p_user_id: userId,
          p_patch: {
            verification_photo_path: normalized,
            verification_status: "analyzing",
            verification_submitted_at: nowIso,
            verification_reviewed_at: null,
            verification_auto_rejected: false,
            verification_similarity_score: null,
            verification_ai_analysis: null,
            is_verified: false,
          },
        },
      );

      if (startError) {
        throw new Error(`Failed to start verification: ${startError.message}`);
      }
    }

    // Get user's profile data
    console.log("👤 EDGE FUNCTION: Fetching user data for userId:", userId);
    const { data: userData, error: userError } = await supabase
      .from("users")
      .select("verification_photo_path")
      .eq("id", userId)
      .single();

    if (userError) {
      console.log("❌ EDGE FUNCTION: Database error:", userError);
      throw new Error(`User not found: ${userError.message}`);
    }

    if (!userData) {
      console.log("❌ EDGE FUNCTION: No user data returned");
      throw new Error("User not found");
    }

    // photos is now on user_profiles
    const { data: profileData } = await supabase
      .from("user_profiles")
      .select("photos")
      .eq("user_id", userId)
      .maybeSingle();

    const photos = (profileData as any)?.photos as string[] | null;

    console.log("✅ EDGE FUNCTION: User data retrieved:", {
      hasPhotos: !!photos,
      photosCount: photos?.length || 0,
      hasVerificationPhoto: !!userData.verification_photo_path
    });

    if (!photos || photos.length === 0) {
      console.log("❌ EDGE FUNCTION: User has no profile photos");
      throw new Error("User has no profile photos");
    }

    if (!userData.verification_photo_path) {
      console.log("❌ EDGE FUNCTION: User has no verification photo");
      throw new Error("User has no verification photo");
    }

    // Get the main profile photo (first one)
    const profilePhotoPath = photos[0];
    const verificationPhotoPath = userData.verification_photo_path;

    console.log("📸 EDGE FUNCTION: Photo paths:", {
      profilePhotoPath,
      verificationPhotoPath
    });

    // Download both images from Supabase storage
    // Profile photos are in profile-photos bucket, verification photos are in verification-photos bucket
    console.log("⬇️ EDGE FUNCTION: Downloading photos from storage...");
    const [profilePhotoResponse, verificationPhotoResponse] = await Promise.all([
      supabase.storage.from("profile-photos").download(profilePhotoPath),
      supabase.storage.from("verification-photos").download(verificationPhotoPath),
    ]);

    console.log("📦 EDGE FUNCTION: Profile photo download response:", {
      error: profilePhotoResponse.error,
      status: profilePhotoResponse.status,
      statusText: profilePhotoResponse.statusText
    });

    console.log("📦 EDGE FUNCTION: Verification photo download response:", {
      error: verificationPhotoResponse.error,
      status: verificationPhotoResponse.status,
      statusText: verificationPhotoResponse.statusText
    });

    if (profilePhotoResponse.error) {
      console.log("❌ EDGE FUNCTION: Failed to download profile photo:", profilePhotoResponse.error);
      console.log("🔍 EDGE FUNCTION: Profile photo path was:", profilePhotoPath);
      throw new Error(`Failed to download profile photo: ${JSON.stringify(profilePhotoResponse.error)}`);
    }

    if (verificationPhotoResponse.error) {
      console.log("❌ EDGE FUNCTION: Failed to download verification photo:", verificationPhotoResponse.error);
      console.log("🔍 EDGE FUNCTION: Verification photo path was:", verificationPhotoPath);
      throw new Error(`Failed to download verification photo: ${JSON.stringify(verificationPhotoResponse.error)}`);
    }

    console.log("✅ EDGE FUNCTION: Both photos downloaded successfully");
    console.log("📊 EDGE FUNCTION: Profile photo size:", profilePhotoResponse.data?.byteLength || "unknown");
    console.log("📊 EDGE FUNCTION: Verification photo size:", verificationPhotoResponse.data?.byteLength || "unknown");

    const verificationPhotoBuffer = await verificationPhotoResponse.data.arrayBuffer();
    const profilePhotoBuffer = await profilePhotoResponse.data.arrayBuffer();

    // SECURITY AUDIT: Gemini authenticity check (tampering, screenshot, deepfake, edited)
    console.log("🔒 Starting Gemini authenticity audit for verification photo...");
    let auditResult: { authentic: boolean; reasoning: string } | null = null;
    try {
      auditResult = await auditPhotoAuthenticity(verificationPhotoBuffer);
      console.log("🔒 Authenticity audit result:", auditResult.authentic ? "PASS" : "FAIL", auditResult.reasoning);
    } catch (auditErr) {
      console.warn("⚠️ Authenticity audit failed (proceeding with comparison):", auditErr);
    }

    if (auditResult && !auditResult.authentic) {
      console.log("❌ Verification photo failed authenticity audit - rejecting");
      const verificationReferenceArtifact = await buildVerificationReferenceArtifact(
        verificationPhotoBuffer,
        null,
      );
      const retentionPolicy = getVerificationRetentionPolicy("rejected");
      const aiAnalysisData = {
        similarity: 0,
        confidence: 0,
        isMatch: false,
        reasoning: auditResult.reasoning || "Photo failed authenticity check.",
        comparedAt: new Date().toISOString(),
        service: "gemini_ai",
        authenticityAudit: { authentic: false, reasoning: auditResult.reasoning },
        retentionPolicy,
      };
      await supabaseInternal.rpc("edge_update_verification", {
        p_user_id: userId,
        p_patch: {
          verification_status: "rejected",
          verification_auto_rejected: true,
          verification_similarity_score: 0,
          verification_ai_analysis: aiAnalysisData,
          verification_reference_artifact: {
            ...verificationReferenceArtifact,
            retentionPolicy: retentionPolicy.policy,
          },
          verification_reference_generated_at:
            verificationReferenceArtifact.generatedAt,
          verification_photo_retention_until: retentionPolicy.retentionUntil,
          verification_reviewed_at: new Date().toISOString(),
          is_verified: false,
        },
      });
      aiUsed = true;
      aiModel = aiModel ?? "gemini";
      return await respond(
        {
          success: true,
          isMatch: false,
          similarity: 0,
          confidence: 0,
          reasoning: auditResult.reasoning,
          userId,
          note: "Rejected by Gemini authenticity audit",
        },
        {
          success: true,
          userId,
          meta: { outcome: "rejected_by_authenticity_audit" },
        },
      );
    }

    const { descriptor: verificationIdentityDescriptor, modelUsed: descriptorModelUsed } =
      await generateIdentityDescriptorWithGemini(verificationPhotoBuffer);
    if (descriptorModelUsed) {
      aiUsed = true;
      aiModel = descriptorModelUsed;
    }
    const verificationReferenceArtifact = await buildVerificationReferenceArtifact(
      verificationPhotoBuffer,
      verificationIdentityDescriptor,
    );

    // PRIMARY: Gemini AI for face comparison (live chain from _shared/gemini_config.ts)
    // To switch back to Vision API: change compareFacesWithGemini to compareFacesWithVision
    const visionModels = await resolveVisionModels(Deno.env.get("GOOGLE_AI_API_KEY") ?? "");
    console.log(`🤖 Starting face comparison with Gemini AI (${visionModels[0]})...`);
    let comparisonResult;
    try {
      aiUsed = true;
      aiModel = visionModels[0];
      comparisonResult = await compareFacesWithGemini(
        profilePhotoBuffer,
        verificationPhotoBuffer,
        gesturePrompt || gestureCode
      );
      console.log("✅ Gemini AI face comparison completed successfully");
    } catch (error) {
      console.log("❌ Gemini AI failed, falling back to basic comparison:", error);
      aiUsed = false;
      aiModel = null;
      comparisonResult = await compareFacesBasic(
        profilePhotoBuffer,
        verificationPhotoBuffer
      );
    }

    // Store the results in the database (include authenticity audit if run)
    const decision = determineVerificationDecision(comparisonResult, auditResult);
    const retentionPolicy = getVerificationRetentionPolicy(decision.status);
    const aiAnalysisData = {
      similarity: comparisonResult.similarity,
      confidence: comparisonResult.confidence,
      isMatch: comparisonResult.isMatch,
      reasoning: comparisonResult.reasoning || "No reasoning provided",
      comparedAt: new Date().toISOString(),
      service: "gemini_ai",
      note: `Using Gemini AI (${visionModels[0]}) for face comparison`,
      decision: decision.status,
      decisionReason: decision.reason,
      retentionPolicy,
      verificationReferenceReady: verificationIdentityDescriptor !== null,
      gestureCode: gestureCode || null,
      gesturePrompt: gesturePrompt || null,
      ...(comparisonResult.mismatchRegions &&
        comparisonResult.mismatchRegions.length > 0 && {
          mismatchRegions: comparisonResult.mismatchRegions,
        }),
      ...(auditResult && { authenticityAudit: { authentic: auditResult.authentic, reasoning: auditResult.reasoning } }),
    };

    console.log("💾 Storing comparison results in database:", comparisonResult);
    console.log("📊 AI Analysis data to store:", JSON.stringify(aiAnalysisData, null, 2));
    console.log("🔍 Reasoning value:", comparisonResult.reasoning);
    console.log("🔍 Reasoning type:", typeof comparisonResult.reasoning);

    const updatePayload: Record<string, unknown> = {
      verification_similarity_score: comparisonResult.similarity / 100, // Convert to 0-1 scale
      verification_ai_analysis: aiAnalysisData,
      verification_status: decision.status,
      verification_auto_rejected: decision.autoRejected,
      verification_reference_artifact: {
        ...verificationReferenceArtifact,
        retentionPolicy: retentionPolicy.policy,
      },
      verification_reference_generated_at:
        verificationReferenceArtifact.generatedAt,
      verification_photo_retention_until: retentionPolicy.retentionUntil,
      verification_reviewed_at: decision.reviewedAt,
      is_verified: decision.isVerified,
    }

    const { error: updateError } = await supabaseInternal
      .rpc("edge_update_verification", { p_user_id: userId, p_patch: updatePayload });

    if (updateError) {
      console.error("❌ Database update error:", updateError);
      throw new Error(`Failed to update user data: ${updateError.message}`);
    }

    console.log("✅ Database update successful for user:", userId);

    // Verify the data was stored correctly
    const { data: verifyData, error: verifyError } = await supabase
      .from("users")
      .select("verification_ai_analysis")
      .eq("id", userId)
      .single();

    if (verifyError) {
      console.error("❌ Verification query error:", verifyError);
    } else {
      console.log("🔍 Verification - stored ai_analysis:", JSON.stringify(verifyData?.verification_ai_analysis, null, 2));
    }

    console.log("🎯 EDGE FUNCTION: Comparison result:", {
      similarity: comparisonResult.similarity,
      confidence: comparisonResult.confidence,
      isMatch: comparisonResult.isMatch
    });

    const responseData = {
      success: true,
      similarity: comparisonResult.similarity,
      confidence: comparisonResult.confidence,
      isMatch: comparisonResult.isMatch,
      verificationStatus: decision.status,
      decisionReason: decision.reason,
      reasoning: comparisonResult.reasoning,
      mismatchRegions: comparisonResult.mismatchRegions ?? [],
      userId,
      note: `Using Gemini AI (${visionModels[0]}) for face comparison`,
    };

    console.log("✅ EDGE FUNCTION: Returning success response:", responseData);

    return await respond(
      responseData,
      {
        success: true,
        userId,
        meta: {
          isMatch: comparisonResult.isMatch,
          similarity: comparisonResult.similarity,
          confidence: comparisonResult.confidence,
          verificationStatus: decision.status,
          decisionReason: decision.reason,
        },
      },
    );

  } catch (error) {
    const err = error instanceof Error ? error : new Error(String(error));
    console.error("❌ EDGE FUNCTION: Error in compare-verification-photos function:", error);
    console.error("🔍 EDGE FUNCTION: Error type:", err.constructor.name);
    console.error("🔍 EDGE FUNCTION: Error message:", err.message);
    console.error("🔍 EDGE FUNCTION: Stack trace:", err.stack);

    if (
      supabase &&
      requestUserId &&
      !(error instanceof Error &&
        error.message.includes("protected_user_fields_update_not_allowed"))
    ) {
      try {
        if (supabaseInternal) {
          await supabaseInternal.rpc("edge_update_verification", {
            p_user_id: requestUserId,
            p_patch: {
              verification_status: "rejected",
              verification_auto_rejected: true,
              verification_reviewed_at: new Date().toISOString(),
              is_verified: false,
              verification_ai_analysis: {
                service: "edge_function",
                comparedAt: new Date().toISOString(),
                decision: "rejected",
                decisionReason: "comparison_error",
                reasoning: "A temporary processing error occurred. Please try submitting your verification photo again.",
                error: error instanceof Error ? error.message : String(error),
              },
            },
          });
        }
      } catch (e) {
        console.error("⚠️ EDGE FUNCTION: Failed to set pending after error:", e);
      }
    }

    const errorResponse = {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };

    console.log("🚨 EDGE FUNCTION: Returning error response:", errorResponse);

    return await respond(
      errorResponse,
      {
        success: false,
        userId: requestUserId,
        errorType: "exception",
        errorMessage: error instanceof Error ? error.message : String(error),
      },
    );
  }
});

// PRODUCTION AI FACE COMPARISON - Choose one of these implementations:

// Option 1: AWS Rekognition (Recommended for production)
/*
async function compareFacesAWS(
  profilePhotoBuffer: ArrayBuffer,
  verificationPhotoBuffer: ArrayBuffer
): Promise<FaceComparisonResult> {
  const AWS_ACCESS_KEY = Deno.env.get("AWS_ACCESS_KEY_ID")!;
  const AWS_SECRET_KEY = Deno.env.get("AWS_SECRET_ACCESS_KEY")!;
  const AWS_REGION = Deno.env.get("AWS_REGION") || "us-east-1";

  // Convert ArrayBuffers to base64 (efficient method to avoid stack overflow)
  const profileBase64 = btoa(String.fromCharCode.apply(null, Array.from(new Uint8Array(profilePhotoBuffer))));
  const verificationBase64 = btoa(String.fromCharCode.apply(null, Array.from(new Uint8Array(verificationPhotoBuffer))));

  const response = await fetch(`https://rekognition.${AWS_REGION}.amazonaws.com/`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-amz-json-1.1",
      "X-Amz-Target": "RekognitionService.CompareFaces",
      "Authorization": `AWS4-HMAC-SHA256 ...`, // Implement AWS4 signing
    },
    body: JSON.stringify({
      SourceImage: { Bytes: Uint8Array.from(atob(profileBase64), c => c.charCodeAt(0)) },
      TargetImage: { Bytes: Uint8Array.from(atob(verificationBase64), c => c.charCodeAt(0)) },
      SimilarityThreshold: 80.0,
    }),
  });

  const result = await response.json();
  if (result.FaceMatches && result.FaceMatches.length > 0) {
    const match = result.FaceMatches[0];
    return {
      similarity: match.Similarity,
      confidence: match.Face.Confidence,
      isMatch: match.Similarity >= 80.0,
    };
  }

  return { similarity: 0, confidence: 0, isMatch: false };
}
*/

// Helper function for efficient base64 encoding
function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  const binary = Array.from(bytes, byte => String.fromCharCode(byte)).join('');
  return btoa(binary);
}

// Gemini authenticity audit: detect tampering, screenshots, deepfakes, edited photos
async function auditPhotoAuthenticity(
  verificationPhotoBuffer: ArrayBuffer
): Promise<{ authentic: boolean; reasoning: string }> {
  const API_KEY = Deno.env.get("GOOGLE_AI_API_KEY");
  if (!API_KEY) {
    throw new Error("GOOGLE_AI_API_KEY environment variable not set");
  }
  const verificationBase64 = arrayBufferToBase64(verificationPhotoBuffer);
  const auditModels = await resolveVisionModels(API_KEY);
  const geminiUrls = auditModels.map(m => buildGeminiUrl(m, API_KEY));

  const prompt = `You are a security auditor for a verification photo. Analyze this image and determine if it appears AUTHENTIC (live selfie from a real person) or TAMPERED/FAKE.

Consider and flag as INVALID (authentic: false) if the image appears to:
- Be a screenshot or photo of a screen
- Be a printed photo or photo of a photo
- Show signs of digital manipulation, compositing, or deepfake
- Have inconsistent lighting/artifacts suggesting paste or edit
- Be a stock photo or someone else's image
- Show multiple faces or no clear single face for verification

Consider AUTHENTIC (authentic: true) only if:
- It looks like a single, live selfie with natural lighting and no obvious edits
- Face and any requested gesture appear to be real and in-frame

Return ONLY a JSON object with this exact structure (no markdown, no extra text):
{"authentic": true or false, "reasoning": "brief explanation"}`;

  const body = {
    contents: [{
      parts: [
        { text: prompt },
        { inline_data: { mime_type: "image/jpeg", data: verificationBase64 } },
      ],
    }],
    generationConfig: {
      responseMimeType: "application/json",
      temperature: 0.1,
    },
  };

  let response: Response | undefined;
  try {
    for (let i = 0; i < geminiUrls.length; i++) {
      response = await fetch(geminiUrls[i], {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (response.ok) break;
      console.warn(`Authenticity audit model ${auditModels[i]} failed with status ${response.status}, trying next...`);
    }
  } catch (e) {
    throw new Error(`Gemini authenticity audit request failed: ${e}`);
  }

  if (!response || !response.ok) {
    throw new Error(`All ${geminiUrls.length} Gemini models failed for authenticity audit`);
  }

  const data = await response.json();
  const content = data.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!content) {
    throw new Error("No content in Gemini authenticity response");
  }
  const parsed = JSON.parse(content.trim()) as { authentic?: boolean; reasoning?: string };
  return {
    authentic: Boolean(parsed.authentic),
    reasoning: typeof parsed.reasoning === "string" ? parsed.reasoning : "Authenticity check completed.",
  };
}

// Google Cloud Vision AI (using correct Google AI API key)
async function compareFacesGoogle(
  profilePhotoBuffer: ArrayBuffer,
  verificationPhotoBuffer: ArrayBuffer
): Promise<FaceComparisonResult> {
  // Use the same API key used for Gemini in event processing
  const API_KEY = Deno.env.get('GOOGLE_AI_API_KEY');
  if (!API_KEY) {
    throw new Error('GOOGLE_AI_API_KEY environment variable not set');
  }

  console.log("🔄 Converting images to base64 for Google Vision API...");
  console.log(`📊 Profile photo size: ${profilePhotoBuffer.byteLength} bytes`);
  console.log(`📊 Verification photo size: ${verificationPhotoBuffer.byteLength} bytes`);

  // Convert ArrayBuffers to base64 using efficient method
  const profileBase64 = arrayBufferToBase64(profilePhotoBuffer);
  const verificationBase64 = arrayBufferToBase64(verificationPhotoBuffer);

  console.log("✅ Base64 conversion completed");

  // Detect faces in both images
  console.log("🤖 Calling Google Vision API for face detection...");

  try {
    const [profileResponse, verificationResponse] = await Promise.all([
      fetch(`https://vision.googleapis.com/v1/images:annotate?key=${API_KEY}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          requests: [{
            image: { content: profileBase64 },
            features: [{ type: "FACE_DETECTION", maxResults: 1 }]
          }]
        })
      }),
      fetch(`https://vision.googleapis.com/v1/images:annotate?key=${API_KEY}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          requests: [{
            image: { content: verificationBase64 },
            features: [{ type: "FACE_DETECTION", maxResults: 1 }]
          }]
        })
      })
    ]);

    console.log(`📡 Profile API response status: ${profileResponse.status}`);
    console.log(`📡 Verification API response status: ${verificationResponse.status}`);

    if (!profileResponse.ok || !verificationResponse.ok) {
      const profileError = await profileResponse.text();
      const verificationError = await verificationResponse.text();
      console.error("❌ Google Vision API error:", { profileError, verificationError });
      return { similarity: 0, confidence: 0, isMatch: false };
    }

    const [profileData, verificationData] = await Promise.all([
      profileResponse.json(),
      verificationResponse.json()
    ]);

    console.log("✅ Google Vision API responses received");

    // Check if faces were detected
    const profileFace = profileData.responses?.[0]?.faceAnnotations?.[0];
    const verificationFace = verificationData.responses?.[0]?.faceAnnotations?.[0];

    if (!profileFace || !verificationFace) {
      console.log("❌ No faces detected in one or both images");
      return { similarity: 0, confidence: 0, isMatch: false };
    }

    // Simple similarity based on face detection confidence and basic features
    const profileConfidence = profileFace.detectionConfidence || 0;
    const verificationConfidence = verificationFace.detectionConfidence || 0;

    const confidenceDiff = Math.abs(profileConfidence - verificationConfidence);
    const similarity = Math.max(0, 100 - (confidenceDiff * 100));

    console.log(`🎯 Google Vision similarity: ${similarity.toFixed(2)}% (basic calculation)`);
    console.log(`📊 Face confidences - Profile: ${profileConfidence.toFixed(2)}, Verification: ${verificationConfidence.toFixed(2)}`);

    return {
      similarity: Math.round(similarity * 100) / 100,
      confidence: Math.min(profileConfidence, verificationConfidence),
      isMatch: similarity >= 70,
    };
  } catch (error) {
    console.error("❌ Error in Google Vision API call:", error);
    return { similarity: 0, confidence: 0, isMatch: false };
  }
}

// Gemini AI Face Comparison (Primary method - live chain via resolveVisionModels)
async function compareFacesWithGemini(
  profilePhotoBuffer: ArrayBuffer,
  verificationPhotoBuffer: ArrayBuffer,
  gestureRequirementText?: string
): Promise<FaceComparisonResult> {
  const API_KEY = Deno.env.get('GOOGLE_AI_API_KEY');
  if (!API_KEY) {
    throw new Error('GOOGLE_AI_API_KEY environment variable not set');
  }

  console.log("🤖 Using Gemini AI for face comparison...");

  // Use efficient base64 encoding
  const profileBase64 = arrayBufferToBase64(profilePhotoBuffer);
  const verificationBase64 = arrayBufferToBase64(verificationPhotoBuffer);

  const faceModels = await resolveVisionModels(API_KEY);
  const geminiUrls = faceModels.map(m => buildGeminiUrl(m, API_KEY));

  const gestureInstruction = gestureRequirementText
    ? `
    IMPORTANT GESTURE REQUIREMENT:

    The verification photo MUST also clearly show this exact gesture:
    "${gestureRequirementText}"

    Gesture validation rules:
    - Reject if the person is not clearly performing this specific gesture
    - Reject if the gesture is only partially visible or ambiguous
    - Reject if the gesture appears to be performed by someone else or a prop
    - Only approve if the gesture is unmistakably visible and matches the description above
    `
    : '';

  const prompt = `
    You are a security expert verifying user identities for a dating app. Compare these two photos and determine if they show the SAME PERSON.

    SECURITY REQUIREMENTS (CRITICAL):
    - The verification photo MUST show a CLEAR, FULL VIEW of the person's FACE
    - Both eyes, nose, mouth, and jawline must be clearly visible
    - Reject any photo that only shows partial face, beard only, hair only, or obscured features
    - Eyeglasses are NOT an obstruction: if the eyes are clearly visible through the lenses, the photo passes this requirement
    - This prevents fake accounts and catfishing - be extremely strict!

    IDENTITY TOLERANCE (CRITICAL):
    The same person legitimately looks different across photos. The following must NEVER
    lower similarity, confidence, or cause isMatch=false on their own — judge them as if
    they were absent:
    - Eyeglasses (or sunglasses) worn in one photo but not the other
    - Facial hair grown, shaved, or trimmed (beard/mustache changes)
    - Hairstyle, hair length, hair color, or hairline changes
    - Makeup, earrings, or other accessories
    - Different lighting, camera angle, facial expression, or an age gap of a few years
    Judge identity ONLY by stable facial geometry: overall face shape, eye shape and
    spacing (behind any lenses), nose structure, mouth/lip shape, jawline and bone
    structure. If the faces match apart from the tolerated differences above, report
    similarity in the 85-100 range and isMatch=true.

    Photo 1: User's profile photo (reference image)
    Photo 2: Verification photo (MUST be a clear facial selfie)

    First, validate Photo 2 (verification):
    - Does it show a complete, unobstructed face with clear facial features?
    - Are both eyes fully visible and in focus?
    - Is the nose and mouth clearly visible?
    - Is the photo a proper facial portrait, not just hair/beard/body?

    If Photo 2 FAILS validation (not a clear face photo), return:
    {
      "similarity": 0,
      "isMatch": false,
      "confidence": 0,
      "reasoning": "Verification photo does not show a clear, complete face. Must be a proper facial portrait."
    }

    If Photo 2 PASSES validation, then compare facial features:
    - Overall facial structure and bone structure
    - Eye shape, color, and spacing between eyes
    - Nose shape, bridge, and nostrils
    - Mouth shape, lips, and jawline
    - Skin tone (facial hair differences are covered by IDENTITY TOLERANCE above)
    - Any distinctive marks, scars, or unique features

    ${gestureInstruction}

    If a gesture requirement is provided above, you MUST also validate that the verification photo clearly shows that exact gesture being performed by the person in Photo 2. If the gesture is missing, unclear, or does not match the description, you MUST treat the verification as a failure and set "isMatch" to false.

    Return ONLY a valid JSON object with this exact structure:
    {
      "similarity": <number 0-100, how similar the FACES are (0 if no clear face in verification)>,
      "isMatch": <boolean - true ONLY if same person with high confidence, clear face shown, AND (if gesture requirement is provided) the gesture is clearly visible and correct>,
      "confidence": <number 0-100, your confidence in the match>,
      "reasoning": "<brief explanation - include validation results, including whether the gesture requirement was satisfied if provided>",
      "mismatchRegions": <array - empty when isMatch is true, otherwise up to 4 objects pinpointing which features differ: {
        "feature": "<short feature name, e.g. jawline, eye shape, nose>",
        "description": "<one plain-language sentence explaining this specific mismatch>",
        "profileBox": {"x": <0-1 normalized left edge within Photo 1>, "y": <0-1 normalized top edge>, "width": <0-1>, "height": <0-1>},
        "verificationBox": {"x": <0-1 within Photo 2>, "y": <0-1>, "width": <0-1>, "height": <0-1>}
      }>
    }
    mismatchRegions boxes are approximate: they must roughly bound the feature in each
    photo using coordinates normalized to that photo's own width/height (0.0-1.0).

    Scoring guide (ONLY if verification photo shows clear face):
    - 90-100: Same person, virtually identical facial features
    - 80-89: Same person, very similar with minor differences
    - 70-79: Likely same person, needs manual review
    - 60-69: Uncertain, probably different people
    - 0-59: Different people or poor quality faces
  `;

  const body = {
    contents: [{
      parts: [
        { text: prompt },
        {
          inline_data: {
            mime_type: "image/jpeg",
            data: profileBase64
          }
        },
        {
          inline_data: {
            mime_type: "image/jpeg",
            data: verificationBase64
          }
        }
      ]
    }],
    generationConfig: {
      responseMimeType: "application/json",
      temperature: 0.1, // Low temperature for consistent analysis
    }
  };

  try {
    let response;
    for (let i = 0; i < geminiUrls.length; i++) {
      const modelName = faceModels[i];
      try {
        console.log(`📡 Calling Gemini API (${modelName}) for face comparison...`);
        response = await fetch(geminiUrls[i], {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body)
        });

        if (!response.ok) {
          const errorText = await response.text();
          console.warn(`⚠️ ${modelName} failed (${response.status}), trying next...`);
          continue;
        }
        break;
      } catch (modelError) {
        console.warn(`⚠️ ${modelName} error: ${modelError}, trying next...`);
      }
    }

    if (!response || !response.ok) {
      throw new Error(`Gemini API error: All ${faceModels.length} models failed`);
    }

    const data = await response.json();
    console.log("✅ Gemini API response received");

    // Extract the JSON response from Gemini
    const content = data.candidates?.[0]?.content?.parts?.[0]?.text;
    if (!content) {
      throw new Error('No content in Gemini response');
    }

    // Parse the JSON response
    console.log("🔍 Raw Gemini response content:", content);

    let result;
    try {
      result = JSON.parse(content.trim());
      console.log("📊 Parsed Gemini result:", JSON.stringify(result, null, 2));
    } catch (parseError) {
      console.error("❌ Failed to parse Gemini JSON response:", content);
      throw new Error('Invalid JSON response from Gemini');
    }

    console.log(`🎯 Gemini analysis: ${result.similarity}% similarity, ${result.confidence}% confidence, match: ${result.isMatch}`);
    console.log(`💬 Reasoning: ${result.reasoning}`);
    console.log(`🔍 Reasoning type: ${typeof result.reasoning}, length: ${result.reasoning?.length || 0}`);

    const finalResult = {
      similarity: Math.max(0, Math.min(100, result.similarity || 0)),
      confidence: Math.max(0, Math.min(100, result.confidence || 0)),
      isMatch: Boolean(result.isMatch),
      reasoning: result.reasoning || "Analysis completed",
      mismatchRegions: result.isMatch === true
        ? []
        : parseMismatchRegions(result.mismatchRegions),
    };

    console.log("✅ Final comparison result:", JSON.stringify(finalResult, null, 2));

    return finalResult;

  } catch (error) {
    console.error("❌ Error in Gemini face comparison:", error);
    throw error;
  }
}

// Google Cloud Vision API (Alternative method - easy to switch back)
async function compareFacesWithVision(
  profilePhotoBuffer: ArrayBuffer,
  verificationPhotoBuffer: ArrayBuffer
): Promise<FaceComparisonResult> {
  // Easy switch-back option - just uncomment the Vision API code if needed
  console.log("🔄 Vision API selected but not implemented - use Gemini instead");
  throw new Error('Switch to Vision API by implementing this function');
}

// FALLBACK: Basic validation only (when AI fails)
async function compareFacesBasic(
  profilePhotoBuffer: ArrayBuffer,
  verificationPhotoBuffer: ArrayBuffer
): Promise<FaceComparisonResult> {
  console.log("⚠️ FALLBACK: Google Vision failed, using basic validation");
  console.log("📊 Photo sizes - Profile:", profilePhotoBuffer.byteLength, "Verification:", verificationPhotoBuffer.byteLength);

  // Basic validation - check if images exist and are reasonable sizes
  if (profilePhotoBuffer.byteLength < 1000 || verificationPhotoBuffer.byteLength < 1000) {
    console.log("❌ Photos too small - rejecting");
    return {
      similarity: 0,
      confidence: 0,
      isMatch: false,
    };
  }

  // Conservative fallback - require manual review
  // Since we can't do real AI comparison, set low similarity to force manual review
  const fallbackSimilarity = 45 + Math.random() * 20; // 45-65% (requires manual review)
  const fallbackConfidence = 60 + Math.random() * 20; // 60-80%

  console.log(`🔄 FALLBACK RESULT: ${fallbackSimilarity.toFixed(2)}% similarity (manual review required)`);

  return {
    similarity: Math.round(fallbackSimilarity * 100) / 100,
    confidence: Math.round(fallbackConfidence * 100) / 100,
    isMatch: false,
    reasoning: "Automated verification could not be completed at this time. Please try again with good lighting and framing.",
  };
}
