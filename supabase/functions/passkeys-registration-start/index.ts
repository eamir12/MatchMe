import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  bytesToBase64Url,
  corsHeaders,
  createAdminClient,
  errorResponse,
  getAuthenticatedUser,
  getPasskeyRuntimeConfig,
  jsonResponse,
  storePasskeyChallenge,
} from "../_shared/passkeys.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const authenticatedUser = await getAuthenticatedUser(req);
    if (!authenticatedUser?.id) {
      return errorResponse(401, "unauthorized", "You must be signed in to add a passkey.");
    }

    const adminClient = createAdminClient();
    const config = await getPasskeyRuntimeConfig(adminClient);
    const challenge = crypto.getRandomValues(new Uint8Array(32));
    const challengeBase64Url = bytesToBase64Url(challenge);
    const requestId = crypto.randomUUID();

    const normalizedEmail = (
      body.email ??
      authenticatedUser.email ??
      ""
    ).toString().trim().toLowerCase();
    const normalizedDisplayName = (
      body.display_name ??
      body.displayName ??
      authenticatedUser.user_metadata?.display_name ??
      authenticatedUser.user_metadata?.full_name ??
      authenticatedUser.email ??
      "User"
    ).toString().trim();

    const userIdBase64Url = bytesToBase64Url(
      new TextEncoder().encode(authenticatedUser.id),
    );

    const { data: existingCredentials, error: credentialsError } = await adminClient
      .from("passkey_credentials")
      .select("credential_id, transports")
      .eq("user_id", authenticatedUser.id);

    if (credentialsError) {
      throw new Error(`Failed to load existing passkeys: ${credentialsError.message}`);
    }

    await storePasskeyChallenge(adminClient, {
      requestId,
      userId: authenticatedUser.id,
      email: normalizedEmail || null,
      challenge: challengeBase64Url,
      challengeType: "registration",
      rpId: config.activeRpId,
    });

    return jsonResponse({
      requestId,
      publicKey: {
        challenge: challengeBase64Url,
        rp: {
          name: "MatchMe",
          id: config.activeRpId,
        },
        user: {
          id: userIdBase64Url,
          name: normalizedEmail || authenticatedUser.id,
          displayName: normalizedDisplayName || "User",
        },
        pubKeyCredParams: [
          { alg: -7, type: "public-key" },
          { alg: -257, type: "public-key" },
        ],
        excludeCredentials: (existingCredentials ?? []).map((credential) => ({
          id: credential.credential_id,
          type: "public-key",
          transports: Array.isArray(credential.transports) ? credential.transports : [],
        })),
        timeout: 60000,
        attestation: "none",
        authenticatorSelection: {
          requireResidentKey: false,
          residentKey: "preferred",
          userVerification: "preferred",
        },
      },
    });
  } catch (error) {
    console.error("[passkeys-registration-start] Error:", error);
    const message = error instanceof Error ? error.message : String(error);
    const status = message === "Missing authorization header" ? 401 : 400;
    return errorResponse(
      status,
      "passkey_registration_start_failed",
      message,
    );
  }
});
