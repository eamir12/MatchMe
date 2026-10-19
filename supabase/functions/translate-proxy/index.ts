import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";
import { consumeAiRateLimit } from "../_shared/ai_rate_limit.ts";

const DEEPL_BASE_URL = "https://api-free.deepl.com/v2";
const DEEPL_API_KEY = Deno.env.get("DEEPL_API_KEY") || "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const SUPABASE_TRANSLATION_PRIVATE_KEY_BASE64 =
  Deno.env.get("TRANSLATION_PRIVATE_KEY_BASE64") || "";
const SUPABASE_TRANSLATION_KEY_ID =
  Deno.env.get("TRANSLATION_KEY_ID") || "f5af9936-a780-4380-b9e8-b04396d4d903";

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Startup health check — log whether critical secrets are available
console.log(`[translate-proxy] DEEPL_API_KEY set: ${!!DEEPL_API_KEY}`);
console.log(`[translate-proxy] SUPABASE_SERVICE_ROLE_KEY set: ${!!SERVICE_ROLE_KEY}`);
console.log(`[translate-proxy] SUPABASE_URL: ${SUPABASE_URL}`);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-matchme-webhook-secret",
};

function base64Decode(s: string): Uint8Array {
  const binary = atob(s);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const result = new Uint8Array(a.length + b.length);
  result.set(a);
  result.set(b, a.length);
  return result;
}

let _supabasePrivateKey: CryptoKey | null = null;

async function getSupabaseKeyPair(): Promise<{
  privateKey: CryptoKey;
}> {
  if (_supabasePrivateKey) {
    return { privateKey: _supabasePrivateKey };
  }
  const privateKeyBytes = base64Decode(SUPABASE_TRANSLATION_PRIVATE_KEY_BASE64);
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    privateKeyBytes.slice(),
    { name: "X25519" } as any,
    false,
    ["deriveBits"],
  );
  _supabasePrivateKey = privateKey;
  return { privateKey };
}

async function x25519SharedSecret(
  privateKey: CryptoKey,
  publicKeyBytes: Uint8Array,
): Promise<Uint8Array> {
  const importedPublic = await crypto.subtle.importKey(
    "raw",
    publicKeyBytes.slice(),
    { name: "X25519" } as any,
    false,
    [],
  );
  const sharedBits = await crypto.subtle.deriveBits(
    { name: "X25519", public: importedPublic } as any,
    privateKey,
    256,
  );
  return new Uint8Array(sharedBits);
}

async function hkdfSha256(
  inputKeyMaterial: Uint8Array,
  salt: Uint8Array,
  info: string,
  length: number = 32,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    inputKeyMaterial.slice(),
    "HKDF",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: salt.slice(),
      info: new TextEncoder().encode(info),
    },
    key,
    length * 8,
  );
  return new Uint8Array(bits);
}

async function aesGcmDecrypt(
  ciphertext: Uint8Array,
  keyBytes: Uint8Array,
  nonce: Uint8Array,
  aad: Uint8Array,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", keyBytes.slice(), "AES-GCM", false, ["decrypt"]);
  const result = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: nonce.slice(), additionalData: aad.slice() },
    key,
    ciphertext.slice(),
  );
  return new Uint8Array(result);
}

async function aesGcmEncrypt(
  plaintext: Uint8Array,
  keyBytes: Uint8Array,
  nonce: Uint8Array,
  aad: Uint8Array,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", keyBytes.slice(), "AES-GCM", false, ["encrypt"]);
  const result = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce.slice(), additionalData: aad.slice() },
    key,
    plaintext.slice(),
  );
  return new Uint8Array(result);
}

function generateNonce(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(12));
}

/// Normalize an app gender value to 'male' | 'female' | null.
/// Unknown / non-binary / empty values return null so no gender claim is sent
/// to DeepL (we only steer the model when a binary gender is known).
function normalizeGenderForContext(raw: unknown): "male" | "female" | null {
  if (typeof raw !== "string") return null;
  let g = raw.trim().toLowerCase().replace(/-/g, "_");
  if (g.startsWith("gender_")) g = g.slice("gender_".length);
  if (g === "male" || g === "m") return "male";
  if (g === "female" || g === "f") return "female";
  return null;
}

/// Build the DeepL `context` string carrying speaker/addressee gender.
///
/// DeepL has no gender parameter. Per DeepL's own "How to Use the Context
/// Parameter Effectively" guide, `context` must read like NATURAL surrounding
/// content with pronoun clues ("She did not want to tidy up herself") —
/// LLM-style meta-instructions ("The speaker is a woman") are documented as
/// unreliable, and proven so here (EN→HE kept masculine אוהב despite an
/// explicit feminine-speaker instruction). So this emits plain sentences with
/// gendered pronouns, never statements about the request itself.
/// Returns undefined when neither gender is known (no context sent).
function buildGenderContext(
  speakerGenderRaw: unknown,
  addresseeGenderRaw: unknown,
): string | undefined {
  const speaker = normalizeGenderForContext(speakerGenderRaw);
  const addressee = normalizeGenderForContext(addresseeGenderRaw);
  if (!speaker && !addressee) return undefined;
  const wroteSelf = (g: "male" | "female") =>
    g === "female"
      ? "She wrote the following about herself."
      : "He wrote the following about himself.";
  const addressedTo = (g: "male" | "female") =>
    g === "female"
      ? "The following is addressed to her."
      : "The following is addressed to him.";
  if (speaker && addressee) return `${wroteSelf(speaker)} ${addressedTo(addressee)}`;
  if (speaker) return wroteSelf(speaker);
  return addressedTo(addressee as "male" | "female");
}

/// Claim marker suffix stored in translated_target_language while a DeepL
/// translation for a row is in flight, e.g. "es#pending#1789463017890".
/// The embedded timestamp lets a crashed execution's marker be reclaimed
/// after PENDING_STALE_MS instead of blocking that message forever.
/// Existing readers compare translated_target_language for equality against
/// a plain language code, so a marker is simply treated as "not translated
/// yet" everywhere else.
const PENDING_SUFFIX = "#pending#";
const PENDING_STALE_MS = 120_000;

function parsePendingMarker(
  value: unknown,
): { target: string; claimedAt: number } | null {
  if (typeof value !== "string") return null;
  const idx = value.indexOf(PENDING_SUFFIX);
  if (idx <= 0) return null;
  const claimedAt = Number(value.slice(idx + PENDING_SUFFIX.length));
  if (!Number.isFinite(claimedAt) || claimedAt <= 0) return null;
  return { target: value.slice(0, idx), claimedAt };
}

