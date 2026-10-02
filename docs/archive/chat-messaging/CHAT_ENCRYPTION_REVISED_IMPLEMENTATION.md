# Chat Message Encryption - Revised Implementation Plan

## Source Documents

This document supersedes the first implementation draft while preserving its core design. It is based on:

- `CHAT_ENCRYPTION_PLAN.md` - original architecture and phased implementation plan.
- `ENCRYPTION_PLAN_REVIEW.md` - review findings and pre-implementation concerns.
- Additional engineering review notes from Codex, focused on the current MatchMe Flutter/Supabase codebase.

The revised position is: the architecture is directionally sound, but the implementation must include stronger key authenticity, authentication recovery, local cache encryption, key versioning, and plaintext logging controls before development begins.

---

## 1. Goals and Non-Goals

### Goals

| Goal | Revised requirement |
|------|---------------------|
| Database at-rest encryption | New chat messages must not store plaintext in `chat_messages.content_original` or `chat_messages.content_translated`. |
| Encrypted client/server transport | App-to-Supabase chat payloads must contain ciphertext, except legacy plaintext rows. TLS still remains required. |
| Translation-aware privacy | Supabase/Edge Functions can decrypt only messages that include an explicit Supabase-wrapped message key. |
| Backward compatibility | Existing plaintext rows remain readable while new rows use encryption scheme `v1`. |
| Cross-device support | Users can recover their chat private key on a new device using an approved account recovery mechanism. |
| Offline support | Decrypted local cache remains available offline, but the cache itself must be encrypted. |
| Operational clarity | Key rotation, password reset, passkey/social login, and translation failure modes must be specified before rollout. |

### Non-Goals for v1

- Full forward secrecy via Double Ratchet or X3DH.
- Admin/master-key message recovery.
- Hiding message metadata such as sender, recipient, match ID, timestamp, message length, or translation state.
- Preventing DeepL from receiving plaintext when translation is enabled.

Forward secrecy may be a future v2. In v1, compromise of a user's long-term private chat key can expose historical messages that were wrapped for that key.

---

## 2. Security Decisions

### 2.1 Cryptographic Primitives

| Purpose | Primitive | Notes |
|---------|-----------|-------|
| User chat key agreement | X25519 | One or more versioned long-term key pairs per user. |
| Supabase translation key agreement | X25519 | Private key stored only as Edge Function secret. Public key must be authenticated. |
| Message encryption | AES-256-GCM | Random 32-byte key and 12-byte nonce per encrypted field. |
| Key derivation | HKDF-SHA256 | Separate `info` labels for recipient, Supabase, private-key wrapping, and cache keys. |
| Private-key recovery wrapping | Argon2id preferred, PBKDF2 fallback | If Flutter/web support blocks Argon2id, use PBKDF2-SHA256 with calibrated iterations. |
| Message key wrapping | AES-GCM wrapping preferred unless AES-KW is proven available | AES-KW is acceptable if supported across Flutter and Deno. Otherwise use AES-GCM with random wrap nonce. |

The original plan proposed AES-KW. That remains cryptographically acceptable, but implementation should first verify support in both Dart and Deno. If support is awkward or inconsistent, use AES-GCM for wrapping with explicit nonce storage.

### 2.2 Authenticated Additional Data

Every AES-GCM operation must bind ciphertext to stable metadata.

Original message AAD:

```text
matchme.chat.v1|original|message_id|match_id|sender_id|recipient_id
```

Translated message AAD:

```text
matchme.chat.v1|translated|message_id|match_id|sender_id|recipient_id|target_language
```

Wrapped message key AAD:

```text
matchme.chat.v1|wrap|message_id|recipient_key_id|sender_key_id|purpose
```

This prevents swapping original/translated ciphertexts or moving ciphertext between messages.

### 2.3 Public Key Authenticity

The original plan stored the Supabase public key in `app_config`. That is not sufficient as a trust anchor.

Use one of these approaches before implementation:

1. Preferred: hardcode the active Supabase translation public key in the app binary in `lib/config/security_constants.dart`.
2. Flexible: fetch a signed key manifest from `app_config`, but verify it with a hardcoded root signing public key.

