import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { withInvocationLogging } from "../_shared/edge_function_logger.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import { verifyAuthenticationResponse } from "npm:@simplewebauthn/server@13";
import {
  base64UrlToBytes,
  consumePasskeyChallenge,
  corsHeaders,
  createAdminClient,
  errorResponse,
  jsonResponse,
} from "../_shared/passkeys.ts";
import { getPasskeyRuntimeConfig } from "../_shared/passkeys.ts";

serve(withInvocationLogging("passkeys-authentication-finish", async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const assertion = body.assertion ?? body.credential;
    const email = (body.email ?? "").toString().trim().toLowerCase();
    const requestId = (body.requestId ?? body.request_id ?? "").toString().trim();

    if (!assertion || !email || !requestId) {
      return errorResponse(
        400,
        "invalid_request",
        "Assertion, email, and requestId are required.",
      );
    }

    const adminClient = createAdminClient();
    const challenge = await consumePasskeyChallenge(
      adminClient,
      requestId,
      "authentication",
    );

    if (!challenge?.user_id || challenge.email?.toLowerCase() !== email) {
      return errorResponse(
        401,
        "invalid_challenge",
        "This passkey sign-in request is no longer valid.",
      );
    }

    const credentialId = (assertion.id ?? assertion.rawId ?? "").toString().trim();
    if (!credentialId) {
      return errorResponse(
        400,
        "invalid_assertion",
        "The passkey response did not include a credential ID.",
      );
    }

    const { data: credential, error: credentialError } = await adminClient
      .from("passkey_credentials")
      .select(
        "id, user_id, credential_id, public_key, counter, transports, rp_id, credential_device_type, credential_backed_up",
      )
      .eq("credential_id", credentialId)
      .maybeSingle();

    if (credentialError) {
      throw new Error(`Failed to load passkey credential: ${credentialError.message}`);
    }

    if (!credential || credential.user_id !== challenge.user_id) {
      return errorResponse(401, "credential_not_found", "Passkey sign-in failed.");
    }

    const config = await getPasskeyRuntimeConfig(adminClient);
    const verification = await verifyAuthenticationResponse({
      response: assertion,
      expectedChallenge: challenge.challenge,
      expectedOrigin: config.allowedOrigins,
      expectedRPID: config.authenticationRpIdFallbacks,
      credential: {
        id: credential.credential_id,
        publicKey: base64UrlToBytes(credential.public_key),
        counter: Number(credential.counter ?? 0),
        transports: Array.isArray(credential.transports) ? credential.transports : [],
      },
      requireUserVerification: false,
    });

    if (!verification.verified) {
      return errorResponse(401, "verification_failed", "Passkey sign-in failed.");
    }

    const authenticationInfo = verification.authenticationInfo as Record<string, unknown> | undefined;
    const newCounter = Number(authenticationInfo?.newCounter ?? credential.counter ?? 0);

    const { error: updateError } = await adminClient
      .from("passkey_credentials")
      .update({
        counter: newCounter,
        last_used_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq("id", credential.id);

    if (updateError) {
      throw new Error(`Failed to update passkey counter: ${updateError.message}`);
    }

    const { data: generatedLink, error: generateLinkError } = await adminClient.auth.admin
      .generateLink({
        type: "magiclink",
        email,
      });

    if (generateLinkError) {
      throw new Error(`Failed to generate session token: ${generateLinkError.message}`);
    }

    const linkProperties = generatedLink?.properties as Record<string, unknown> | undefined;
    const tokenHash = (
      linkProperties?.hashed_token ??
      (generatedLink as Record<string, unknown> | undefined)?.hashed_token
    )?.toString().trim();
    const emailOtp = (
      linkProperties?.email_otp ??
      (generatedLink as Record<string, unknown> | undefined)?.email_otp
    )?.toString().trim();

    const sessionClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      {
        auth: {
          persistSession: false,
          autoRefreshToken: false,
          detectSessionInUrl: false,
        },
      },
    );

    const verifyResponse = tokenHash
      ? await sessionClient.auth.verifyOtp({
        token_hash: tokenHash,
        type: "magiclink",
      })
      : emailOtp
      ? await sessionClient.auth.verifyOtp({
        email,
        token: emailOtp,
        type: "magiclink",
      })
      : { data: { session: null }, error: new Error("Missing magic link token payload.") };

    if (verifyResponse.error || !verifyResponse.data.session) {
      throw new Error(
        verifyResponse.error?.message ?? "Failed to exchange passkey sign-in for a session.",
      );
    }

    return jsonResponse({
      session: verifyResponse.data.session,
    });
  } catch (error) {
    console.error("[passkeys-authentication-finish] Error:", error);
    return errorResponse(
      400,
      "passkey_authentication_finish_failed",
      error instanceof Error ? error.message : String(error),
    );
  }
}));