/// True when the stored translation was made for the row's current content:
/// the `translated_source_edited_at` marker recorded at translation time
/// still equals the row's `edited_at`. NULL-safe on both sides and compared
/// as instants (immune to timestamptz formatting drift). Semantics:
/// - marker NULL + never edited (NULL) → match (translation is current);
/// - marker NULL + edited → mismatch (pre-migration backlog: retranslate);
/// - marker set + equal → match (skip, already translated);
/// - marker set + different → mismatch (edited after translation).
/// A missing column (migration not yet applied) reads as undefined, which
/// only ever forces retranslation — never a stale skip.
/// Exported for unit tests.
export function translationMarkerMatches(storedMarker: unknown, rowEditedAt: unknown): boolean {
  const norm = (v: unknown): number | null => {
    if (v === null || v === undefined) return null;
    if (typeof v !== "string") return null;
    const t = v.trim();
    if (t === "" || t === "null") return null;
    const ms = Date.parse(t);
    return Number.isFinite(ms) ? ms : null;
  };
  return norm(storedMarker) === norm(rowEditedAt);
}

/// Atomically claim one chat_messages row for translation to normTarget.
///
/// Concurrent translate-proxy executions (multiple chat bubbles, the
/// locale-change path, the Recent-Chats preview, webhook redeliveries) all
/// used to read translated_target_language before any of them wrote, so
/// every execution re-sent the same messages to DeepL. This claim is a
/// compare-and-swap UPDATE on translated_target_language — only one
/// execution can win per row. The CAS compares against the value this
/// execution observed (`currentTarget`), so a row modified by anyone else
/// in the meantime cannot be claimed.
///
/// Returns the marker to pass to the final CAS write / releaseClaim, or
/// null when the row is already translated (same target) or freshly
/// claimed by another request. A marker older than PENDING_STALE_MS is
/// considered abandoned and may be reclaimed.
async function claimMessageForTranslation(
  messageId: string,
  normTarget: string,
  currentTarget: string | null,
): Promise<string | null> {
  const pending = parsePendingMarker(currentTarget);
  if (pending && pending.target === normTarget) {
    const ageMs = Date.now() - pending.claimedAt;
    if (ageMs < PENDING_STALE_MS) {
      console.log(
        `[translate-proxy] Message ${messageId}: translation to ${normTarget} already in flight ` +
        `(${Math.round(ageMs / 1000)}s ago), skipping`,
      );
      return null;
    }
    console.log(
      `[translate-proxy] Message ${messageId}: reclaiming stale claim from ` +
      `${Math.round(ageMs / 1000)}s ago`,
    );
  }
  const claimValue = `${normTarget}${PENDING_SUFFIX}${Date.now()}`;
  let query = supabase
    .from("chat_messages")
    .update({ translated_target_language: claimValue })
    .eq("id", messageId);
  query = currentTarget === null
    ? query.is("translated_target_language", null)
    : query.eq("translated_target_language", currentTarget);
  const { data, error } = await query.select("id");
  if (error) {
    console.error(`[translate-proxy] Claim CAS failed for message ${messageId}: ${error.message}`);
    return null;
  }
  if (!data || data.length === 0) {
    return null;
  }
  return claimValue;
}

/// Release a claim back to the previous translated_target_language value
/// (best effort, CAS-guarded so we never clobber a newer owner).
async function releaseClaim(
  messageId: string,
  claimValue: string,
  previousTarget: string | null,
): Promise<void> {
  try {
    await supabase
      .from("chat_messages")
      .update({ translated_target_language: previousTarget })
      .eq("id", messageId)
      .eq("translated_target_language", claimValue);
  } catch {
    // Best effort only — a leaked marker is reclaimed after PENDING_STALE_MS.
  }
}

/// Fetch genders for two users in one query. Returns a map userId -> raw gender.
async function fetchUserGenders(
  userIdA: string,
  userIdB: string,
): Promise<Record<string, unknown>> {
  try {
    const { data, error } = await supabase
      .from("users")
      .select("id, gender")
      .in("id", [userIdA, userIdB]);
    if (error || !data) return {};
    const out: Record<string, unknown> = {};
    for (const row of data as Array<{ id: string; gender: unknown }>) {
      out[row.id] = row.gender;
    }
    return out;
  } catch {
    return {};
  }
}

/// Translates text via DeepL, optionally with a client-provided source language
/// and an optional gender `context`.
/// Language detection must happen BEFORE this function is called (on the Flutter
/// client or in the calling handler).  This function only passes source_lang
/// through to DeepL; it never guesses.  When no clientSourceLang is given, no
/// source_lang is sent and DeepL auto-detects.
///
/// DeepL compliance (per current API reference):
/// - POST {DEEPL_BASE_URL}/translate, auth `DeepL-Auth-Key`, JSON body.
/// - `text: [text]` (single-element array; DeepL translates entries
///   independently), `target_lang` + optional `source_lang` uppercased.
/// - `preserve_formatting: true` kept as before.
/// - `context` is extra, non-translated, UNBILLED steering input — used here
///   exclusively for speaker/addressee gender. `formality` intentionally NOT
///   sent (defaults apply); if ever needed, only `prefer_more`/`prefer_less`
///   are safe for arbitrary target languages.
/// - Errors: JSON `{message, code?}` + `X-Trace-ID` header (logged). Retry
///   429/5xx with exponential backoff; NEVER retry 400 (invalid) or 456
///   (quota exhausted). Request limit 128KiB — chat messages are far below it.
/// Translate via DeepL with optional source-language pinning and gender context.
///
/// DeepL preserves words it reads as proper nouns. A lone word sent WITH the
/// personal context string ("She wrote the following about herself…") is the
/// worst case: e.g. "apple" comes back as "apple" instead of תפוח, the proxy
/// stores it as the Hebrew translation, and every later batch skips the row
/// as "current" — so the message is never translated and no error is logged
/// anywhere. To catch exactly that, when DeepL echoes the source text back
/// unchanged (and the context parameter was sent), retry ONCE without context:
/// a bare word usually translates literally. Whatever the retry returns is
/// stored as-is — the stored blob doubles as the done-marker, so storing
/// nothing would make every client batch re-send it to DeepL forever.
/// Exported for unit tests.
export async function translateWithSourceValidation(
  text: string,
  targetLang: string,
  deepLBaseUrl: string,
  apiKey: string,
  clientSourceLang?: string,
  opts?: { context?: string },
): Promise<{ translatedText: string; detectedSource: string }> {
  const sourceLang = clientSourceLang;

  const context = opts?.context?.trim();
  const result = await callDeepLTranslate(
    text,
    targetLang,
    deepLBaseUrl,
    apiKey,
    sourceLang,
    context ? context.slice(0, 500) : undefined,
  );

  const echoedSource =
    text.trim().length > 0 &&
    result.translatedText.trim().toLowerCase() ===
      text.trim().toLowerCase() &&
    result.detectedSource !== targetLang.toLowerCase();
  if (echoedSource && context) {
    console.log(
      `[translate-proxy] DeepL echoed source ("${text.slice(0, 40)}"); ` +
        `retrying once without context`,
    );
    return await callDeepLTranslate(
      text,
      targetLang,
      deepLBaseUrl,
      apiKey,
      sourceLang,
      undefined,
    );
  }
  return result;
}