For v1, use the hardcoded public key unless frequent key rotation is required. `app_config` may expose key metadata for diagnostics, but clients must not trust an unsigned DB value as the translation public key.

### 2.4 Plaintext Logging Ban

The current `translate-proxy` logs plaintext-like fields and request previews. The encryption implementation must remove all message content logging.

Allowed logs:

- Message ID.
- Match ID.
- Sender/recipient IDs.
- Encryption scheme.
- Translation status.
- Error category.
- Lengths and timing.

Forbidden logs:

- Original message text.
- Translated message text.
- Decrypted request body.
- Raw ciphertext or wrapped key blobs unless explicitly redacted/truncated for diagnostics.

---

## 3. Revised Data Model

### 3.1 User Chat Keys

Use versioned keys from the start. Even if rotation is not exposed in the UI yet, old messages need a stable key ID.

```sql
CREATE TABLE public.user_chat_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  key_version integer NOT NULL,
  public_key bytea NOT NULL,
  encrypted_private_key bytea,
  private_key_wrap_salt bytea,
  private_key_wrap_kdf text NOT NULL DEFAULT 'pbkdf2-sha256',
  private_key_wrap_iterations integer,
  private_key_wrap_nonce bytea,
  private_key_wrap_aad text,
  recovery_method text NOT NULL DEFAULT 'password',
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  activated_at timestamptz NOT NULL DEFAULT now(),
  retired_at timestamptz,
  UNIQUE (user_id, key_version)
);

CREATE UNIQUE INDEX idx_user_chat_keys_one_active
  ON public.user_chat_keys(user_id)
  WHERE status = 'active';
```

RLS rules:

- Users can select their own private-key wrapping fields.
- Matched peers can select only active or referenced public keys.
- Service role can select public keys for translation flows and maintenance.
- Direct client updates to `encrypted_private_key` should be blocked except through a validated RPC/Edge Function.

### 3.2 Chat Message Columns

```sql
ALTER TABLE public.chat_messages
  ADD COLUMN encryption_scheme text NOT NULL DEFAULT 'plaintext',
  ADD COLUMN sender_key_id uuid REFERENCES public.user_chat_keys(id),
  ADD COLUMN recipient_key_id uuid REFERENCES public.user_chat_keys(id),
  ADD COLUMN content_original_encrypted bytea,
  ADD COLUMN content_original_nonce bytea,
  ADD COLUMN content_translated_encrypted bytea,
  ADD COLUMN content_translated_nonce bytea,
  ADD COLUMN wrapped_keys jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN translation_capable boolean
    GENERATED ALWAYS AS ((wrapped_keys ? 'supabase')) STORED,
  ADD COLUMN translation_disabled boolean NOT NULL DEFAULT false;

CREATE INDEX idx_chat_messages_encryption_scheme
  ON public.chat_messages(encryption_scheme);

CREATE INDEX idx_chat_messages_translation_capable
  ON public.chat_messages(translation_capable)
  WHERE translation_capable = true;

CREATE INDEX idx_chat_messages_sender_key_id
  ON public.chat_messages(sender_key_id);

CREATE INDEX idx_chat_messages_recipient_key_id
  ON public.chat_messages(recipient_key_id);
```

For encrypted rows:

- `content_original` must be `NULL`.
- `content_translated` must be `NULL`.
- `content_original_encrypted` and `content_original_nonce` must be non-null.
- `sender_key_id`, `recipient_key_id`, and `wrapped_keys.recipient` must be non-null.

Use a check constraint after rollout has been validated:

```sql
ALTER TABLE public.chat_messages ADD CONSTRAINT chat_messages_encryption_shape_chk
CHECK (
  encryption_scheme = 'plaintext'
  OR (
    encryption_scheme = 'v1'
    AND content_original IS NULL
    AND content_original_encrypted IS NOT NULL
    AND content_original_nonce IS NOT NULL
    AND sender_key_id IS NOT NULL
    AND recipient_key_id IS NOT NULL
    AND wrapped_keys ? 'recipient'
  )
);
```

### 3.3 Wrapped Keys Shape

