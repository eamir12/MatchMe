import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  bytesToBase64Url,
  corsHeaders,
  createAdminClient,
  findAuthUserByEmail,
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
    const normalizedEmail = (body.email ?? "").toString().trim().toLowerCase();

    if (!normalizedEmail) {
      return jsonResponse(
        { error: "email_required", message: "Email is required." },
        400,
      );
    }

    const adminClient = createAdminClient();
    const config = await getPasskeyRuntimeConfig(adminClient);
    const authUser = await findAuthUserByEmail(adminClient, normalizedEmail);
    const challenge = crypto.getRandomValues(new Uint8Array(32));
    const challengeBase64Url = bytesToBase64Url(challenge);
    const requestId = crypto.randomUUID();

    const { data: credentials, error: credentialsError } = authUser?.id
      ? await adminClient
        .from("passkey_credentials")
        .select("credential_id, user_id, transports")
        .eq("user_id", authUser.id)
      : { data: [], error: null };

    if (credentialsError) {
      throw new Error(`Failed to load passkey credentials: ${credentialsError.message}`);
    }

    const allowCredentials = (credentials ?? []).map((credential) => ({
      id: credential.credential_id,
      type: "public-key",
      transports: Array.isArray(credential.transports) ? credential.transports : [],
    }));

    await storePasskeyChallenge(adminClient, {
      requestId,
      userId: authUser?.id ?? null,
      email: normalizedEmail,
      challenge: challengeBase64Url,
      challengeType: "authentication",
      rpId: config.activeRpId,
    });

    if (!authUser?.id || allowCredentials.length == 0) {
      return jsonResponse({
        requestId,
        hasPasskey: false,
      });
    }

    return jsonResponse({
      requestId,
      hasPasskey: true,
      publicKey: {
        challenge: challengeBase64Url,
        timeout: 60000,
        rpId: config.activeRpId,
        allowCredentials,
        userVerification: "preferred",
      },
    });
  } catch (error) {
    console.error("[passkeys-authentication-start] Error:", error);
    return jsonResponse(
      {
        error: "passkey_authentication_start_failed",
        message: error instanceof Error ? error.message : String(error),
      },
      400,
    );
  }
});