/// Single DeepL round trip (with its own 429/5xx retries). Extracted from
/// [translateWithSourceValidation] so the echo-retry above reuses it.
async function callDeepLTranslate(
  text: string,
  targetLang: string,
  deepLBaseUrl: string,
  apiKey: string,
  sourceLang: string | undefined,
  context: string | undefined,
): Promise<{ translatedText: string; detectedSource: string }> {
  const body: Record<string, any> = {
    text: [text],
    target_lang: targetLang.toUpperCase(),
    preserve_formatting: true,
  };
  if (sourceLang) body.source_lang = sourceLang.toUpperCase();
  if (context) body.context = context;
  console.log(
    `[translate-proxy] DeepL request target=${targetLang.toUpperCase()} ` +
    `source=${sourceLang ? sourceLang.toUpperCase() : "auto"} ` +
    `context=${context ? "yes(" + context.slice(0, 80) + ")" : "no"} ` +
    `chars=${text.length}`,
  );

  const maxAttempts = 3;
  let lastError: unknown = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    let res: Response;
    try {
      res = await fetch(`${deepLBaseUrl}/translate`, {
        method: "POST",
        headers: { Authorization: `DeepL-Auth-Key ${apiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
    } catch (e) {
      lastError = e; // network-level failure: retryable
      if (attempt < maxAttempts) {
        await new Promise((r) => setTimeout(r, 400 * 2 ** (attempt - 1)));
        continue;
      }
      throw e;
    }
    if (res.ok) {
      const data = await res.json();
      return {
        translatedText: data.translations[0].text,
        detectedSource: data.translations[0].detected_source_language?.toLowerCase() ?? "und",
      };
    }
    const traceId = res.headers.get("x-trace-id") ?? res.headers.get("X-Trace-ID") ?? "n/a";
    let errBody = "";
    try {
      errBody = JSON.stringify(await res.json());
    } catch {
      try {
        errBody = await res.text();
      } catch {
        errBody = "";
      }
    }
    console.error(`[translate-proxy] DeepL API failed: status=${res.status} trace=${traceId} body=${errBody.slice(0, 300)}`);
    if (res.status === 400 || res.status === 456) {
      throw new Error(`DeepL API failed: ${res.status}`);
    }
    lastError = new Error(`DeepL API failed: ${res.status}`);
    if ((res.status === 429 || res.status >= 500) && attempt < maxAttempts) {
      await new Promise((r) => setTimeout(r, 400 * 2 ** (attempt - 1)));
      continue;
    }
    throw lastError;
  }
  throw lastError instanceof Error ? lastError : new Error("DeepL API failed");
}



serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const requestId = crypto.randomUUID();
  const startedAt = Date.now();

  try {
    const body = await req.json();
    const mode = body.mode || "webhook";

    if (mode === "client_assisted_translation_v1") {
      return await handleClientAssistedTranslation(req, body, requestId, startedAt);
    }

    // Handle direct client calls authenticated via JWT.
    // Unlike the old body-field sniffing, ANY request with mode === "direct"
    // uses JWT auth so that missing/renamed fields never cause a fall-through
    // to webhook secret validation (which would log "Invalid webhook secret").
    if (mode === "direct") {
      const authHeader = req.headers.get("authorization") || "";
      const userClient = createClient(SUPABASE_URL, ANON_KEY, {
        auth: { persistSession: false },
        global: { headers: { Authorization: authHeader } },
      });
      const { data: userData, error: userErr } = await userClient.auth.getUser();
      if (userErr || !userData?.user) {
        return new Response(
          JSON.stringify({ error: "Forbidden" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
      return await handleDirectClientTranslation(req, body, userData.user.id, requestId, startedAt);
    }

    const record = body.record;
    if (!record || !record.id) {
      return new Response(
        JSON.stringify({ error: "Invalid webhook payload" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const messageId = record.id;
    const { data: msgRow, error: msgErr } = await supabase
      .from("chat_messages")
      .select("*")
      .eq("id", messageId)
      .maybeSingle();

    if (msgErr || !msgRow) {
      return new Response(
        JSON.stringify({ error: "Message not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (msgRow.encryption_scheme !== "v1") {
      return new Response(
        JSON.stringify({ status: "unsupported_encryption_scheme" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    return await handleEncryptedWebhook(req, msgRow, requestId, startedAt);
  } catch (error) {
    console.error("[translate-proxy] Error:", error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : "Unknown error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});

async function handleEncryptedWebhook(
  req: Request,
  record: any,
  requestId: string,
  startedAt: number,
): Promise<Response> {
  if (!record.wrapped_keys?.supabase) {
    return new Response(
      JSON.stringify({ status: "not_translation_capable" }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // Use the top-level sender_key_id column, not wrapped_keys.supabase.sender_key_id
  // (the client does not store sender_key_id inside wrapped_keys).
  const senderKeyId = record.sender_key_id;
  const supabaseKeyId = SUPABASE_TRANSLATION_KEY_ID;

  if (!senderKeyId) {
    return new Response(
      JSON.stringify({ error: "Sender key not found" }),
      { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  const { data: senderKeyRow } = await supabase
    .from("user_chat_keys")
    .select("public_key")
    .eq("id", senderKeyId)
    .maybeSingle();

  if (!senderKeyRow) {
    return new Response(
      JSON.stringify({ error: "Sender key not found" }),
      { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // Always decrypt the message so we can determine the push-notification body.
  // (The body must never be "New message" — it must be the actual message text.)
  let plaintextStr: string;
  let messageKey: Uint8Array;
  try {
    const { privateKey } = await getSupabaseKeyPair();
    const senderPublicKeyBytes = base64Decode(senderKeyRow.public_key);
    const sharedSecret = await x25519SharedSecret(privateKey, senderPublicKeyBytes);
    const messageIdBytes = new TextEncoder().encode(record.id);
    const wrapKey = await hkdfSha256(
      sharedSecret,
      messageIdBytes,
      "matchme-supabase-translation-key-wrap-v1",
    );

    const supabaseWrapNonce = base64Decode(record.wrapped_keys.supabase.nonce);
    const supabaseWrapCiphertext = base64Decode(record.wrapped_keys.supabase.ciphertext);
    const wrapAad = new TextEncoder().encode(
      `matchme.chat.v1|wrap|supabase|${record.id}|${senderKeyId}|${supabaseKeyId}`,
    );

    messageKey = await aesGcmDecrypt(
      supabaseWrapCiphertext,
      wrapKey,
      supabaseWrapNonce,
      wrapAad as Uint8Array,
    );

    const contentNonce = base64Decode(record.content_original_nonce);
    const contentCiphertext = base64Decode(record.content_original_encrypted);
    const contentAad = new TextEncoder().encode(
      `matchme.chat.v1|original|${record.id}|${record.match_id}|${record.sender_id}|${record.recipient_id || ""}|${senderKeyId}|${record.recipient_key_id || ""}`,
    );

    const plaintext = await aesGcmDecrypt(
      contentCiphertext,
      messageKey,
      contentNonce,
      contentAad as Uint8Array,
    );

    plaintextStr = new TextDecoder().decode(plaintext);
  } catch (error) {
    console.error("[translate-proxy] Decrypt error:", error);
    return new Response(
      JSON.stringify({ status: "decrypt_failed" }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // Look up the recipient's translation preference.
  const { data: chats } = await supabase
    .from("chats")
    .select("translation_enabled, translation_language, user_id")
    .eq("match_id", record.match_id);
  const recipientChat = chats?.find((c) => c.user_id !== record.sender_id);
  const translationEnabled = recipientChat?.translation_enabled === true;
  const targetLang = recipientChat?.translation_language;

  // Determine the body text for the push notification.
  // - Translation enabled + already stored: decrypt the existing translation.
  // - Translation enabled + not yet stored: translate now and store.
  // - Translation enabled but translation/storage failed: keep the message
  //   completely undisclosed until a current translation is ready.
  // - Translation disabled: use the original plaintext.
  let bodyText = plaintextStr;
  let translatedSuccessfully = false;

  if (translationEnabled && !targetLang) {
    return new Response(
      JSON.stringify({ status: "translation_pending", message_id: record.id }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  if (translationEnabled && targetLang) {
    const storedTranslationIsCurrent =
      (record.translated_target_language || "").toLowerCase() === targetLang.toLowerCase() &&
      (record.translated_source_edited_at ?? null) === (record.edited_at ?? null);
    if (record.content_translated_encrypted && record.content_translated_nonce && storedTranslationIsCurrent) {
      // Already translated in a previous run — decrypt the stored translation.
      try {
        const detectedSourceLang = record.detected_source_language || "und";
        const storedTargetLang = (record.translated_target_language || targetLang).toLowerCase();
        const translatedAad = new TextEncoder().encode(
          `matchme.chat.v1|translated|${record.id}|${record.match_id}|${record.sender_id}|${record.recipient_id || ""}|${detectedSourceLang}|${storedTargetLang}|${senderKeyId}|${record.recipient_key_id || ""}`,
        );
        const translatedCiphertext = base64Decode(record.content_translated_encrypted);
        const translatedNonce = base64Decode(record.content_translated_nonce);
        const decryptedTranslated = await aesGcmDecrypt(
          translatedCiphertext,
          messageKey,
          translatedNonce,
          translatedAad as Uint8Array,
        );
        bodyText = new TextDecoder().decode(decryptedTranslated);
        translatedSuccessfully = true;
      } catch (e) {
        console.error("[translate-proxy] Decrypt-translation error; translation is still pending:", e);
        bodyText = "";
      }
    } else {
      // Translate now via DeepL, store, and use the translated text.
      // Gender rule for CHAT: use BOTH sender and recipient genders.
      // - Sender gender for first-person statements ("I am...")
      // - Recipient gender for second-person statements ("You are...")
      // DeepL's context parameter handles both naturally in sentences.
      //
      // Claim the row first so a concurrent batch request (or a webhook
      // redelivery) cannot translate the same message twice.
      const prevTarget = typeof record.translated_target_language === "string"
        ? record.translated_target_language
        : null;
      const webhookClaim = await claimMessageForTranslation(
        record.id,
        targetLang.toLowerCase(),
        prevTarget,
      );
      if (!webhookClaim) {
        // Another worker owns the translation claim. Do not publish the
        // original while that translation is in flight.
        bodyText = "";
      } else {
        try {
          const recipientUserId =
            (record.recipient_id as string | undefined) ||
            chats?.find((c) => c.user_id !== record.sender_id)?.user_id;
          const genderMap = recipientUserId
            ? await fetchUserGenders(record.sender_id, recipientUserId)
            : {};
          const genderContext = buildGenderContext(
            genderMap[record.sender_id],    // SENDER'S GENDER (for first-person statements)
            recipientUserId ? genderMap[recipientUserId] : undefined,  // RECIPIENT'S GENDER (for second-person statements)
          );
          const { translatedText, detectedSource: detectedSourceLang } = await translateWithSourceValidation(
            plaintextStr, targetLang, DEEPL_BASE_URL, DEEPL_API_KEY,
            record.detected_source_language ?? undefined,
            genderContext ? { context: genderContext } : undefined,
          );

          const translatedNonce = generateNonce();
          const translatedAad = new TextEncoder().encode(
            `matchme.chat.v1|translated|${record.id}|${record.match_id}|${record.sender_id}|${record.recipient_id || ""}|${detectedSourceLang || "und"}|${targetLang.toLowerCase()}|${senderKeyId}|${record.recipient_key_id || ""}`,
          );

          const translatedEncrypted = await aesGcmEncrypt(
            new TextEncoder().encode(translatedText),
            messageKey,
            translatedNonce,
            translatedAad as Uint8Array,
          );

          const { data: updatedRows, error: updateErr } = await supabase
            .from("chat_messages")
            .update({
              content_translated_encrypted: base64Encode(translatedEncrypted),
              content_translated_nonce: base64Encode(translatedNonce),
              detected_source_language: detectedSourceLang || "und",
              translated_target_language: targetLang.toLowerCase(),
              // Bind this payload to the content revision just translated so
              // later edits mismatch the marker and trigger one regeneration.
              translated_source_edited_at: (record.edited_at as string | null) ?? null,
            })
            .eq("id", record.id)
            .eq("translated_target_language", webhookClaim)
            .select("id");

          if (updateErr || !updatedRows || updatedRows.length === 0) {
            if (updateErr) {
              console.error(`[translate-proxy] DB update error for webhook message ${record.id}: ${updateErr.message}`);
            }
            await releaseClaim(record.id, webhookClaim, prevTarget);
            bodyText = "";
          } else {
            bodyText = translatedText;
            translatedSuccessfully = true;
          }
        } catch (error) {
          console.error("[translate-proxy] Encrypted translation failed; keeping notification pending:", error);
          await releaseClaim(record.id, webhookClaim, prevTarget);
          bodyText = "";
        }
      }
    }
  }

  if (translationEnabled && !translatedSuccessfully) {
    return new Response(
      JSON.stringify({ status: "translation_pending", message_id: record.id }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // Trigger the push notification with the resolved body text.
  // The push-message edge function is called server-to-server with the
  // MATCHME_INTERNAL_SECRET so the notification body is the real message text
  // (translated or original), never "New message".
  // The Authorization header (service role key) is required to pass the
  // Supabase gateway; the x-matchme-internal header authorizes the
  // translated_message mode inside push-message.
  //
  // For RTL target languages (Hebrew, Arabic, etc.) prepend a Right-to-Left
  // Mark (U+200F). The OS notification renderer doesn't apply the bidi
  // algorithm the same way Flutter's text renderer does, so without the RLM
  // Hebrew punctuation appears on the wrong side. The RLM is zero-width and
  // invisible in the chat UI, but it forces the notification renderer into an
  // RTL context so punctuation lands in the visually correct place.
  const RTL_LANGS = new Set(["he", "ar", "fa", "ur", "yi"]);
  const isRtl = !!(targetLang && RTL_LANGS.has(targetLang.toLowerCase()));
  const bodyForPush = isRtl ? "\u200F" + bodyText : bodyText;

  try {
    const pushRes = await fetch(`${SUPABASE_URL}/functions/v1/push-message`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SERVICE_ROLE_KEY}`,
        "x-matchme-internal": Deno.env.get("MATCHME_INTERNAL_SECRET") ?? "",
      },
      body: JSON.stringify({
        kind: "translated_message",
        message_id: record.id,
        body: bodyForPush,
      }),
    });
    if (!pushRes.ok) {
      console.error(`[translate-proxy] push-message invoke failed status=${pushRes.status}`);
    }
  } catch (e) {
    console.error("[translate-proxy] push-message invoke exception:", e);
  }

  return new Response(
    JSON.stringify({
      status: "success",
      message_id: record.id,
      translated: translatedSuccessfully,
    }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
  );
}

async function handleClientAssistedTranslation(
  req: Request,
  body: any,
  requestId: string,
  startedAt: number,
): Promise<Response> {
  const authHeader = req.headers.get("authorization") || "";
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return new Response(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  const currentUserId = userData.user.id;
  const matchId = body.match_id;
  const targetLanguage = body.target_language;
  const supabaseKeyId = body.supabase_key_id;
  const requestWrappedKey = body.request_wrapped_key;
  const items: Array<{ message_id: string; source_ciphertext: string; source_nonce: string; source_aad: string }> = body.items || [];

  // AI rate limiting (app_config ai.rate_limit.translation.*) — client-initiated
  // DeepL usage counts against the requesting user; the server-driven webhook
  // path is not limited here.
  const rateLimit = await consumeAiRateLimit(supabase, {
    task: "translation",
    userId: currentUserId,
    requestId,
  });
  if (!rateLimit.allowed) {
    console.warn(
      `[translate-proxy] client-assisted rate limited, retryAfter=${rateLimit.retryAfterSeconds}s`,
    );
    return new Response(
      JSON.stringify({ error: "Too many translation requests. Please try again later.", retryAfterSeconds: rateLimit.retryAfterSeconds }),
      { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  if (!matchId || !targetLanguage || !requestWrappedKey || items.length === 0) {
    return new Response(
      JSON.stringify({ error: "Invalid request" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  const { data: matchRow } = await supabase
    .from("matches")
    .select("id, user1_id, user2_id")
    .eq("id", matchId)
    .maybeSingle();

  if (!matchRow || (matchRow.user1_id !== currentUserId && matchRow.user2_id !== currentUserId)) {
    return new Response(
      JSON.stringify({ error: "Not authorized for this match" }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  const { data: chats } = await supabase
    .from("chats")
    .select("translation_enabled, translation_language")
    .eq("match_id", matchId)
    .eq("user_id", currentUserId)
    .maybeSingle();

  if (!chats?.translation_enabled || !chats?.translation_language) {
    return new Response(
      JSON.stringify({ error: "Translation not enabled" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  try {
    const currentUserKeyId = requestWrappedKey.current_user_key_id;
    const { data: userKeyRow } = await supabase
      .from("user_chat_keys")
      .select("public_key")
      .eq("id", currentUserKeyId)
      .eq("user_id", currentUserId)
      .maybeSingle();

    if (!userKeyRow) {
      return new Response(
        JSON.stringify({ error: "User key not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { privateKey } = await getSupabaseKeyPair();
    const userPublicKeyBytes = base64Decode(userKeyRow.public_key);
    const sharedSecret = await x25519SharedSecret(privateKey, userPublicKeyBytes);
    const salt = new TextEncoder().encode(matchId);
    const wrapKey = await hkdfSha256(sharedSecret, salt, "matchme-supabase-translation-key-wrap-v1");

    const reqWrapNonce = base64Decode(requestWrappedKey.nonce);
    const reqWrapCiphertext = base64Decode(requestWrappedKey.ciphertext);
    const reqWrapAad = new TextEncoder().encode(
      `matchme.chat.v1|wrap|supabase|${matchId}|${currentUserKeyId}|${supabaseKeyId}`,
    );

    const kRequest = await aesGcmDecrypt(
      reqWrapCiphertext,
      wrapKey,
      reqWrapNonce,
      reqWrapAad as Uint8Array,
    );

    // Gender rule for CHAT (same as batch path): steer by the ADDRESSEE =
    // current user (requester). One users-table read.
    const assistedGenderMap = await fetchUserGenders(
      matchRow.user1_id,
      matchRow.user2_id,
    );

    const succeeded: Array<{
      message_id: string;
      detected_source_language: string;
      translated_ciphertext: string;
      translated_nonce: string;
      translated_aad: string;
    }> = [];
    const failed: Array<{ message_id: string; error_code: string }> = [];

    for (const item of items) {
      try {
        const { data: msgRow } = await supabase
          .from("chat_messages")
          .select("*")
          .eq("id", item.message_id)
          .eq("match_id", matchId)
          .maybeSingle();

        if (!msgRow) {
          failed.push({ message_id: item.message_id, error_code: "message_not_found" });
          continue;
        }

        const sourceCiphertext = base64Decode(item.source_ciphertext);
        const sourceNonce = base64Decode(item.source_nonce);
        const sourceAad = new TextEncoder().encode(item.source_aad);

        const plaintext = await aesGcmDecrypt(
          sourceCiphertext,
          kRequest,
          sourceNonce,
          sourceAad as Uint8Array,
        );

        const plaintextStr = new TextDecoder().decode(plaintext);

        let translatedText: string;
        let detectedSourceLang: string;
        try {
          const assistedContext = buildGenderContext(
            assistedGenderMap[msgRow.sender_id],    // SENDER'S GENDER (for first-person statements)
            assistedGenderMap[currentUserId],       // RECIPIENT'S GENDER (for second-person statements)
          );
          const result = await translateWithSourceValidation(
            plaintextStr, targetLanguage, DEEPL_BASE_URL, DEEPL_API_KEY,
            undefined,
            assistedContext ? { context: assistedContext } : undefined,
          );
          translatedText = result.translatedText;
          detectedSourceLang = result.detectedSource;
        } catch (_) {
          failed.push({ message_id: item.message_id, error_code: "translation_failed" });
          continue;
        }

        const responseNonce = generateNonce();
        const responseAad = `matchme.chat.v1|client-assisted-translate-response|${item.message_id}|${matchId}|${currentUserId}|${detectedSourceLang}|${targetLanguage}|${currentUserKeyId}|${supabaseKeyId}`;

        const translatedEncrypted = await aesGcmEncrypt(
          new TextEncoder().encode(translatedText),
          kRequest,
          responseNonce,
          new TextEncoder().encode(responseAad) as Uint8Array,
        );

        succeeded.push({
          message_id: item.message_id,
          detected_source_language: detectedSourceLang,
          translated_ciphertext: base64Encode(translatedEncrypted),
          translated_nonce: base64Encode(responseNonce),
          translated_aad: responseAad,
        });
      } catch (itemError) {
        failed.push({ message_id: item.message_id, error_code: "translation_failed" });
      }
    }

    return new Response(
      JSON.stringify({
        mode: "client_assisted_translation_v1",
        match_id: matchId,
        target_language: targetLanguage,
        items: succeeded,
        failed: failed,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("[translate-proxy] Client-assisted error:", error);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
}

// Handle direct client translation requests authenticated via user's JWT.
// Supports two sub-modes:
//   - Single text translation: body has "text" and "target_lang"
//   - Batch database translation: body has "match_id", "target_language", and either "message_ids" or "retranslate_all"
//     A stored translation is reused only when it is current for the target
//     language AND was made for the row's current content (see
//     translationMarkerMatches); an edit always forces exactly one
//     regeneration, no matter how many surfaces request it.
async function handleDirectClientTranslation(
  req: Request,
  body: any,
  currentUserId: string,
  requestId: string,
  startedAt: number,
): Promise<Response> {
  try {
    // AI rate limiting (app_config ai.rate_limit.translation.*).
    const rateLimit = await consumeAiRateLimit(supabase, {
      task: "translation",
      userId: currentUserId,
      requestId,
    });
    if (!rateLimit.allowed) {
      console.warn(
        `[translate-proxy] direct rate limited, retryAfter=${rateLimit.retryAfterSeconds}s`,
      );
      return new Response(
        JSON.stringify({ error: "Too many translation requests. Please try again later.", retryAfterSeconds: rateLimit.retryAfterSeconds }),
        { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // ── Single text translation (for real-time display; profile
    // bio/occupation use this path) ──
    // Gender steering (DeepL-only): a ready-made `context` string or
    // `speaker_gender` / `addressee_gender` values ('male'/'female'; anything
    // else omitted). `context` carries natural pronoun-clue sentences per
    // DeepL's documented effective pattern — never LLM-style instructions.
    // Profile callers send the WRITER's gender as speaker (bio/occupation are
    // first-person self-descriptions); chat callers use the recipient's.
    if (body.text && body.target_lang) {
      const directContext =
        typeof body.context === "string" && body.context.trim()
          ? body.context as string
          : buildGenderContext(body.speaker_gender, body.addressee_gender);
      const directSource =
        typeof body.source_lang === "string" &&
        body.source_lang.trim() &&
        body.source_lang.trim().toLowerCase() !== "auto"
          ? body.source_lang as string
          : undefined;
      const { translatedText, detectedSource } = await translateWithSourceValidation(
        body.text, body.target_lang, DEEPL_BASE_URL, DEEPL_API_KEY,
        directSource,
        directContext ? { context: directContext } : undefined,
      );
      return new Response(
        JSON.stringify({ translatedText, detectedSource }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // ── Batch database translation (for retranslate_all / message_ids) ──
    const matchId = body.match_id;
    const targetLanguage = body.target_language;
    const excludeSenderId = body.exclude_sender_id || "";

    console.log(`[translate-proxy] Batch request — matchId=${matchId} target=${targetLanguage} exclude=${excludeSenderId}`);

    if (!matchId || !targetLanguage) {
      console.warn(`[translate-proxy] Missing match_id or target_language`);
      return new Response(
        JSON.stringify({ error: "Invalid request: missing match_id or target_language" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Verify user belongs to this match
    const { data: matchRow, error: matchErr } = await supabase
      .from("matches")
      .select("id, user1_id, user2_id")
      .eq("id", matchId)
      .maybeSingle();

    if (matchErr) {
      console.error(`[translate-proxy] Match query error: ${matchErr.message}`);
    }
    console.log(`[translate-proxy] Match query result: ${matchRow ? `found (user1=${matchRow.user1_id})` : 'NOT found'}`);

    if (!matchRow || (matchRow.user1_id !== currentUserId && matchRow.user2_id !== currentUserId)) {
      console.warn(`[translate-proxy] User ${currentUserId} not authorized for match ${matchId}`);
      return new Response(
        JSON.stringify({ error: "Not authorized for this match" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Gender rule for CHAT: a match has exactly 2 members, so fetch both
    // genders once. Per message, steer ONLY by the ADDRESSEE (the member who
    // is not the sender — the bubble's reader). See webhook note about the
    // first-person tradeoff.
    const matchGenderMap = await fetchUserGenders(matchRow.user1_id, matchRow.user2_id);

    // Determine which messages to translate
    let messageIds: string[] = [];
    if (body.message_ids && Array.isArray(body.message_ids)) {
      messageIds = body.message_ids;
      console.log(`[translate-proxy] Using message_ids list (${messageIds.length} messages)`);
    } else if (body.retranslate_all) {
      // Fetch all incoming messages that need translation.
      // Translation payload always lives in content_translated_encrypted.
      // A message needs translation if:
      // - no translated payload yet, OR
      // - translated_target_language is NULL, OR
      // - translated_target_language != targetLanguage.
      // NOTE: Broken encrypted translations (content_translated_encrypted exists but undecryptable)
      // are handled client-side: decryption failure clears content_translated_encrypted, then
      // the next batch run picks them up via the "encrypted without translation" condition.
      const query = supabase
        .from("chat_messages")
        .select("id, match_id, sender_id, recipient_id, content_original_encrypted, content_original_nonce, content_translated_encrypted, content_translated_nonce, translated_target_language, encryption_scheme, sender_key_id, recipient_key_id, wrapped_keys")
        .eq("match_id", matchId)
        .or(`content_translated_encrypted.is.null,translated_target_language.is.null,translated_target_language.neq.${targetLanguage.toLowerCase()}`)
        .order("created_at", { ascending: true });

      if (excludeSenderId) {
        query.neq("sender_id", excludeSenderId);
      }

      const { data: msgs, error: msgsErr } = await query;
      if (msgsErr) {
        console.error(`[translate-proxy] Messages query error: ${msgsErr.message}`);
      }
      console.log(`[translate-proxy] Messages query returned ${msgs?.length ?? 0} messages`);
      if (msgs) {
        messageIds = msgs.map((m: any) => m.id);
        console.log(`[translate-proxy] ${messageIds.length} messages need translation`);
      }
    }

    if (messageIds.length === 0) {
      console.log(`[translate-proxy] No messages to translate`);
      return new Response(
        JSON.stringify({ translated: 0 }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Column list for per-message chunk fetches. `translated_source_edited_at`
    // may not exist if its migration has not been applied yet — see
    // fetchChunkMessages for the tolerant fallback.
    const kMessageChunkColumns =
      "id, match_id, sender_id, recipient_id, content_original_encrypted, content_original_nonce, content_translated_encrypted, content_translated_nonce, translated_target_language, translated_source_edited_at, edited_at, encryption_scheme, sender_key_id, recipient_key_id, wrapped_keys";
    const kMessageChunkColumnsLegacy =
      "id, match_id, sender_id, recipient_id, content_original_encrypted, content_original_nonce, content_translated_encrypted, content_translated_nonce, translated_target_language, encryption_scheme, sender_key_id, recipient_key_id, wrapped_keys";

    /// Fetch one chunk of messages, tolerating a database where the
    /// `translated_source_edited_at` migration has not been applied yet. The
    /// marker then reads as undefined, which only ever forces retranslation —
    /// never a stale skip (see translationMarkerMatches).
    async function fetchChunkMessages(chunk: string[]): Promise<any[] | null> {
      const attempt = await supabase
        .from("chat_messages")
        .select(kMessageChunkColumns)
        .in("id", chunk);
      if (!attempt.error) return attempt.data as any[];
      console.error(`[translate-proxy] Chunk fetch error: ${attempt.error.message}`);
      const legacy = await supabase
        .from("chat_messages")
        .select(kMessageChunkColumnsLegacy)
        .in("id", chunk);
      if (legacy.error) {
        console.error(`[translate-proxy] Legacy chunk fetch error: ${legacy.error.message}`);
        return null;
      }
      return legacy.data as any[];
    }

    // Process messages in chunks
    let translated = 0;
    const chunkSize = 10;
    for (let i = 0; i < messageIds.length; i += chunkSize) {
      const chunk = messageIds.slice(i, i + chunkSize);

      const msgs = await fetchChunkMessages(chunk);
      if (!msgs) continue;

      console.log(`[translate-proxy] Processing chunk of ${msgs.length} messages`);

      for (const msg of msgs) {
        // Skip messages whose stored translation is current: same target,
        // encrypted payload present, AND the version marker recorded at
        // translation time still matches the row's edited_at. An edit changes
        // edited_at, so a pre-edit translation never matches and is
        // regenerated here — exactly once, since the write below restamps the
        // marker. Concurrent duplicate requests still dedupe via the claim.
        const normTarget = targetLanguage.toLowerCase();
        const markerOk = translationMarkerMatches(
          msg.translated_source_edited_at ?? null,
          msg.edited_at ?? null,
        );
        if (msg.translated_target_language === normTarget && msg.content_translated_encrypted && markerOk) {
          console.log(`[translate-proxy] Skipping message ${msg.id}: translation current for ${normTarget}`);
          continue;
        }
        // Atomically claim the row before doing any decrypt/DeepL work.
        // Without this, concurrent batch requests all pass the skip check
        // above before any of them writes, and each re-translates the same
        // messages — the exact "same message translated 3x within one
        // second" pattern observed in the edge logs.
        const claimValue = await claimMessageForTranslation(
          msg.id,
          normTarget,
          msg.translated_target_language ?? null,
        );
        if (!claimValue) {
          console.log(
            `[translate-proxy] Skipping message ${msg.id}: translated to or claimed for ${normTarget} by a concurrent request`,
          );
          continue;
        }
        let claimSettled = false;
        try {
        let plaintextStr: string;
        let messageKey: Uint8Array | null = null;

        if (msg.encryption_scheme === "v1") {
          if (!msg.content_original_encrypted || msg.content_original_encrypted.length < 4) {
            console.log(`[translate-proxy] Skipping message ${msg.id}: encrypted content too short`);
            continue;
          }

          const supabaseWrap = msg.wrapped_keys?.supabase;
          if (!supabaseWrap?.nonce || !supabaseWrap?.ciphertext || !msg.sender_key_id) {
            console.log(`[translate-proxy] Skipping message ${msg.id}: missing wrapped keys or sender key`);
            continue;
          }

          const { data: senderKeyRow } = await supabase
            .from("user_chat_keys")
            .select("public_key")
            .eq("id", msg.sender_key_id)
            .maybeSingle();

          if (!senderKeyRow) {
            console.error(`[translate-proxy] Sender key not found for message ${msg.id}`);
            continue;
          }

          const { privateKey } = await getSupabaseKeyPair();
          const senderPublicKeyBytes = base64Decode(senderKeyRow.public_key);
          const sharedSecret = await x25519SharedSecret(privateKey, senderPublicKeyBytes);

          const messageIdBytes = new TextEncoder().encode(msg.id);
          const wrapKey = await hkdfSha256(sharedSecret, messageIdBytes, "matchme-supabase-translation-key-wrap-v1");

          const supabaseWrapNonce = base64Decode(supabaseWrap.nonce);
          const supabaseWrapCiphertext = base64Decode(supabaseWrap.ciphertext);
          const wrapAad = new TextEncoder().encode(
            `matchme.chat.v1|wrap|supabase|${msg.id}|${msg.sender_key_id}|${SUPABASE_TRANSLATION_KEY_ID}`,
          );

          messageKey = await aesGcmDecrypt(
            supabaseWrapCiphertext,
            wrapKey,
            supabaseWrapNonce,
            wrapAad as Uint8Array,
          );

          const contentNonce = base64Decode(msg.content_original_nonce);
          const contentCiphertext = base64Decode(msg.content_original_encrypted);
          const contentAad = new TextEncoder().encode(
            `matchme.chat.v1|original|${msg.id}|${msg.match_id}|${msg.sender_id}|${msg.recipient_id || ""}|${msg.sender_key_id}|${msg.recipient_key_id || ""}`,
          );

          const plaintext = await aesGcmDecrypt(
            contentCiphertext,
            messageKey,
            contentNonce,
            contentAad as Uint8Array,
          );

          plaintextStr = new TextDecoder().decode(plaintext);

          console.log(`[translate-proxy] Translating encrypted message ${msg.id} (${plaintextStr.length} chars)`);
        } else {
          console.log(`[translate-proxy] Skipping message ${msg.id}: unsupported encryption scheme ${msg.encryption_scheme}`);
          continue;
        }

        // Skip emoji-only / whitespace-only messages — DeepL can't translate them
        // and returns garbled output.  Strip emoji/pictographic ranges + whitespace
        // and check if any real text remains.
        const strippedForCheck = plaintextStr
          .replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE00}-\u{FE0F}\u{200D}\u{20E3}\u{E0020}-\u{E007F}]/gu, '')
          .replace(/[\s]/g, '')
          .trim();
        if (strippedForCheck.length === 0) {
          console.log(`[translate-proxy] Skipping message ${msg.id}: emoji/whitespace-only (${plaintextStr.length} chars)`);
          continue;
        }

        let translatedText: string;
        let detectedSource: string;
        try {
          const addresseeId =
            (msg.recipient_id as string | undefined) ||
            (msg.sender_id === matchRow.user1_id ? matchRow.user2_id : matchRow.user1_id);
          const genderContext = buildGenderContext(
            matchGenderMap[msg.sender_id],    // SENDER'S GENDER (for first-person statements)
            matchGenderMap[addresseeId],      // RECIPIENT'S GENDER (for second-person statements)
          );
          const result = await translateWithSourceValidation(
            plaintextStr, targetLanguage, DEEPL_BASE_URL, DEEPL_API_KEY,
            body.source_language as string | undefined,
            genderContext ? { context: genderContext } : undefined,
          );
          translatedText = result.translatedText;
          detectedSource = result.detectedSource;
        } catch (e) {
          console.error(`[translate-proxy] DeepL API error for message ${msg.id}: ${e}`);
          continue;
        }

        // Re-verify the content version after the (slow) DeepL round trip: an
        // edit landing meanwhile must not receive this now-stale translation.
        // Skipping the write here is safe — the newer edit's own batch
        // regenerates it — and the finally block releases our claim.
        try {
          const recheck = await supabase
            .from("chat_messages")
            .select("edited_at")
            .eq("id", msg.id)
            .maybeSingle();
          if (recheck.data && !translationMarkerMatches(msg.edited_at ?? null, (recheck.data as any).edited_at ?? null)) {
            console.log(`[translate-proxy] Message ${msg.id} edited during translation — discarding stale result`);
            continue;
          }
        } catch {
          // Best-effort only: on lookup failure proceed to the write, whose
          // CAS still guards against clobbering a newer owner.
        }

        if (msg.encryption_scheme === "v1" && messageKey) {
          const translatedNonce = generateNonce();
          const translatedAad = new TextEncoder().encode(
            `matchme.chat.v1|translated|${msg.id}|${msg.match_id}|${msg.sender_id}|${msg.recipient_id || ""}|${detectedSource || "und"}|${targetLanguage.toLowerCase()}|${msg.sender_key_id}|${msg.recipient_key_id || ""}`,
          );

          const translatedEncrypted = await aesGcmEncrypt(
            new TextEncoder().encode(translatedText),
            messageKey,
            translatedNonce,
            translatedAad as Uint8Array,
          );

          // CAS from our claim marker to the final target language: if the
          // claim was stolen (stale-reclaimed after a language switch), the
          // write matches 0 rows and we do not clobber the newer owner.
          // The version marker binds this payload to the content revision we
          // actually translated (rechecked above), so later edits mismatch it
          // and trigger exactly one regeneration.
          const { data: updatedRows, error: updateErr } = await supabase
            .from("chat_messages")
            .update({
              content_translated_encrypted: base64Encode(translatedEncrypted),
              content_translated_nonce: base64Encode(translatedNonce),
              detected_source_language: detectedSource || "und",
              translated_target_language: targetLanguage.toLowerCase(),
              translated_source_edited_at: (msg.edited_at as string | null) ?? null,
            })
            .eq("id", msg.id)
            .eq("translated_target_language", claimValue)
            .select("id");

          if (updateErr) {
            console.error(`[translate-proxy] DB update error for encrypted message ${msg.id}: ${updateErr.message}`);
          } else if (updatedRows && updatedRows.length > 0) {
            claimSettled = true;
            console.log(`[translate-proxy] Successfully translated encrypted message ${msg.id} -> ${translatedText.substring(0, 40)}...`);
          } else {
            console.log(`[translate-proxy] Claim lost for message ${msg.id} before final write — discarding our translation`);
          }
        } else {
          const { data: updatedRows, error: updateErr } = await supabase
            .from("chat_messages")
            .update({
              content_translated_encrypted: translatedText,
              content_translated_nonce: null,
              detected_source_language: detectedSource || "und",
              translated_target_language: targetLanguage.toLowerCase(),
              translated_source_edited_at: (msg.edited_at as string | null) ?? null,
            })
            .eq("id", msg.id)
            .eq("translated_target_language", claimValue)
            .select("id");

          if (updateErr) {
            console.error(`[translate-proxy] DB update error for message ${msg.id}: ${updateErr.message}`);
          } else if (updatedRows && updatedRows.length > 0) {
            claimSettled = true;
            console.log(`[translate-proxy] Successfully translated message ${msg.id} -> ${translatedText.substring(0, 40)}...`);
          } else {
            console.log(`[translate-proxy] Claim lost for message ${msg.id} before final write — discarding our translation`);
          }
        }

        if (claimSettled) translated++;
        } catch (itemError) {
          console.error(`[translate-proxy] Skipping message ${msg.id} due to decryption/processing error: ${itemError instanceof Error ? `${itemError.name}: ${itemError.message}` : itemError}`);
        } finally {
          // Every path that did not settle the claim (skip-continues, decrypt
          // failure, DeepL failure, lost claim) must give it back so the
          // message is not blocked until the stale-marker timeout.
          if (!claimSettled) {
            await releaseClaim(msg.id, claimValue, msg.translated_target_language ?? null);
          }
        }
      }
    }

    console.log(`[translate-proxy] Batch complete: ${translated} messages translated`);
    return new Response(
      JSON.stringify({ translated }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("[translate-proxy] Direct client translation error:", error);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
}