Use structured metadata instead of raw base64 strings.

```json
{
  "recipient": {
    "alg": "AES-256-GCM",
    "kdf": "X25519-HKDF-SHA256",
    "sender_key_id": "uuid",
    "recipient_key_id": "uuid",
    "nonce": "base64",
    "ciphertext": "base64"
  },
  "supabase": {
    "alg": "AES-256-GCM",
    "kdf": "X25519-HKDF-SHA256",
    "sender_key_id": "uuid",
    "supabase_key_id": "2026-05-v1",
    "nonce": "base64",
    "ciphertext": "base64"
  }
}
```

If AES-KW is used instead of AES-GCM wrapping, omit `nonce` and set `alg` to `AES-KW`.

---

## 4. Key Recovery and Login

### 4.1 Password Users

For password-based accounts:

1. Generate a random salt per user chat key.
2. Derive a wrapping key from the user's entered password.
3. Encrypt the private chat key with AES-GCM.
4. Store encrypted private key, salt, KDF name, iteration count, nonce, and recovery method in `user_chat_keys`.

PBKDF2 minimum:

- `PBKDF2-HMAC-SHA256`
- At least `310000` iterations, calibrated so old devices remain usable.
- 16-byte or larger random salt.

Argon2id is preferred if supported consistently across mobile and web.

### 4.2 Passkey, Social, OTP, and Passwordless Users

This app already has passkey and connected-account flows, so encryption cannot rely only on a reusable password.

Choose one supported recovery policy:

1. Recovery passphrase: user creates a separate chat recovery passphrase during encryption setup.
2. Recovery code: app generates a high-entropy recovery code; user must store it.
3. Device-only mode: private key remains only on current device; cross-device chat history is unavailable until a recovery method is configured.

Recommended v1 policy:

- Password accounts use password wrapping.
- Passwordless/passkey/social accounts must create a chat recovery passphrase before encrypted chat is enabled.
- If the user skips recovery setup, keep encrypted chat disabled for that account or make cross-device recovery explicitly unavailable.

### 4.3 Password Change

Password changes must not directly update `encrypted_private_key` from the client.

Required flow:

1. User reauthenticates using Supabase or an existing sensitive-action verification flow.
2. Client decrypts old private chat key locally.
3. Client derives new wrapping key.
4. Client sends the newly encrypted private key to a validated RPC/Edge Function.
5. Server verifies the user session and recent reauthentication before update.
6. Server updates wrapping metadata and optionally invalidates other sessions.

### 4.4 Password Reset or Lost Recovery Secret

If the user cannot decrypt their private chat key, historical encrypted messages cannot be recovered without a separate recovery secret or admin recovery key.

v1 should not add an admin recovery key. The product should document:

- Password reset can restore account access.
- Password reset cannot restore old encrypted chat history unless the recovery passphrase/code is available.
- The user may create a new chat key after reset; old encrypted messages remain unreadable.

---

## 5. Message Flows

### 5.1 Sending a Message - Translation Off

Client:

1. Generate `message_id` client-side before insert.
2. Load sender active private key and recipient active public key.
3. Generate random message key `K`.
4. Encrypt plaintext into `content_original_encrypted` using AES-GCM and original-message AAD.
5. Derive a recipient wrapping key from X25519(sender private, recipient public) and HKDF.
6. Wrap `K` for the recipient.
7. Insert row with:
   - `encryption_scheme = 'v1'`
   - encrypted content fields
   - `sender_key_id`
   - `recipient_key_id`
   - `wrapped_keys.recipient`
   - plaintext content columns set to `NULL`

Server:

1. Stores opaque ciphertext.
2. Realtime broadcasts encrypted payload.
3. Push notification omits message content.

### 5.2 Sending a Message - Translation On

Same as translation off, plus:

1. Client uses the authenticated Supabase translation public key.
2. Client wraps the same message key `K` for Supabase.
3. Insert includes `wrapped_keys.supabase`.

Supabase can decrypt this message only because the sender explicitly included the Supabase-wrapped key.

### 5.3 Receiving a Message

Client:

