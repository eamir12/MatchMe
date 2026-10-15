import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
};

const DEFAULT_RP_ID = "vazkmvrbshxwyodentng.supabase.co";
const DEFAULT_DEVELOPMENT_RP_ID = "localhost";
const DEFAULT_ANDROID_APK_KEY_HASH = "nSPXJ93P8O5mS7iICbkWxo1Et5xSeOB7kHw0N_ZC81c";
const PASSKEY_CONFIG_KEYS = [
  "auth.passkeys.development_mode",
  "auth.passkeys.development_rp_id",
  "auth.passkeys.relying_party_id",
  "auth.passkeys.android_apk_key_hash",
  "auth.passkeys.allowed_origins",
] as const;

export type PasskeyChallengeType = "registration" | "authentication";

export type PasskeyRuntimeConfig = {
  relyingPartyId: string;
  developmentRpId: string;
  developmentMode: boolean;
  activeRpId: string;
  androidApkKeyHash: string;
  allowedOrigins: string[];
  authenticationRpIdFallbacks: string[];
};

type PasskeyChallengeRow = {
  id: string;
  request_id: string;
  user_id: string | null;
  email: string | null;
  challenge: string;
  challenge_type: PasskeyChallengeType;
  rp_id: string;
  created_at: string;
  expires_at: string;
};

type AuthUser = {
  id: string;
  email?: string | null;
  user_metadata?: Record<string, unknown> | null;
};

function requireEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

export function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (let index = 0; index < bytes.byteLength; index += 1) {
    binary += String.fromCharCode(bytes[index]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export function base64UrlToBytes(value: string) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

export function errorResponse(
  status: number,
  code: string,
  message: string,
): Response {
  return jsonResponse({ error: code, message }, status);
}

export function createAdminClient() {
  return createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { persistSession: false } },
  );
}

export function createAuthedClient(req: Request) {
  const authHeader = req.headers.get("authorization") ?? req.headers.get("Authorization");
  if (!authHeader) {
    throw new Error("Missing authorization header");
  }

  return createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_ANON_KEY"),
    {
      auth: { persistSession: false },
      global: { headers: { Authorization: authHeader } },
    },
  );
}

function extractBearerToken(req: Request): string {
  const authHeader = req.headers.get("authorization") ?? req.headers.get("Authorization");
  if (!authHeader) {
    throw new Error("Missing authorization header");
  }

  const token = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!token) {
    throw new Error("Missing bearer token");
  }

  return token;
}

export async function getAuthenticatedUser(req: Request): Promise<AuthUser | null> {
  const token = extractBearerToken(req);
  const adminClient = createAdminClient();
  const { data, error } = await adminClient.auth.getUser(token);
  if (error || !data.user?.id) {
    return null;
  }

  const rawUser = data.user as {
    id: string;
    email?: string | null;
    user_metadata?: Record<string, unknown> | null;
    userMetadata?: Record<string, unknown> | null;
  };

  return {
    id: rawUser.id,
    email: rawUser.email,
    user_metadata: rawUser.user_metadata ?? rawUser.userMetadata ?? null,
  };
}

