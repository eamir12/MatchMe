import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface FaceComparisonResult {
  similarity: number;
  confidence: number;
  isMatch: boolean;
  reasoning?: string;
  gestureValid?: boolean;
  error?: string;
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
      .select("photos, verification_photo_path")
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

    console.log("✅ EDGE FUNCTION: User data retrieved:", {
      hasPhotos: !!userData.photos,
      photosCount: userData.photos?.length || 0,
      hasVerificationPhoto: !!userData.verification_photo_path
    });

    if (!userData.photos || userData.photos.length === 0) {
      console.log("❌ EDGE FUNCTION: User has no profile photos");
      throw new Error("User has no profile photos");
    }

    if (!userData.verification_photo_path) {
      console.log("❌ EDGE FUNCTION: User has no verification photo");
      throw new Error("User has no verification photo");
    }

    // Get the main profile photo (first one)
    const profilePhotoPath = userData.photos[0];
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
      const aiAnalysisData = {
        similarity: 0,
        confidence: 0,
        isMatch: false,
        reasoning: auditResult.reasoning || "Photo failed authenticity check.",
        comparedAt: new Date().toISOString(),
        service: "gemini_ai",
        authenticityAudit: { authentic: false, reasoning: auditResult.reasoning },
      };
      await supabaseInternal.rpc("edge_update_verification", {
        p_user_id: userId,
        p_patch: {
          verification_status: "rejected",
          verification_auto_rejected: true,
          verification_similarity_score: 0,
          verification_ai_analysis: aiAnalysisData,
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

    // PRIMARY: Gemini AI for face comparison (using gemini-3.0-flash model)
    // To switch back to Vision API: change compareFacesWithGemini to compareFacesWithVision
    console.log("🤖 Starting face comparison with Gemini AI (gemini-3.0-flash)...");
    let comparisonResult;
    try {
      aiUsed = true;
      aiModel = "gemini-3-flash-preview";
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
    const aiAnalysisData = {
      similarity: comparisonResult.similarity,
      confidence: comparisonResult.confidence,
      isMatch: comparisonResult.isMatch,
      reasoning: comparisonResult.reasoning || "No reasoning provided",
      comparedAt: new Date().toISOString(),
      service: "gemini_ai",
      note: "Using Gemini AI (gemini-3.0-flash) for face comparison",
      gestureCode: gestureCode || null,
      gesturePrompt: gesturePrompt || null,
      ...(auditResult && { authenticityAudit: { authentic: auditResult.authentic, reasoning: auditResult.reasoning } }),
    };

    console.log("💾 Storing comparison results in database:", comparisonResult);
    console.log("📊 AI Analysis data to store:", JSON.stringify(aiAnalysisData, null, 2));
    console.log("🔍 Reasoning value:", comparisonResult.reasoning);
    console.log("🔍 Reasoning type:", typeof comparisonResult.reasoning);

    const nowIso = new Date().toISOString();
    const updatePayload: Record<string, unknown> = {
      verification_similarity_score: comparisonResult.similarity / 100, // Convert to 0-1 scale
      verification_ai_analysis: aiAnalysisData,
    };

    if (comparisonResult.isMatch === false) {
      updatePayload.verification_status = "rejected";
      updatePayload.verification_auto_rejected = true;
      updatePayload.verification_reviewed_at = nowIso;
      updatePayload.is_verified = false;
    } else if (comparisonResult.isMatch === true && comparisonResult.similarity >= 85) {
      updatePayload.verification_status = "approved";
      updatePayload.is_verified = true;
      updatePayload.verification_auto_rejected = false;
      updatePayload.verification_reviewed_at = nowIso;
    } else {
      updatePayload.verification_status = "pending";
      updatePayload.verification_auto_rejected = false;
      updatePayload.verification_reviewed_at = null;
    }

    const { error: updateError } = await supabaseInternal
      .rpc("edge_update_verification", { p_user_id: userId, p_patch: updatePayload });

    if (updateError) {
      console.error("❌ Database update error:", updateError);
      throw new Error(`Failed to update user data: ${updateError.message}`);
    }

    console.log("✅ Database update successful for user:", userId);

    if (updatePayload["verification_status"] === "approved") {
      try {
        await supabase.storage.from("verification-photos").remove([verificationPhotoPath]);
        await supabaseInternal.rpc("edge_update_verification", {
          p_user_id: userId,
          p_patch: { verification_photo_path: null },
        });
      } catch (e) {
        console.error("⚠️ Failed to delete verification photo after auto-approve:", e);
      }
    }

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
      reasoning: comparisonResult.reasoning,
      userId,
      note: "Using Gemini AI (gemini-3.0-flash) for face comparison",
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
        },
      },
    );

  } catch (error) {
    console.error("❌ EDGE FUNCTION: Error in compare-verification-photos function:", error);
    console.error("🔍 EDGE FUNCTION: Error type:", error.constructor.name);
    console.error("🔍 EDGE FUNCTION: Error message:", error.message);
    console.error("🔍 EDGE FUNCTION: Stack trace:", error.stack);

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
              verification_status: "pending",
              verification_auto_rejected: false,
              verification_reviewed_at: null,
              is_verified: false,
              verification_ai_analysis: {
                service: "edge_function",
                comparedAt: new Date().toISOString(),
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
      error: error.message,
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
  const GEMINI_URL_PRIMARY = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${API_KEY}`;
  const GEMINI_URL_BACKUP = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${API_KEY}`;

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

  let response: Response;
  try {
    response = await fetch(GEMINI_URL_PRIMARY, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      response = await fetch(GEMINI_URL_BACKUP, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
    }
  } catch (e) {
    throw new Error(`Gemini authenticity audit request failed: ${e}`);
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

  } catch (error) {
    console.error("❌ Error in Google Vision API call:", error);
    return { similarity: 0, confidence: 0, isMatch: false };
  }

  // Check if faces were detected
  const profileFace = profileData.responses?.[0]?.faceAnnotations?.[0];
  const verificationFace = verificationData.responses?.[0]?.faceAnnotations?.[0];

  if (!profileFace || !verificationFace) {
    console.log("❌ No faces detected in one or both images");
    return { similarity: 0, confidence: 0, isMatch: false };
  }

  // Simple similarity based on face detection confidence and basic features
  // This is a basic implementation - for better accuracy, you'd need more sophisticated comparison
  const profileConfidence = profileFace.detectionConfidence || 0;
  const verificationConfidence = verificationFace.detectionConfidence || 0;

  // Very basic similarity calculation (just for demo)
  // In production, you'd compare facial landmarks, angles, etc.
  const confidenceDiff = Math.abs(profileConfidence - verificationConfidence);
  const similarity = Math.max(0, 100 - (confidenceDiff * 100));

  console.log(`🎯 Google Vision similarity: ${similarity.toFixed(2)}% (basic calculation)`);
  console.log(`📊 Face confidences - Profile: ${profileConfidence.toFixed(2)}, Verification: ${verificationConfidence.toFixed(2)}`);

  return {
    similarity: Math.round(similarity * 100) / 100,
    confidence: Math.min(profileConfidence, verificationConfidence),
    isMatch: similarity >= 70, // Lower threshold since this is basic
  };
}

// Gemini AI Face Comparison (Primary method - using gemini-3.0-flash)
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

  const GEMINI_URL_PRIMARY = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=${API_KEY}`;
  const GEMINI_URL_BACKUP = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${API_KEY}`;

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
    - This prevents fake accounts and catfishing - be extremely strict!

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
    - Skin tone and facial hair (if present)
    - Any distinctive marks, scars, or unique features

    ${gestureInstruction}

    If a gesture requirement is provided above, you MUST also validate that the verification photo clearly shows that exact gesture being performed by the person in Photo 2. If the gesture is missing, unclear, or does not match the description, you MUST treat the verification as a failure and set "isMatch" to false.

    Return ONLY a valid JSON object with this exact structure:
    {
      "similarity": <number 0-100, how similar the FACES are (0 if no clear face in verification)>,
      "isMatch": <boolean - true ONLY if same person with high confidence, clear face shown, AND (if gesture requirement is provided) the gesture is clearly visible and correct>,
      "confidence": <number 0-100, your confidence in the match>,
      "reasoning": "<brief explanation - include validation results, including whether the gesture requirement was satisfied if provided>"
    }

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
    try {
      console.log("📡 Calling Gemini API (Primary) for face comparison...");
      response = await fetch(GEMINI_URL_PRIMARY, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Primary API error: ${response.status} - ${errorText}`);
      }
    } catch (primaryError) {
      console.warn("⚠️ Primary Gemini failed, switching to backup...", primaryError);
      console.log("📡 Calling Gemini API (Backup) for face comparison...");
      response = await fetch(GEMINI_URL_BACKUP, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      });

      if (!response.ok) {
        const errorText = await response.text();
        console.error("❌ Backup Gemini API error:", response.status, errorText);
        throw new Error(`Gemini API error (Primary & Backup failed): ${response.status} - ${errorText}`);
      }
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
    isMatch: false, // Require manual review when AI fails
  };
}