1. If `encryption_scheme = 'plaintext'`, use legacy fields.
2. If `encryption_scheme = 'v1'`, load the referenced sender public key by `sender_key_id`.
3. Use recipient private key and sender public key to derive wrapping key.
4. Unwrap message key `K`.
5. Decrypt original message with original-message AAD.
6. If encrypted translation exists, decrypt it with translated-message AAD.
7. Store decrypted display values only in encrypted local cache.

Peer public key cache:

- Cache public keys by `user_chat_keys.id`, not just user ID.
- Pre-fetch active peer public keys at login and when opening chat.
- On decryption failure, refetch the referenced key and retry once.
- Do not evict key IDs referenced by local messages.

### 5.4 Translation Edge Function for New Messages

Trigger condition:

```sql
encryption_scheme = 'v1'
AND translation_capable = true
AND translation_disabled = false
AND content_translated_encrypted IS NULL
```

Edge Function:

1. Receives webhook row.
2. Validates `wrapped_keys.supabase` and `sender_key_id`.
3. Loads sender public key by `sender_key_id`.
4. Derives Supabase wrapping key using Supabase private key.
5. Unwraps message key `K`.
6. Decrypts original content in memory.
7. Sends plaintext to DeepL.
8. Encrypts translated text with `K`, a fresh nonce, and translated-message AAD.
9. Updates only encrypted translation fields and language metadata.
10. Logs no plaintext.

DeepL receives plaintext. This is part of the translation feature and must be reflected in privacy language.

### 5.5 Translation of Older Encrypted Messages

If a message was originally encrypted without `wrapped_keys.supabase`, the Edge Function cannot decrypt it from the database. It also must not unwrap `wrapped_keys.recipient`, because Supabase does not have the recipient's private key.

Use a client-assisted flow:

1. Client decrypts visible old messages locally.
2. Client generates a temporary batch key `K_batch`.
3. Client encrypts each plaintext original into a request payload using `K_batch`.
4. Client wraps `K_batch` for Supabase using the authenticated Supabase public key.
5. Edge Function unwraps `K_batch`, decrypts request items in memory, calls DeepL, and returns encrypted translated results to the client.
6. Client decrypts each translated result.
7. Client writes the translated result back to Supabase encrypted under that message's original message key `K`, using the existing recipient-wrapped key path.

Important refinement: the Edge Function should not permanently store translations encrypted only with `K_batch`, because future devices will not have `K_batch`. Either the client stores the encrypted translations after re-encrypting with each message key, or the request must include a per-message storage key explicitly designed for future decryption.

Recommended v1: client performs the final DB update for older encrypted messages after re-encrypting translations with each original message key. This keeps persistent storage consistent with normal receive flow.

### 5.6 Legacy Plaintext Messages

Legacy plaintext rows can remain readable under `encryption_scheme = 'plaintext'`.

Optional migration:

- When both participants have active chat keys, a client can opportunistically re-encrypt legacy messages it is authorized to read.
- Do not make this a launch blocker.

---

## 6. Local Cache Encryption

The original plan cached decrypted messages in Hive. The review correctly identified this as a privacy gap.

Revised requirement:

- Chat message Hive boxes must be encrypted before claiming at-rest message encryption.
- Derive or generate a local cache key and store it in `flutter_secure_storage`.
- Use Hive encrypted boxes where practical, or encrypt message payloads before writing JSON strings to existing boxes.
- Separate the cache encryption key from message keys using HKDF, for example:

```text
HKDF(user_private_key_material_or_random_device_secret, info="matchme-hive-chat-cache-v1")
```

Practical v1 recommendation:

- Generate a random 256-bit device cache key.
- Store it with `flutter_secure_storage`.
- Use it to encrypt chat/message Hive boxes.
- If secure storage is cleared, wipe encrypted cache and resync/decrypt from Supabase.

This keeps offline support while avoiding plaintext message storage on disk.

---

## 7. Realtime and API Payloads

Realtime encrypted row payload must include:

```json
{
  "id": "uuid",
  "match_id": "uuid",
  "sender_id": "uuid",
  "encryption_scheme": "v1",
  "sender_key_id": "uuid",
  "recipient_key_id": "uuid",
  "content_original_encrypted": "base64",
  "content_original_nonce": "base64",
  "content_translated_encrypted": "base64|null",
  "content_translated_nonce": "base64|null",
  "wrapped_keys": {},
  "detected_source_language": "string|null",
  "translated_target_language": "string|null",
  "created_at": "timestamp",
  "edited_at": "timestamp|null",
  "delivered_at": "timestamp|null",
  "read_at": "timestamp|null",
  "reply_to_message_id": "uuid|null"
}
```

For encrypted rows, plaintext columns should not be selected by app queries except during legacy compatibility paths. Existing selectors in `chat_provider.dart`, `chat_message_model.dart`, `local_db_service.dart`, and `translate-proxy` must be updated from plaintext-first behavior to scheme-aware behavior.

---

## 8. File-Level Implementation Scope

### New Flutter Files

| File | Purpose |
|------|---------|
| `lib/config/security_constants.dart` | Hardcoded Supabase translation public key or root signing key. |
| `lib/services/crypto_service.dart` | Cryptographic primitives, message encrypt/decrypt, wrap/unwrap, KDF helpers. |
| `lib/services/chat_key_service.dart` | User key generation, recovery wrapping, secure storage, key loading. |
| `lib/models/user_chat_key_model.dart` | Versioned key metadata model. |
| `lib/providers/chat_key_provider.dart` | Current user's active chat key and setup state. |
| `lib/providers/peer_chat_keys_provider.dart` | Peer public-key cache by key ID/user ID. |
| `lib/services/encrypted_local_cache_service.dart` | Shared helpers for encrypted Hive payloads or encrypted boxes. |

### Modified Flutter Files

| File | Required changes |
|------|------------------|
| `pubspec.yaml` | Add crypto and secure storage dependencies after primitive support is verified. |
| `lib/models/chat_message_model.dart` | Add encrypted fields, key IDs, scheme-aware parsing, and nullable plaintext fields for encrypted rows. |
| `lib/providers/chat_provider.dart` | Encrypt before insert, decrypt after select/realtime, update translation logic, remove plaintext assumptions. |
| `lib/services/local_db_service.dart` | Encrypt local chat cache and preserve encrypted metadata. |
| `lib/services/global_sync_manager.dart` | Decrypt encrypted rows during sync and handle missing key state. |
| `lib/services/platform/deepl_translation_service.dart` | Stop sending plaintext direct translation requests for chat messages; route chat translation through encrypted path. |
| `lib/services/platform/web_translation_service.dart` | Same as mobile path. |
| `lib/services/session_service.dart` / auth flows | Load or set up chat key after login, handle recovery method. |
| `lib/screens/auth/auth_screen.dart` and passkey/social flows | Capture/setup recovery secret when required. |
| `lib/main.dart` | Initialize secure storage/cache and key providers in startup order. |

### Modified Supabase Files

| File | Required changes |
|------|------------------|
| `supabase/functions/translate-proxy/index.ts` | Decrypt encrypted payloads, translate, encrypt result, remove plaintext logs. |
| New migrations | Add key table, encryption columns, indexes, RLS, and safe transition constraints. |
| Existing chat translation RPCs | Ensure translation toggle affects future wrapping behavior and batch translation requests. |
| Push message function | Ensure notifications never include plaintext message content for encrypted rows. |

---

## 9. Rollout Plan

### Phase 0 - Security Specification

- Confirm primitive support across Flutter mobile, Flutter web, and Deno Edge Functions.
- Decide AES-KW vs AES-GCM wrapping.
- Decide passwordless/passkey recovery policy.
- Generate Supabase translation key pair.
- Add hardcoded public key or signed manifest verification design.
- Define privacy copy for DeepL plaintext processing and unrecoverable chat history.

Do not implement chat encryption before this phase is complete.

### Phase 1 - Crypto Foundation

- Add dependencies.
- Implement `CryptoService`.
- Unit test:
  - AES-GCM encrypt/decrypt.
  - X25519 ECDH shared-secret equality.
  - HKDF label separation.
  - key wrapping/unwrapping.
  - AAD tamper failure.
  - cross-language vectors between Dart and Deno.

