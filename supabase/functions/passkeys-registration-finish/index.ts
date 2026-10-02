import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { verifyRegistrationResponse } from "npm:@simplewebauthn/server@13";
import {
  bytesToBase64Url,
  consumePasskeyChallenge,
  corsHeaders,
  createAdminClient,
  errorResponse,
  getAuthenticatedUser,
  getCredentialResponseTransports,
  getPasskeyRuntimeConfig,
  jsonResponse,
} from "../_shared/passkeys.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const attestation = body.attestation ?? body.credential;
    const requestId = (body.requestId ?? body.request_id ?? "").toString().trim();

    if (!attestation || !requestId) {
      return errorResponse(
        400,
        "invalid_request",
        "Attestation and requestId are required.",
      );
    }

    const authenticatedUser = await getAuthenticatedUser(req);
    if (!authenticatedUser?.id) {
      return errorResponse(401, "unauthorized", "You must be signed in to add a passkey.");
    }

    const adminClient = createAdminClient();
    const challenge = await consumePasskeyChallenge(
      adminClient,
      requestId,
      "registration",
    );

    if (!challenge || challenge.user_id !== authenticatedUser.id) {
      return errorResponse(
        400,
        "invalid_challenge",
        "This passkey registration request is no longer valid.",
      );
    }

    const config = await getPasskeyRuntimeConfig(adminClient);
    const verification = await verifyRegistrationResponse({
      response: attestation,
      expectedChallenge: challenge.challenge,
      expectedOrigin: config.allowedOrigins,
      expectedRPID: challenge.rp_id,
      requireUserVerification: false,
    });

    if (!verification.verified || !verification.registrationInfo) {
      return errorResponse(
        400,
        "verification_failed",
        "Passkey registration could not be verified.",
      );
    }

    const registrationInfo = verification.registrationInfo as Record<string, unknown>;
    const nestedCredential = registrationInfo.credential as Record<string, unknown> | undefined;
    const credentialId = (
      nestedCredential?.id ??
      registrationInfo.credentialID
    )?.toString();
    const publicKey = (
      nestedCredential?.publicKey ??
      registrationInfo.credentialPublicKey
    ) as Uint8Array | undefined;
    const counter = Number(
      nestedCredential?.counter ??
      registrationInfo.counter ??
      0,
    );

    if (!credentialId || !publicKey) {
      return errorResponse(
        400,
        "invalid_registration",
        "The verified passkey response was missing credential data.",
      );
    }

    const { data: existingCredential, error: existingCredentialError } = await adminClient
      .from("passkey_credentials")
      .select("id, user_id")
      .eq("credential_id", credentialId)
      .maybeSingle();

    if (existingCredentialError) {
      throw new Error(`Failed to check existing passkey: ${existingCredentialError.message}`);
    }

    if (existingCredential && existingCredential.user_id !== authenticatedUser.id) {
      return errorResponse(
        409,
        "credential_conflict",
        "This passkey is already linked to another account.",
      );
    }

    const transports = getCredentialResponseTransports(attestation);
    const payload = {
      user_id: authenticatedUser.id,
      credential_id: credentialId,
      public_key: bytesToBase64Url(publicKey),
      counter,
      rp_id: challenge.rp_id,
      transports,
      credential_device_type: (
        registrationInfo.credentialDeviceType ??
        nestedCredential?.deviceType ??
        null
      )?.toString() ?? null,
      credential_backed_up: Boolean(
        registrationInfo.credentialBackedUp ??
        nestedCredential?.backedUp ??
        false,
      ),
      updated_at: new Date().toISOString(),
    };

    const mutation = existingCredential
      ? adminClient.from("passkey_credentials").update(payload).eq("id", existingCredential.id)
      : adminClient.from("passkey_credentials").insert(payload);
    const { error: writeError } = await mutation;

    if (writeError) {
      throw new Error(`Failed to store passkey credential: ${writeError.message}`);
    }

    return jsonResponse({
      credentialId,
      rpId: challenge.rp_id,
    });
  } catch (error) {
    console.error("[passkeys-registration-finish] Error:", error);
    return errorResponse(
      400,
      "passkey_registration_finish_failed",
      error instanceof Error ? error.message : String(error),
    );
  }
});