function normalizeConfigString(value: unknown, fallback: string): string {
  if (typeof value !== "string") {
    return fallback;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : fallback;
}

function normalizeConfigBoolean(value: unknown): boolean {
  return value === true || value === "true";
}

function normalizeStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

function looksLocalHost(rpId: string): boolean {
  return rpId === "localhost" || rpId === "127.0.0.1" || rpId.endsWith(".localhost");
}

function deriveAllowedOrigins(
  activeRpId: string,
  androidApkKeyHash: string,
  configuredOrigins: string[],
): string[] {
  const origins = new Set<string>(configuredOrigins);
  origins.add(`https://${activeRpId}`);

  if (looksLocalHost(activeRpId)) {
    origins.add("http://localhost");
    origins.add("https://localhost");
    origins.add("http://127.0.0.1");
    origins.add("https://127.0.0.1");
  }

  if (androidApkKeyHash) {
    origins.add(`android:apk-key-hash:${androidApkKeyHash}`);
  }

  return [...origins];
}

function buildAuthenticationRpIdFallbacks(
  activeRpId: string,
  developmentRpId: string,
  relyingPartyId: string,
): string[] {
  return [
    activeRpId,
    relyingPartyId,
    developmentRpId,
    "com.example.matchme",
    "android",
    "localhost",
  ].filter((value, index, values) => value && values.indexOf(value) === index);
}

export async function getPasskeyRuntimeConfig(
  adminClient: ReturnType<typeof createAdminClient>,
): Promise<PasskeyRuntimeConfig> {
  const { data, error } = await adminClient
    .from("app_config")
    .select("config_key, config_value")
    .in("config_key", [...PASSKEY_CONFIG_KEYS]);

  if (error) {
    throw new Error(`Failed to load passkey config: ${error.message}`);
  }

  const configMap = new Map<string, unknown>();
  for (const row of data ?? []) {
    configMap.set(row.config_key, row.config_value);
  }

  const relyingPartyId = normalizeConfigString(
    configMap.get("auth.passkeys.relying_party_id"),
    DEFAULT_RP_ID,
  );
  const developmentRpId = normalizeConfigString(
    configMap.get("auth.passkeys.development_rp_id"),
    DEFAULT_DEVELOPMENT_RP_ID,
  );
  const developmentMode = normalizeConfigBoolean(
    configMap.get("auth.passkeys.development_mode"),
  );
  const activeRpId = developmentMode ? developmentRpId : relyingPartyId;
  const androidApkKeyHash = normalizeConfigString(
    configMap.get("auth.passkeys.android_apk_key_hash"),
    DEFAULT_ANDROID_APK_KEY_HASH,
  );
  const configuredOrigins = normalizeStringArray(
    configMap.get("auth.passkeys.allowed_origins"),
  );

  return {
    relyingPartyId,
    developmentRpId,
    developmentMode,
    activeRpId,
    androidApkKeyHash,
    allowedOrigins: deriveAllowedOrigins(
      activeRpId,
      androidApkKeyHash,
      configuredOrigins,
    ),
    authenticationRpIdFallbacks: buildAuthenticationRpIdFallbacks(
      activeRpId,
      developmentRpId,
      relyingPartyId,
    ),
  };
}

export async function storePasskeyChallenge(
  adminClient: ReturnType<typeof createAdminClient>,
  input: {
    requestId: string;
    userId: string | null;
    email: string | null;
    challenge: string;
    challengeType: PasskeyChallengeType;
    rpId: string;
  },
): Promise<void> {
  const { error } = await adminClient.from("passkey_challenges").insert({
    request_id: input.requestId,
    user_id: input.userId,
    email: input.email,
    challenge: input.challenge,
    challenge_type: input.challengeType,
    rp_id: input.rpId,
  });

  if (error) {
    throw new Error(`Failed to store passkey challenge: ${error.message}`);
  }
}

export async function consumePasskeyChallenge(
  adminClient: ReturnType<typeof createAdminClient>,
  requestId: string,
  challengeType: PasskeyChallengeType,
): Promise<PasskeyChallengeRow | null> {
  const nowIso = new Date().toISOString();
  const { data, error } = await adminClient
    .from("passkey_challenges")
    .select("*")
    .eq("request_id", requestId)
    .eq("challenge_type", challengeType)
    .gt("expires_at", nowIso)
    .maybeSingle<PasskeyChallengeRow>();

  if (error) {
    throw new Error(`Failed to load passkey challenge: ${error.message}`);
  }

  if (!data) {
    return null;
  }

  const { error: deleteError } = await adminClient
    .from("passkey_challenges")
    .delete()
    .eq("id", data.id);

  if (deleteError) {
    throw new Error(`Failed to consume passkey challenge: ${deleteError.message}`);
  }

  return data;
}

export async function findAuthUserByEmail(
  adminClient: ReturnType<typeof createAdminClient>,
  email: string,
): Promise<AuthUser | null> {
  const normalizedEmail = email.trim().toLowerCase();
  if (!normalizedEmail) {
    return null;
  }

  const perPage = 200;
  for (let page = 1; page <= 25; page += 1) {
    const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage });
    if (error) {
      throw new Error(`Failed to list users: ${error.message}`);
    }

    const users = data.users ?? [];
    const matchedUser = users.find((user) => user.email?.toLowerCase() === normalizedEmail);
    if (matchedUser) {
      return {
        id: matchedUser.id,
        email: matchedUser.email,
        user_metadata: matchedUser.user_metadata ?? null,
      };
    }

    if (users.length < perPage) {
      break;
    }
  }

  return null;
}

export function getCredentialResponseTransports(
  credential: Record<string, unknown>,
): string[] {
  const response = credential.response;
  if (!response || typeof response !== "object") {
    return [];
  }

  const transports = (response as Record<string, unknown>).transports;
  if (!Array.isArray(transports)) {
    return [];
  }

  return transports.filter((item): item is string => typeof item === "string");
}