### Phase 2 - Schema and RLS

- Add `user_chat_keys`.
- Add encryption columns to `chat_messages`.
- Add indexes and RLS policies.
- Keep plaintext columns during migration.
- Add constraints in permissive form first; tighten after rollout.

### Phase 3 - User Key Setup

- Generate chat keys for password users.
- Add recovery setup for passkey/social/passwordless users.
- Store private key in `flutter_secure_storage`.
- Store encrypted private key in Supabase only through validated flow.

### Phase 4 - Encrypted Local Cache

- Add encrypted cache key management.
- Encrypt chat/message Hive storage.
- Migrate or invalidate old plaintext local cache.

### Phase 5 - Encrypted Send/Receive

- Client inserts encrypted rows for new messages.
- Client can read mixed plaintext and encrypted rows.
- Realtime path decrypts encrypted messages before display.
- Notifications omit content.

### Phase 6 - Translation for New Encrypted Messages

- Rewrite `translate-proxy` encryption path.
- Remove plaintext logs.
- Store encrypted translations.
- Test retries and idempotency.

### Phase 7 - Toggle and Older Message Translation

- Translation ON adds Supabase-wrapped keys only to new outgoing messages.
- Older encrypted messages use the client-assisted translation flow.
- Legacy plaintext messages may continue using legacy translation until migrated, or can be translated and re-stored encrypted after client re-encryption.

### Phase 8 - Tests and Observability

- Multi-device login.
- Password change.
- Password reset/lost recovery secret.
- Passkey/social login.
- Translation ON/OFF transitions.
- Offline open after cache encryption.
- Decryption failure and key refetch.
- Edge Function retry.
- Legacy plaintext compatibility.

---

## 10. Failure Handling

| Failure | Expected behavior |
|---------|-------------------|
| Missing private chat key | Prompt recovery setup/login recovery; do not show encrypted message plaintext. |
| Wrong recovery secret | Decryption fails locally; no server-side recovery of old messages. |
| Missing peer public key | Fetch by `sender_key_id`; retry once; show recoverable error if unavailable. |
| Key rotation mismatch | Use stored `sender_key_id` and `recipient_key_id`; do not assume current active key. |
| Translation function crash | Safe retry; skip update unless full encrypted result is available. |
| Partial batch translation | Prefer per-message idempotent updates; return translated/skipped/failed counts. |
| Local cache key lost | Wipe local cache and resync encrypted rows. |
| Supabase public key mismatch | Disable translation wrapping and surface configuration error. |

---

## 11. Product and Policy Decisions

These decisions should be made explicitly before release:

- No admin message recovery in v1.
- No forward secrecy in v1.
- DeepL receives plaintext only for messages where translation is enabled.
- Password reset cannot recover historical encrypted messages without recovery secret.
- Device compromise can expose messages currently decrypted on that device.
- Message metadata remains visible to Supabase.
- Local cache is encrypted, but unlocked devices can still display cached messages.

---

## 12. Pre-Implementation Checklist

- [ ] Choose and verify crypto primitives in Dart and Deno.
- [ ] Decide recovery policy for passkey/social/passwordless users.
- [ ] Add authenticated Supabase translation public key strategy.
- [ ] Add versioned `user_chat_keys` schema.
- [ ] Add encrypted local cache design.
- [ ] Remove plaintext logging from translation code.
- [ ] Define password change and reset behavior.
- [ ] Define realtime encrypted payload schema.
- [ ] Define push notification behavior for encrypted messages.
- [ ] Add key cache invalidation/refetch rules.
- [ ] Add migration and mixed-mode compatibility tests.
- [ ] Review with a security specialist before production rollout.

---

## 13. Final Recommendation

Proceed with the encryption project only after Phase 0 is complete. The original architecture is a strong foundation, and the review correctly identified the main risks. The revised implementation keeps the practical shape of the original plan but strengthens the parts that would otherwise become production liabilities: public key authenticity, auth recovery, local plaintext cache, key versioning, old-message translation, and logging discipline.

