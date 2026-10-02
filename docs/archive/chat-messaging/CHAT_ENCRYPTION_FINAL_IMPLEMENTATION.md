# Chat Encryption Final Implementation Specification

## Status

This is the build-ready specification for encrypted chat messages and encrypted translation support in MatchMe.

It replaces `CHAT_ENCRYPTION_PLAN.md` as the implementation source of truth, incorporates `ENCRYPTION_PLAN_REVIEW.md`, and resolves the open issues identified in `CHAT_ENCRYPTION_REVISED_IMPLEMENTATION.md`.

No implementation decision is intentionally left open. If code constraints expose a contradiction, the implementation must be updated to preserve the security properties in this document rather than silently weakening them.

---

## 1. Final Decisions

| Topic | Final decision |
|-------|----------------|
| Message encryption | AES-256-GCM with one random 32-byte message key per message. |
| Key agreement | X25519 for user-to-user and user-to-Supabase wrapping. |
| Key derivation | HKDF-SHA256 for all non-password key derivation. |
| Message key wrapping | AES-256-GCM wrapping, not AES-KW, to keep Dart and Deno implementation consistent. |
| Password KDF | PBKDF2-HMAC-SHA256, 600000 iterations, 16-byte random salt minimum. |
| Passwordless/OAuth/passkey recovery | Universal random chat recovery key for every user. |
| `users.id` as key material | Forbidden. It is public, stable, and not secret. |
| Supabase translation public key | Hardcoded in app binary for v1. `app_config` may expose metadata only. |
| Supabase translation private key | Edge Function secret only. Never stored in DB. |
| Local cache | Encrypted before message encryption can be called at-rest encryption. |
| Legacy plaintext rows | Readable forever; optional opportunistic migration after v1 launch. |
| Recipient without active key | Block encrypted send and show a warning; allow explicit plaintext fallback only during rollout. |
| Forward secrecy | Not provided in v1. Explicitly documented. |
| Admin message recovery | Not provided. No master key. |
| DeepL plaintext exposure | Allowed only when translation is enabled; must be documented in privacy copy. |
| Plaintext logs | Forbidden everywhere in chat/translation paths. |

---

## 2. Why `users.id` Cannot Derive Chat Keys

Do not derive encryption keys from `users.id`.

Reasons:

- It is not secret. Database readers, logs, URLs, joins, support tooling, and client code can see user IDs.
- It is stable. A stable identifier makes brute-force and correlation easier, not harder.
- It has no meaningful entropy. A UUID is not a user-controlled secret in this context.
- If combined with a server secret, Supabase can derive the same key, which breaks the goal that Supabase cannot read messages when translation is off.
- If combined with OAuth or session tokens, keys become unstable and may become server-readable or expire.

Accepted key-unlock material:

- A high-entropy random chat recovery key generated on the client.
- The account password, used only through a slow password KDF as an extra convenience wrapper.
- A device-local random key stored in secure storage for local cache encryption.

---

## 3. User Recovery Model

### 3.1 Universal Chat Recovery Key

Every user gets a random 256-bit Chat Recovery Key, abbreviated `CRK`.

The CRK:

- Is generated on the client with a CSPRNG.
- Is never sent to Supabase in plaintext.
- Is stored on the current device in `flutter_secure_storage`.
- Wraps the user's X25519 private chat key for cross-device recovery.
- Is shown to the user once as a recovery code during encryption setup.
- Can be re-shown only after the user proves they already have the unlocked CRK on the current device and completes sensitive-action reauth.

Human-readable format:

```text
MMRK1-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-CCCC
```

The payload is 32 random bytes encoded as 52 Crockford Base32 characters, displayed as 13 groups of 4 characters. `CCCC` is a 4-character checksum over the CRK version and payload. Total user-entered body length is 56 Crockford Base32 characters plus separators.

This intentionally keeps the full 256-bit CRK. The shorter 8-group format would encode only 160 bits and must not be used for v1.

Checksum algorithm:

- Checksum input: one version byte `0x01` followed by the raw 32 CRK bytes.
- Algorithm: CRC-16/CCITT-FALSE.
- Polynomial: `0x1021`.
- Initial value: `0xFFFF`.
- Input reflected: no.
- Output reflected: no.
- Final XOR: `0x0000`.
- Encode the 16-bit checksum as two big-endian bytes.
- Crockford Base32 encode those two checksum bytes and left-pad to 4 characters.

Checksum validation happens before any key derivation. The checksum is for typo detection only; it is not a security MAC. The CRK's security comes from the 32 random bytes.

Compatibility note:

- Crockford Base32 defines an optional native modulo-37 checksum.
- MatchMe v1 intentionally uses CRC-16/CCITT-FALSE instead because it provides a 16-bit typo-detection checksum and is simple to implement consistently in Dart and Deno.
- Do not use an off-the-shelf Crockford parser's native checksum mode for CRKs unless it is explicitly configured to bypass modulo-37 validation and return the raw Base32 payload/checksum groups for MatchMe's CRC-16 validation.

Reference Dart implementation:

```dart
int crkChecksum(Uint8List crkBytes) {
  if (crkBytes.length != 32) {
    throw ArgumentError('CRK must be exactly 32 bytes');
  }
  var crc = 0xFFFF;
  final data = Uint8List(33)
    ..[0] = 0x01
    ..setRange(1, 33, crkBytes);
  for (final b in data) {
    crc ^= (b << 8);
    for (var i = 0; i < 8; i++) {
      final highBitSet = (crc & 0x8000) != 0;
      crc = ((crc << 1) & 0xFFFF);
      if (highBitSet) crc ^= 0x1021;
    }
  }
  return crc & 0xFFFF;
}
```

### 3.2 Password Users

Password users get two server-stored encrypted private-key wrappers:

1. `recovery_key` wrapper: private chat key encrypted by a key derived from CRK.
2. `password` wrapper: private chat key encrypted by a key derived from the user's password.

This gives password users a friendly new-device path: sign in with password and unlock automatically. The CRK remains the fallback when the user resets their password or adds passkeys/social login.

### 3.3 Google, Microsoft, Apple, Facebook, Passkey, and OTP Users

These users do not have a stable app password available to the client. They use the CRK wrapper.

User flow:

1. User signs in with OAuth/passkey/OTP.
2. If no unlocked chat key exists locally, app asks for the Chat Recovery Key.
3. If the user enters it correctly, the private chat key unlocks and is stored in secure storage.
4. If the user does not have it, old encrypted messages remain unreadable. The user may create a new chat key for future messages after acknowledging old history cannot be recovered.

### 3.4 OAuth or Passkey User Later Adds a Password

If a user who originally used OAuth, passkey, or OTP later adds a password, the app retroactively adds a `password` wrapper to the existing active chat key.

Flow:

1. Require the user to be authenticated.
2. Require sensitive-action reauth for the password-add operation.
3. Load the existing private chat key from secure storage, or ask for the CRK if the key is not unlocked locally.
4. Derive a PBKDF2 password wrapping key from the new password and a new random salt.
5. Insert `user_chat_key_wrappers.wrapper_type = 'password'` for the existing `user_chat_key_id`.
6. If a password wrapper already exists for that key, replace it.

This is an upgrade of the existing active chat key, not a new key pair. The `UNIQUE (user_chat_key_id, wrapper_type)` constraint remains correct because each key has at most one active wrapper of each type.

### 3.5 First-Time Setup

Encryption setup runs after account creation or first login after the encryption rollout.

Flow:

1. Generate user X25519 key pair.
2. Generate CRK.
3. Encrypt private chat key with CRK-derived wrapping key.
4. If current auth method is password and the plaintext password is available in the signup/login form, also create password wrapper.
5. Store public key and encrypted wrappers in Supabase.
6. Store private chat key and CRK in device secure storage.
7. Show the recovery code and require confirmation that the user saved it.

The app must not block basic profile access if recovery confirmation is skipped during rollout, but encrypted chat must remain locked until setup is completed.

### 3.6 Password Change

On password change:

1. Require sensitive-action reauth: the user must re-enter the current password and complete any active MFA challenge required by the account.
2. Load private chat key from secure storage or ask for CRK.
3. Derive new password wrapping key using PBKDF2-HMAC-SHA256 with a new random salt.
4. Replace only the `password` wrapper.
5. Keep the `recovery_key` wrapper unchanged.
6. Invalidate other sessions using the existing session controls where possible.

The existing Supabase session alone is not sufficient for password-wrapper replacement.

### 3.7 Password Reset

Password reset cannot use the old password wrapper.

After reset:

1. User signs in.
2. App asks for CRK.
3. If CRK is provided, unlock private chat key and create a new password wrapper.
4. If CRK is unavailable, old encrypted messages remain unreadable. User can create a new active chat key for future messages.

This must be explained plainly in UI copy before enabling encryption.

---

## 4. Cryptographic Details

### 4.1 Dependencies

Flutter:

```yaml
dependencies:
  cryptography: ^2.7.0
  flutter_secure_storage: ^9.2.0
```

Deno Edge Functions:

- Use WebCrypto where available for AES-GCM, HKDF, and PBKDF2.
- Use a small audited X25519 implementation if WebCrypto X25519 is unavailable in the deployed Deno runtime.
- Add cross-language test vectors before production.

Secure storage:

- Use `flutter_secure_storage` with Android Keystore-backed storage on Android and Keychain-backed storage on iOS/macOS.
- Prefer the package's encrypted storage defaults across supported devices.
- Do not store CRK, private chat keys, DCK, or password-derived keys in `SharedPreferences`, Hive, logs, or provider state.

### 4.2 Why AES-GCM Wrapping Instead of AES-KW

AES-KW is the conventional standard for wrapping keys, but v1 uses AES-GCM wrapping for implementation consistency.

Decision:

- Deno/WebCrypto can support AES-KW in many runtimes.
- The chosen Flutter `cryptography` dependency supports AES-GCM, X25519, HKDF, and PBKDF2, but does not provide a first-class AES-KW API across all MatchMe targets.
- Adding a separate AES-KW dependency only for key wrapping increases platform and audit surface.
- AES-GCM is a standard AEAD. It is acceptable for wrapping random 32-byte message keys when every wrap uses a fresh random 12-byte nonce and authenticated AAD.

Trade-off:

- AES-GCM wrapping requires storing a nonce per wrapped key.
- Nonce reuse under the same wrapping key is catastrophic, so nonces must come from a CSPRNG and must never be derived deterministically.
- AES-KW may be reconsidered in a future version if a single audited implementation works across Flutter mobile, Flutter web, and Deno.

### 4.3 Password KDF

Use PBKDF2-HMAC-SHA256:

- Iterations: `600000`.
- Salt: 16 random bytes minimum, 32 preferred.
- Output length: 32 bytes.
- Store KDF metadata per wrapper.

This follows current OWASP guidance for PBKDF2-HMAC-SHA256 when Argon2id is not selected. Argon2id remains a future enhancement, but v1 uses PBKDF2 because it is consistently available across Flutter and WebCrypto/Deno.

Performance requirement:

- Keep `600000` iterations.
- Run derivation asynchronously off the UI-critical path where Flutter permits.
- Use `Isolate.run` or Flutter `compute()` for PBKDF2 where the implementation would otherwise block the UI thread.
- Show a brief loading affordance during login/unlock, especially on older Android devices.
- Do not reduce iterations for perceived responsiveness without a separate security review.

Concurrent unlock/update rule:

- Only one chat-key unlock or wrapper update may run per user at a time.
- `ChatKeyService` must serialize these operations with a per-user in-process lock.
- Server-side wrapper RPCs must be idempotent where possible and rely on the `UNIQUE (user_chat_key_id, wrapper_type)` constraint to prevent duplicate wrappers.
- The in-process lock protects only the current app process. It is not the concurrency boundary.
- If another device updates the same wrapper at the same time, the client must handle database conflict errors gracefully.
- On a unique-constraint conflict for `(user_chat_key_id, wrapper_type)`, the client must refetch the wrapper row, verify it belongs to the same active key, and retry local unlock/state validation instead of surfacing a crash.
- Wrapper replacement RPCs must use row locks or transactional upsert/update semantics so simultaneous devices converge to one valid wrapper state.

### 4.4 CRK KDF

The CRK is high entropy, so it does not need a slow password KDF.

Use HKDF-SHA256:

```text
input key material = decoded CRK bytes
salt = user_chat_keys.recovery_salt
info = "matchme-chat-recovery-key-wrap-v1"
output = 32 bytes
```

### 4.5 Message Encryption

For each new message:

- Generate random `message_key` = 32 bytes.
- Generate random `content_original_nonce` = 12 bytes.
- Encrypt original text with AES-256-GCM.

Original AAD:

```text
matchme.chat.v1|original|message_id|match_id|sender_id|recipient_id|sender_key_id|recipient_key_id
```

Translated AAD:

```text
matchme.chat.v1|translated|message_id|match_id|sender_id|recipient_id|detected_source_language|target_language|sender_key_id|recipient_key_id
```

`detected_source_language` is included because it is known at translation encryption time from DeepL or local language detection. If detection fails, use the literal string `und`. The same normalized source value must be stored in `detected_source_language`; if the DB value is later tampered with, translated ciphertext authentication must fail or the client must ignore the mismatched metadata.

Including key IDs in message AAD is intentional defense in depth. The message ciphertext is bound to the exact sender/recipient key pair used for the row, so tampering with parent key columns, replaying ciphertext under a different key version, or swapping encrypted payloads between key epochs fails authentication.

AAD canonicalization:

- All AAD values are canonicalized before concatenation.
- UUID fields must match lowercase canonical UUID format: `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`.
- Language fields must match `^[a-z]{2,3}(-[a-z0-9]{2,8})?$` after lowercasing, or the literal `und`.
- Supabase translation key IDs must match `^[a-z0-9._:-]{1,80}$`.
- Any value containing `|`, whitespace, control characters, or unrecognized Unicode must be rejected before encryption/decryption.
- Do not parse AAD by splitting attacker-controlled strings. Build AAD only from validated typed values.

Nonce policy:

- Every AES-GCM encryption uses a fresh random 12-byte nonce from a CSPRNG.
- Nonces are never derived from message IDs, timestamps, counters, or key IDs.
- The collision probability for random 96-bit nonces is negligible for v1 scale; birthday-bound risk becomes material only at volumes far beyond expected MatchMe chat usage under the same key.
- If a future version approaches extremely high per-key message volumes, rotate keys or move to deterministic nonce allocation with persistent counters.

### 4.6 Message Key Wrapping

Recipient wrapping:

1. `shared = X25519(sender_private_key, recipient_public_key)`
2. `wrap_key = HKDF(shared, salt = message_id bytes, info = "matchme-recipient-message-key-wrap-v1")`
3. AES-GCM encrypt `message_key` with `wrap_key`, random 12-byte nonce, and wrap AAD.

Supabase translation wrapping:

1. `shared = X25519(sender_private_key, supabase_translation_public_key)`
2. `wrap_key = HKDF(shared, salt = message_id bytes, info = "matchme-supabase-translation-key-wrap-v1")`
3. AES-GCM encrypt `message_key` with `wrap_key`, random 12-byte nonce, and wrap AAD.

Wrap AAD:

```text
matchme.chat.v1|wrap|purpose|message_id|sender_key_id|recipient_or_supabase_key_id
```

Including key IDs in wrap AAD is also intentional. The wrapped message key is bound to the exact key agreement participants before the message key is even available. This duplicates some parent-row metadata on purpose to prevent key-swap attacks and to make each cryptographic object self-authenticating.

---

## 5. Database Schema

### 5.1 `user_chat_keys`

```sql
CREATE TABLE public.user_chat_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  key_version integer NOT NULL,
  public_key bytea NOT NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'retired', 'lost')),
  created_at timestamptz NOT NULL DEFAULT now(),
  activated_at timestamptz NOT NULL DEFAULT now(),
  retired_at timestamptz,
  UNIQUE (user_id, key_version)
);

CREATE UNIQUE INDEX idx_user_chat_keys_one_active
  ON public.user_chat_keys(user_id)
  WHERE status = 'active';
```

### 5.2 `user_chat_key_wrappers`

```sql
CREATE TABLE public.user_chat_key_wrappers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_chat_key_id uuid NOT NULL REFERENCES public.user_chat_keys(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  wrapper_type text NOT NULL
    CHECK (wrapper_type IN ('recovery_key', 'password')),
  kdf text NOT NULL,
  kdf_iterations integer,
  kdf_salt bytea NOT NULL,
  wrap_alg text NOT NULL DEFAULT 'AES-256-GCM',
  wrap_nonce bytea NOT NULL,
  encrypted_private_key bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_chat_key_id, wrapper_type)
);

CREATE INDEX idx_user_chat_key_wrappers_user_id
  ON public.user_chat_key_wrappers(user_id);
```

RLS:

- User can select wrappers for their own keys.
- User can insert/update wrappers only through security-definer RPCs or Edge Functions that verify current auth and recent reauth where needed.
- Matched peers cannot read wrappers.
- Matched peers can read only public key metadata needed to decrypt messages addressed to them.

### 5.3 `chat_messages` Encryption Columns

```sql
ALTER TABLE public.chat_messages
  ADD COLUMN encryption_scheme text NOT NULL DEFAULT 'plaintext'
    CHECK (encryption_scheme IN ('plaintext', 'v1')),
  ADD COLUMN sender_key_id uuid REFERENCES public.user_chat_keys(id),
  ADD COLUMN recipient_key_id uuid REFERENCES public.user_chat_keys(id),
  ADD COLUMN content_original_encrypted bytea,
  ADD COLUMN content_original_nonce bytea,
  ADD COLUMN content_translated_encrypted bytea,
  ADD COLUMN content_translated_nonce bytea,
  ADD COLUMN wrapped_keys jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN translation_capable boolean
    GENERATED ALWAYS AS ((wrapped_keys ? 'supabase')) STORED;

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

Add this soft safety constraint immediately with the encryption-column migration. It catches the most dangerous transition bug: a row marked `v1` that still leaks plaintext into legacy columns.

```sql
ALTER TABLE public.chat_messages ADD CONSTRAINT chat_messages_v1_no_plaintext_chk
CHECK (
  encryption_scheme != 'v1'
  OR (content_original IS NULL AND content_translated IS NULL)
);
```

Soft-constraint failure handling during rollout:

- If an insert/update fails because of `chat_messages_v1_no_plaintext_chk`, the client must not retry the same payload as plaintext.
- The client must treat this as a local encryption serialization bug, keep the encrypted local outbox draft, and show a generic retryable send failure.
- The client must discard the malformed outgoing row payload, rebuild the encrypted insert payload from the local encrypted draft, explicitly set legacy plaintext columns to `NULL`, and retry once.
- If the rebuilt payload still fails, leave the message in the local outbox, log a redacted diagnostic event with error code `v1_plaintext_constraint_failed`, app version, platform, and message ID only, and surface "Message could not be sent. Try again." to the user.
- Server monitoring must alert on any `chat_messages_v1_no_plaintext_chk` violation. Any violation blocks rollout from reaching the strict-constraint phase.

After mixed-mode rollout is stable, add the stricter shape constraint:

```sql
ALTER TABLE public.chat_messages ADD CONSTRAINT chat_messages_encryption_shape_chk
CHECK (
  encryption_scheme = 'plaintext'
  OR (
    encryption_scheme = 'v1'
    AND content_original IS NULL
    AND content_translated IS NULL
    AND content_original_encrypted IS NOT NULL
    AND content_original_nonce IS NOT NULL
    AND sender_key_id IS NOT NULL
    AND recipient_key_id IS NOT NULL
    AND wrapped_keys ? 'recipient'
  )
);
```

### 5.4 Wrapped Keys JSON

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
    "supabase_key_id": "matchme-supabase-translation-2026-05-v1",
    "nonce": "base64",
    "ciphertext": "base64"
  }
}
```

The repeated `sender_key_id` and `recipient_key_id` values inside `wrapped_keys` are intentional.

Validation rule:

- `chat_messages.sender_key_id` must equal `wrapped_keys.recipient.sender_key_id`.
- `chat_messages.recipient_key_id` must equal `wrapped_keys.recipient.recipient_key_id`.
- `chat_messages.sender_key_id` must equal `wrapped_keys.supabase.sender_key_id` when a Supabase wrap exists.
- `wrapped_keys.supabase.supabase_key_id` must equal the configured Supabase translation key ID used by the client.

Reasons for redundancy:

- The wrapped object is self-describing for audits, exports, debugging, and future migrations.
- It prevents accidentally unwrapping a key under a mismatched parent row.
- It allows future per-wrap algorithm changes while preserving one table schema.

`alg` and `kdf` are stored per wrap, not only implied by `encryption_scheme`, so future messages can migrate algorithms without rewriting historical rows.

---

## 6. Supabase Translation Key

### 6.1 Public Key

Create:

```dart
// lib/config/security_constants.dart
class SecurityConstants {
  static const supabaseTranslationKeyId =
      'matchme-supabase-translation-2026-05-v1';
  static const supabaseTranslationPublicKeyBase64 = '<32-byte-x25519-public-key>';
}
```

The app must use this constant for translation wrapping. It must not trust a public key fetched from `app_config`.

### 6.2 Private Key

Store the matching private key only in Supabase Edge Function secrets:

```text
SUPABASE_TRANSLATION_PRIVATE_KEY_BASE64
SUPABASE_TRANSLATION_KEY_ID
```

The private key must never be written to a table, log, migration file, or client asset.

Implementation detail:

- Import/decode the private key at module top level in `translate-proxy`.
- Cache the parsed key material or `CryptoKey` equivalent across warm Edge Function invocations.
- Fall back to per-request import only if the runtime forces it.
- The expected per-request import cost is small, but top-level caching avoids unnecessary latency and keeps implementation intent clear.

### 6.3 Rotation

Rotation requires an app release:

1. Add new public key constant and key ID.
2. Edge Function accepts old and new private keys during transition.
3. Clients use newest public key for new messages.
4. Old messages remain decryptable for translation only if they contain old Supabase-wrapped keys and old private key remains configured.
5. Retire old private key after agreed retention period.

Emergency private-key compromise:

- In v1, there is no breakglass private-key rotation that preserves translation without an app release, because clients need the matching public key to create new Supabase wraps.
- If the Supabase translation private key is compromised, immediately remove the compromised secret from Edge Function configuration and disable encrypted translation.
- Ship an app release with a new hardcoded Supabase translation public key and key ID.
- Deploy Edge Function configuration with the new private key.
- Existing messages wrapped to the compromised key are treated as exposed to whoever obtained both the private key and ciphertext. They remain encrypted to normal database readers, but the translation key can no longer be trusted.
- A brief translation outage is acceptable and preferred over continuing to use a compromised translation key.

---

## 7. Client Message Flow

### 7.1 Send Message, Translation Off

1. Generate `message_id` client-side.
2. Load sender active private chat key.
3. Fetch recipient active public key.
4. Generate message key and nonce.
5. Encrypt plaintext original.
6. Wrap message key for recipient.
7. Insert encrypted row:

Message ID rules:

- `message_id` is globally unique.
- Use UUID v4 generated by a CSPRNG.
- The database primary key or unique constraint on `chat_messages.id` enforces uniqueness.
- The client must never reuse a failed queued message ID for different plaintext. Retries of the same logical draft may reuse the same ID only if the plaintext and match metadata are unchanged.

Recipient key freshness:

- If online, sending requires a fresh active-key lookup no older than 15 minutes.
- If offline, composing may use a cached active key no older than 24 hours and must queue locally.
- Queued offline messages must revalidate and, if needed, rewrap to the recipient's current active key before upload.

```json
{
  "id": "message_id",
  "match_id": "match_id",
  "sender_id": "current_user_id",
  "content_original": null,
  "content_translated": null,
  "encryption_scheme": "v1",
  "sender_key_id": "sender_key_id",
  "recipient_key_id": "recipient_key_id",
  "content_original_encrypted": "bytes",
  "content_original_nonce": "bytes",
  "wrapped_keys": {
    "recipient": {}
  }
}
```

### 7.2 Send Message, Translation On

Same as translation off, plus:

1. Use hardcoded Supabase translation public key.
2. Wrap message key for Supabase.
3. Include `wrapped_keys.supabase`.

### 7.3 Recipient Without an Active Chat Key

If the sender has encryption set up but the recipient has no active `user_chat_keys` row:

1. Do not silently send plaintext.
2. Show the sender a warning that the recipient has not enabled encrypted chat yet.
3. During rollout only, offer an explicit action: `Send unencrypted`.
4. If the sender chooses `Send unencrypted`, insert a legacy-compatible row with `encryption_scheme = 'plaintext'` and no encrypted columns.
5. Mark this as a temporary rollout path. After encryption adoption is high, remove the plaintext fallback and require the recipient to finish encryption setup before new messages can be sent.

The UI must make clear that unencrypted messages are stored as plaintext on the server and cannot later be made truly never-plaintext. They may be opportunistically migrated later, but the original server exposure already happened.

Rollout policy:

- Plaintext fallback is controlled by a remote config flag and minimum app version gate.
- Fallback is available only when either party is below the first encryption-required app version or the recipient lacks an active key during the migration window.
- The migration window is 90 days from the first production release containing encrypted chat.
- The fallback can be removed only after both conditions are true: at least 90 days have passed, and at least 98% of DAU have used an encryption-capable app version for 14 consecutive days.
- Removal is approved by the engineering lead and product owner and recorded in release notes.
- After removal, backend insert policy rejects new plaintext chat rows from supported app versions.
- Emergency re-enable is allowed for at most 7 days through remote config if a rollout incident blocks messaging.

Old app behavior:

- Old app versions may still attempt plaintext sends.
- After the fallback removal date, backend policy must reject plaintext inserts from old app versions when the client version can be identified.
- If client version cannot be identified, the server accepts plaintext only until the 90-day migration window ends; after that, unknown-version plaintext chat inserts are rejected.

### 7.4 Receive Message

1. If `encryption_scheme = 'plaintext'`, use legacy fields.
2. If `v1`, load recipient private chat key.
3. Fetch sender public key by `sender_key_id`.
4. Unwrap message key.
5. Decrypt original.
6. Decrypt translated text if present.
7. Write decrypted display payload only to encrypted local cache.

### 7.5 Decryption Failure

On failure:

1. Refetch `sender_key_id` public key.
2. Retry once.
3. If still failing, mark message as locked and show non-sensitive UI text.
4. Do not delete ciphertext.
5. Do not log plaintext or raw keys.

---

## 8. Translation Flow

### 8.1 New Encrypted Messages

The Edge Function translates only when:

```text
encryption_scheme = 'v1'
translation_capable = true
content_translated_encrypted IS NULL
```

Webhook authentication:

- The webhook endpoint must reject public unauthenticated calls.
- Supabase must send a shared internal secret header, for example `x-matchme-webhook-secret`.
- `translate-proxy` must compare that header to an Edge Function secret using constant-time comparison before reading or trusting the payload.
- Direct client-assisted translation calls use the user's Supabase bearer token and must not be accepted on the webhook path.
- Webhook payloads must be treated only as hints. The Edge Function must refetch the message row by `message_id` using the service role client before decrypting, then validate that the refetched row still meets translation conditions.
- A spoofed request containing arbitrary ciphertext or a target `message_id` must not cause translation unless both webhook authentication and DB refetch validation pass.

It must also check the recipient chat row at execution time:

```text
chats.translation_enabled = true
chats.translation_language IS NOT NULL
```

There is no separate `translation_disabled` column. Translation is gated by the recipient's current chat setting and by the presence of `wrapped_keys.supabase`. This avoids divergent state between a boolean flag and the cryptographic capability encoded in `wrapped_keys`.

Steps:

1. Receive webhook row.
2. Validate `wrapped_keys.supabase`.
3. Load sender public key by `sender_key_id`.
4. Derive Supabase wrapping key.
5. Unwrap message key.
6. Decrypt original text in memory.
7. Send plaintext to DeepL.
8. Encrypt translated text with same message key and a new nonce.
9. Update:
   - `content_translated_encrypted`
   - `content_translated_nonce`
   - `detected_source_language`
   - `translated_target_language`
10. Clear local plaintext references as far as runtime allows.
11. Log only metadata.

### 8.2 Older Encrypted Messages Without Supabase Wrap

For messages lacking `wrapped_keys.supabase`, Supabase cannot decrypt from DB. Use client-assisted translation.

This is a v1 feature, not a v2 enhancement. It is required for the common case where a user sent or received encrypted messages while translation was off, then later enables translation for the chat. Those older messages intentionally lack a Supabase wrap.

Precondition:

- The user's private chat key must be unlocked before client-assisted translation starts.
- If the key is in secure storage but not loaded into memory, load it through `ChatKeyService` first.
- If the key cannot be unlocked, do not start translation; show the locked-message/recovery flow.
- The app must decrypt from the encrypted server row or encrypted local cache only for the duration of the translation operation. Do not store plaintext in Hive or long-lived provider state.

Steps:

1. Client decrypts message locally.
2. Client generates a random 32-byte temporary request key `K_request`.
3. Client encrypts each plaintext message for the request using `K_request`.
4. Client wraps `K_request` for Supabase using the hardcoded Supabase translation public key.
5. Client calls `translate-proxy` direct mode with the wrapped request key and encrypted items.
6. Edge Function unwraps `K_request`, decrypts request items in memory, calls DeepL, and returns translated text encrypted under `K_request`.
7. Client decrypts returned translation.
8. Client encrypts translation for persistent storage using that message's original message key.
9. Client updates `content_translated_encrypted` and `content_translated_nonce`.

The temporary request key is never stored in the database.

Direct request schema:

AAD for each request item:

```text
matchme.chat.v1|client-assisted-translate-request|message_id|match_id|current_user_id|target_language|current_user_key_id|supabase_key_id
```

AAD for each response item:

```text
matchme.chat.v1|client-assisted-translate-response|message_id|match_id|current_user_id|detected_source_language|target_language|current_user_key_id|supabase_key_id
```

These AAD values are encoded as UTF-8 bytes exactly as shown after substituting normalized field values. They are not reused from the original message AAD because the client-assisted request encrypts a temporary transport payload, not persistent message storage.

```json
{
  "mode": "client_assisted_translation_v1",
  "match_id": "uuid",
  "target_language": "es",
  "supabase_key_id": "matchme-supabase-translation-2026-05-v1",
  "request_wrapped_key": {
    "alg": "AES-256-GCM",
    "kdf": "X25519-HKDF-SHA256",
    "current_user_key_id": "uuid",
    "supabase_key_id": "matchme-supabase-translation-2026-05-v1",
    "nonce": "base64",
    "ciphertext": "base64"
  },
  "items": [
    {
      "message_id": "uuid",
      "source_ciphertext": "base64",
      "source_nonce": "base64",
      "source_aad": "matchme.chat.v1|client-assisted-translate-request|<message_id>|<match_id>|<current_user_id>|<target_language>|<current_user_key_id>|<supabase_key_id>"
    }
  ]
}
```

Direct response schema:

```json
{
  "mode": "client_assisted_translation_v1",
  "match_id": "uuid",
  "target_language": "es",
  "items": [
    {
      "message_id": "uuid",
      "detected_source_language": "en",
      "translated_ciphertext": "base64",
      "translated_nonce": "base64",
      "translated_aad": "matchme.chat.v1|client-assisted-translate-response|<message_id>|<match_id>|<current_user_id>|<detected_source_language>|<target_language>|<current_user_key_id>|<supabase_key_id>"
    }
  ],
  "failed": [
    {
      "message_id": "uuid",
      "error_code": "translation_failed"
    }
  ]
}
```

Authentication:

- The direct call must include the current Supabase bearer token.
- The Edge Function must verify the authenticated user belongs to the `match_id`.
- The Edge Function must load `current_user_key_id`, verify it belongs to the authenticated user, and use that public key with the Supabase private key to unwrap `K_request`.
- The Edge Function must verify that each requested `message_id` belongs to the same `match_id`.
- The Edge Function must not accept plaintext request items.

Error handling and retry:

- Item error codes: `locked_message`, `not_authorized`, `message_not_found`, `bad_request_ciphertext`, `translation_disabled`, `translation_failed`, `rate_limited`, `provider_unavailable`.
- The Edge Function returns per-item failures and does not fail the whole batch unless authentication, request-key unwrap, or request schema validation fails.
- The client may retry `rate_limited` and `provider_unavailable` with exponential backoff: 5 seconds, 30 seconds, 2 minutes, then manual retry.
- The client must not retry `locked_message`, `not_authorized`, `message_not_found`, or `bad_request_ciphertext` automatically.
- Failed items are logged by ID and error code only; no plaintext or ciphertext blobs are logged.
- User notification is quiet by default: untranslated locked/failed messages remain in original language with a retry affordance when appropriate.

### 8.3 Legacy Plaintext Messages

Legacy plaintext messages can continue through the existing plaintext translation path until migrated.

When translated after encryption rollout:

- Store plaintext translation only if `encryption_scheme = 'plaintext'`.
- If the client opportunistically migrates the legacy message to `v1`, store only encrypted translation.

---

## 9. Local Cache Encryption

### 9.1 Device Cache Key

Generate one random 256-bit Device Cache Key, `DCK`, per app install and user.

Store:

- `flutter_secure_storage`: `chat_cache_key:<user_id>`

Use:

- Encrypt chat message payloads before writing to Hive.
- If using Hive encrypted boxes is straightforward, use Hive's encrypted box support.
- Otherwise, keep existing boxes but store encrypted JSON blobs.

### 9.2 Cache Loss

If secure storage loses `DCK`:

1. Delete local chat cache boxes for that user.
2. Resync encrypted rows from Supabase.
3. Decrypt again using the private chat key.

Hive encrypted-box behavior:

- Hive encrypted boxes require the same key every time the box is opened.
- If `DCK` is lost, existing encrypted Hive data is orphaned and must be wiped.
- Do not attempt to open or repair encrypted Hive boxes without the original `DCK`.
- If a new `DCK` is generated, it is used only for newly rebuilt cache data after resync.
- If the implementation stores encrypted JSON blobs inside normal Hive boxes instead of Hive encrypted boxes, the same rule applies: loss of `DCK` means wipe local decrypted-cache data and resync.

### 9.3 Cache Scope

Only decrypted display fields are cache-encrypted. Supabase ciphertext and wrapped metadata may be cached as received.

### 9.4 Local Outbox Schema

Use the existing local persistence layer, currently Hive via `LocalDbService`, for the encrypted outbox unless the app later adopts SQLite. The outbox stores encrypted drafts, not plaintext.

Hive box:

```text
chatOutboxBox
```

Key:

```text
chat_outbox:<user_id>:<draft_id>
```

Encrypted payload fields:

```json
{
  "draft_id": "uuid",
  "message_id": "uuid",
  "match_id": "uuid",
  "sender_id": "uuid",
  "recipient_id": "uuid",
  "plaintext_encrypted": "base64",
  "plaintext_nonce": "base64",
  "created_at": "iso8601",
  "updated_at": "iso8601",
  "attempt_count": 0,
  "last_error_code": null,
  "last_error_at": null,
  "intended_translation_enabled": false,
  "original_recipient_key_id": "uuid|null",
  "original_recipient_key_checked_at": "iso8601|null"
}
```

Rules:

- `plaintext_encrypted` is encrypted with the Device Cache Key, not with the message key.
- The message key and final ciphertext are generated immediately before upload, after recipient key revalidation.
- Indexing is by Hive key prefix plus in-memory filtering by `match_id` and `created_at`.
- If the user logs out, local outbox drafts remain encrypted under that user's DCK. If DCK is lost, queued drafts are lost and must not be uploaded.

---

## 10. File Implementation Plan

### 10.1 New Flutter Files

| File | Responsibility |
|------|----------------|
| `lib/config/security_constants.dart` | Supabase translation public key and key ID. |
| `lib/services/crypto_service.dart` | AES-GCM, X25519, HKDF, PBKDF2, CRK encoding/decoding. |
| `lib/services/chat_key_service.dart` | Generate/load/unlock chat keys and wrappers. |
| `lib/services/chat_recovery_service.dart` | CRK creation, validation, display, confirmation, and restore. |
| `lib/services/encrypted_cache_service.dart` | DCK management and encrypted Hive payload helpers. |
| `lib/models/user_chat_key_model.dart` | User key and wrapper models. |
| `lib/providers/chat_key_provider.dart` | Current user's chat key state. |
| `lib/providers/peer_chat_keys_provider.dart` | Peer public keys by key ID. |
| `lib/services/encrypted_chat_outbox_service.dart` | Encrypted queued-message storage, retry scheduling, reconnect processing, and idempotent upload. |
| `lib/services/encrypted_notification_preview_service.dart` | Device-side decryption for optional local notification previews from encrypted FCM payloads. |
| `lib/screens/settings/chat_recovery_screen.dart` | Recovery key status, re-show, regenerate future key flow. |
| `lib/widgets/chat_locked_message.dart` | Non-sensitive locked-message UI. |

### 10.2 Modified Flutter Files

| File | Changes |
|------|---------|
| `pubspec.yaml` | Add `cryptography` and `flutter_secure_storage`. |
| `lib/screens/auth/auth_screen.dart` | After password signup/login, pass password to chat key unlock/setup then clear controller. After OAuth/passkey login, route to CRK unlock if needed. |
| `lib/services/session_service.dart` | Use existing auth-method tracking to decide whether password wrapper can be created. |
| `lib/services/passkey_auth_service.dart` | After passkey session applies, trigger chat key unlock check. |
| `lib/models/chat_message_model.dart` | Add encrypted fields and scheme-aware parsing. Plaintext fields become nullable for `v1`. |
| `lib/providers/chat_provider.dart` | Encrypt sends, decrypt reads/realtime, handle locked state. |
| `lib/services/local_db_service.dart` | Use encrypted cache for message and recent-chat plaintext previews. |
| `lib/services/global_sync_manager.dart` | Sync/decrypt mixed plaintext and encrypted rows. |
| `lib/services/connectivity_restore_coordinator.dart` | Trigger outbox resume with debounce and preserved backoff after connectivity returns. |
| `lib/services/mobile_local_notification_service.dart` | Show decrypted local notification previews when enabled and possible; otherwise show generic notification. |
| `lib/screens/settings/notifications_settings_screen.dart` | Add per-device setting for encrypted chat message previews. |
| `lib/services/platform/deepl_translation_service.dart` | Do not send chat plaintext directly except through specified encrypted direct mode. |
| `lib/services/platform/web_translation_service.dart` | Same. |
| `lib/main.dart` | Initialize secure storage, encrypted cache, and chat key provider after Supabase session recovery. |

### 10.3 Modified Supabase Files

| File | Changes |
|------|---------|
| `supabase/functions/translate-proxy/index.ts` | Add encrypted webhook mode and encrypted direct mode; remove plaintext logs. |
| `supabase/functions/push-message/index.ts` | For encrypted rows, notification body must be generic and payload must include only non-plaintext routing metadata needed for optional device-side preview. |
| New migration | `user_chat_keys`, `user_chat_key_wrappers`, chat encryption columns, RLS, indexes. |
| New RPC | `create_or_replace_chat_key_wrapper` with auth checks. |
| New RPC | `get_peer_chat_public_keys` constrained to matched users/referenced key IDs. |
| New RPC | `replace_lost_chat_key(p_lost_key_id uuid, p_new_public_key bytea, p_reauth_token text)` marks the current active key `lost`, allocates the next `key_version`, inserts the new active key, and returns the new `user_chat_keys.id`. Requires authenticated user ownership, recent sensitive-action reauth, and a row lock on that user's key set. |

---

## 11. UI and User Flow

### 11.0 UX Principles for Encryption Failures

Encryption must feel calm and dependable. Most technical failures are handled silently.

Rules:

- All user-facing copy for encryption, recovery, locked messages, queued sends, translation failures, and retry states must come from Supabase's `translations` table in the user's current UI language.
- The app must include English fallback strings in code for every new user-facing key, used when Supabase is unreachable, offline, missing the key, or translation download fails.
- Do not show cryptographic jargon to users.
- Do not say "key", "ciphertext", "decrypt", "corrupt", "failed authentication", or "security error" in normal user-facing copy.
- Do not imply data loss unless the user is in a confirmed lost-recovery flow.
- Prefer neutral, familiar language: "Still sending", "Waiting for connection", "Refresh needed", "Restore chat access".
- User interruption happens only after automatic recovery has failed or the user must provide a recovery secret.
- All retryable failures remain retryable from the UI.
- A message must never disappear because an encryption operation failed.
- When in doubt, preserve the local encrypted draft and show calm pending state.

User-facing states:

| State | UI behavior | Translation key | English fallback |
|-------|-------------|-----------------|------------------|
| Sending encrypted message | Show normal outgoing bubble with subtle pending indicator. | none | No text unless user opens details. |
| Temporary send failure | Keep bubble pending and retry silently. | none | No banner. |
| Repeated send failure | Keep bubble with retry icon. | `chatEncryptedSendRetry` | "Message not sent. Tap to retry." |
| Offline | Keep compose/send available; queue locally. | `chatWaitingForConnection` | "Waiting for connection" |
| Chat key locked | Show locked placeholders only where needed. | `chatRestoreAccessToView` | "Restore chat access to view this message." |
| Translation pending | Show original message. | `chatTranslating` | "Translating..." |
| Translation failed after retries | Keep original message and retry affordance. | `chatTranslationRetry` | "Translation unavailable. Tap to retry." |
| Recipient not ready for encrypted chat | Block encrypted send with calm explanation. | `chatEncryptedRecipientNotReady` | "This chat is not ready for encrypted messages yet." |
| Lost recovery key with no unlocked device | Explicit confirmation flow. | `chatRecoveryLostHistoryWarning` | "Old encrypted messages cannot be restored without your recovery key." |

Localization implementation:

- Add all new translation keys to Supabase migrations/seeds for supported locales.
- Add English fallback constants in the client near the localization/error fallback layer.
- If the user's current locale value is missing, fallback order is current locale -> English from Supabase -> English code fallback.
- Offline mode uses the last cached translations; if absent, it uses English code fallback.
- Diagnostics may log missing translation keys, but must not log message content, CRK, keys, or ciphertext.

### 11.0.1 Retry and Escalation Policy

Silent retry is the default.

Message send retry schedule:

- Immediate retry once after rebuilding the encrypted payload.
- Then 5 seconds.
- Then 30 seconds.
- Then 2 minutes.
- Then 10 minutes while app is active or background sync is available.
- After 5 failed attempts, show the retry icon on the message bubble.

Translation retry schedule:

- Immediate retry once for transient provider/network errors.
- Then 30 seconds.
- Then 5 minutes.
- After 3 failed attempts, keep original text visible and show manual retry.

Chat key unlock retry:

- If secure-storage load fails transiently, retry once silently.
- If recovery wrapper fetch fails because of network/offline state, defer until online and show locked placeholders only if the user tries to open locked content.
- If the user enters an invalid CRK, show a calm validation error immediately because user input is required.

No background retry may send plaintext as a fallback.

### 11.0.2 Offline and Flapping Connectivity

The app must tolerate offline mode and repeated online/offline transitions.

Offline send behavior:

- Compose remains available if the sender's private chat key is unlocked.
- Draft is stored in the encrypted local outbox under the Device Cache Key.
- If the recipient active key cache is fresh enough, the app may show the message as queued.
- Upload waits until connectivity and Supabase availability are restored.
- Before upload, recipient active key is revalidated and the message is re-encrypted/rewrapped if needed.

Offline receive behavior:

- Already cached decrypted display content remains available from encrypted local cache.
- Messages not yet decrypted remain locked/pending until online sync can fetch ciphertext and keys.
- The app does not attempt server translation offline.

Connectivity flapping:

- Use a single outbox worker per user.
- Debounce reconnect processing by at least 2 seconds.
- Pause retries while Supabase is marked unavailable by the existing offline coordinator.
- Resume with backoff state preserved, not reset to rapid-fire retries.
- Outbox processing must be idempotent: a message insert either succeeds once by `message_id`, or the client treats duplicate success as sent.

User-facing offline copy:

- Global offline indicator can remain as the app already uses.
- Message-level copy should be quiet: "Waiting for connection".
- Do not show encryption-specific warnings for normal offline queuing.

### 11.0.3 Failsafes

Failsafes that must exist before release:

- Encrypted local outbox for unsent messages.
- Idempotent message IDs and duplicate insert handling.
- Automatic payload rebuild if soft plaintext constraint fails.
- Recipient key revalidation before uploading queued messages.
- Peer public key refetch on decrypt failure.
- Locked-message UI instead of destructive deletion.
- Translation fallback to original text.
- Generic push notifications.
- Redacted diagnostics for engineering without plaintext, keys, CRK, or ciphertext blobs.

### 11.1 Encryption Setup Prompt

Shown when:

- User is authenticated.
- User has no active chat key.
- User opens chat or settings.

Copy requirements:

- Explain that chat messages will be encrypted.
- Explain that recovery key is needed if they change devices or reset password.
- Explain that MatchMe cannot recover old encrypted messages if recovery key is lost.

Actions:

- `Set up encrypted chat`
- `Not now`

`Not now` allows app usage but disables sending encrypted chat until setup is complete.

### 11.2 Recovery Key Confirmation

After generating CRK:

1. Show recovery key.
2. Offer copy and download/share-to-password-manager where platform allows.
3. Ask user to enter the last 8 characters or select matching groups.
4. Mark `recovery_confirmed_at` in local secure storage and optionally DB metadata.

### 11.3 New Device Unlock

After login:

- If private chat key exists in secure storage: no prompt.
- Else if password wrapper exists and current login has password available: unlock automatically.
- Else ask for recovery key.
- If skipped, show locked message placeholders and allow new-key creation only after warning.

Definition of "password available":

- Password is available only in the email/password auth flow, after `supabase.auth.signInWithPassword` succeeds and before `_passwordController` is cleared.
- Password is not available for Google, Microsoft, Apple, Facebook, passkey, OTP, recovered sessions, refresh-token restores, or OAuth callbacks.
- The auth screen must call `ChatKeyService.unlockAfterPasswordAuth(email, password)` immediately after successful password authentication and before clearing the password field.
- The password must never be logged, stored in `SharedPreferences`, stored in Hive, sent to a custom Edge Function, or retained in provider state.
- After PBKDF2 derives the wrapper key and the chat key unlock attempt completes, clear the text controller and any local variable references. Dart strings cannot be reliably zeroized, so the implementation must minimize lifetime and copies.

### 11.4 Lost Recovery Key

If user lost CRK but still has one unlocked device:

1. Require sensitive-action reauth.
2. Generate new CRK.
3. Replace the existing `recovery_key` wrapper for the current active key using an update/upsert, not a blind insert.
4. Show and confirm new CRK.

If no unlocked device exists:

- Old encrypted messages are unrecoverable.
- User can create a new active chat key.
- Future messages use the new key.
- Old messages remain locked.

Creating a new active chat key after lost recovery is a destructive one-way flow:

1. User signs in and chooses `Start fresh encrypted chat`.
2. UI explains that old encrypted messages will remain unreadable permanently unless the old CRK is later found on another unlocked device.
3. User completes sensitive-action reauth.
4. Client generates a new X25519 key pair and new CRK.
5. Client calls a security-definer RPC, `replace_lost_chat_key`, which marks the current active key as `lost`, allocates `key_version = previous_max + 1`, and inserts the new public key.
6. Client creates `recovery_key` and, when possible, `password` wrappers for the new key.
7. New outgoing messages use the new active key. Historical ciphertext addressed to the lost key is not deleted, but remains locked.

---

## 12. Key Rotation

### 12.1 Normal Rotation

Manual rotation only in v1.

Steps:

1. Generate new user chat key pair.
2. Set old active key to `retired`.
3. Set new key to `active`.
4. Future outgoing messages use new key.
5. Old private key remains stored and wrapped so historical messages remain readable.

### 12.2 Lost Key

If private key cannot be recovered:

1. Mark old key `lost`.
2. Generate new active key.
3. Historical messages addressed to lost key remain unreadable.
4. Future messages use new key.

### 12.3 Peer Cache

Cache public keys by `user_chat_keys.id`. Never cache only by user ID.

When receiving a message, always use `sender_key_id` and `recipient_key_id` from the message row.

Invalidation and refresh strategy:

- Public keys referenced by `user_chat_keys.id` are immutable and may be cached indefinitely.
- The "active key for user X" lookup is mutable and has a 15-minute TTL.
- Opening a chat always refreshes the peer's active key if the cached active-key lookup is older than 15 minutes.
- App resume refreshes active keys for visible/recent chats.
- Decryption never depends on the active-key cache; it uses the key IDs stored on each message.
- Sending while online requires a fresh active-key lookup no older than 15 minutes.
- Sending while offline may queue an encrypted message using a cached active key no older than 24 hours.
- When the app reconnects, queued messages must revalidate the recipient's active key before upload. If the recipient rotated keys while the sender was offline, re-encrypt the queued message to the new active key before insert.
- If revalidation fails, keep the message in the local outbox and show a retryable send error.

Queued-message rewrap mechanics:

- The local outbox stores the sender plaintext draft encrypted under the Device Cache Key, plus draft metadata.
- Before upload, the app decrypts the local draft in memory, fetches the recipient's current active public key, generates a fresh message key and nonce, encrypts the message content again, wraps the new message key to the current recipient key, and updates `recipient_key_id`.
- The app must not upload the stale queued ciphertext or stale `recipient_key_id`.
- If any step fails, leave the encrypted local draft in the outbox, discard transient plaintext references, and surface a retryable send error.

---

## 13. Notifications

Server-sent encrypted message notifications must not include message text.

Default server notification body:

```text
New message
```

or localized equivalent.

Plaintext legacy rows may continue old behavior only until encryption rollout is complete. Recommended: switch all server-sent chat notifications to generic text immediately.

### 13.1 Optional Device-Side Message Previews

Users may enable per-device notification previews for encrypted chats.

Setting:

- Name: `Show message previews on this device`.
- Scope: per user, per device.
- Default for new installs: off.
- Existing users may be prompted once after migration to choose whether to enable previews.
- Applies to both translation-enabled and translation-disabled chats.
- Stored locally and, if synced, stored only as a preference flag; it never changes server plaintext behavior.

When enabled, previews are produced on the device only:

1. FCM sends a generic encrypted-chat notification/data payload with no plaintext.
2. The background message handler wakes if the OS allows it.
3. The app loads the private chat key from secure storage if available.
4. The app fetches or uses included encrypted message metadata.
5. The app decrypts the message locally.
6. The app shows a local notification with the decrypted preview using `flutter_local_notifications`.

If any step fails, the app shows or leaves the generic notification.

No plaintext preview is generated by Supabase, Edge Functions, or FCM.

### 13.2 FCM Payload Shape

FCM payload for encrypted chat must be data-minimal and plaintext-free:

```json
{
  "type": "chat_message",
  "message_id": "uuid",
  "match_id": "uuid",
  "sender_id": "uuid",
  "encryption_scheme": "v1",
  "preview_capable": "true"
}
```

The payload must not contain:

- `content_original`
- `content_translated`
- decrypted message text
- CRK
- private keys
- message keys
- wrapped key blobs unless the client cannot fetch the row and the payload size/security review explicitly permits including the encrypted row metadata

Preferred v1 behavior:

- FCM contains IDs only.
- Background handler fetches the encrypted message row from Supabase before local preview.
- If fetch is unavailable because the device is offline or the OS background window is too short, show generic notification.

### 13.3 Platform Limits and Fallbacks

Device-side previews are best effort.

Android:

- Background FCM handlers can often run and fetch/decrypt, subject to battery restrictions, Doze, OEM policies, and app force-stop state.
- If the app was force-stopped or background execution is blocked, the notification remains generic.

iOS:

- Silent/data pushes and background processing are limited by APNs, user settings, Focus modes, low-power mode, and OS scheduling.
- If iOS does not wake the app in time, the notification remains generic.

Web/desktop:

- Support depends on platform notification APIs and available secure key storage.
- If local decryption is unavailable, use generic notification.

The user-facing promise must be: previews appear when this device can safely decrypt in the background. Generic notifications are expected fallback behavior, not an error.

### 13.4 Preview Content Rules

When local preview succeeds:

- If the chat's translation setting and encrypted translated content are available locally, preview may show the translated text.
- Otherwise preview shows the decrypted original text.
- If the message is media, deleted, locked, or too large, show a localized generic message type preview.
- Respect OS-level notification privacy settings. If the OS hides notification content on lock screen, do not bypass it.
- Respect in-app blocked/muted chat settings before showing a local preview.
- Do not write the preview plaintext to logs, analytics, FCM payloads, or unencrypted local storage.

### 13.5 Localization for Notifications

Notification title/body fallback text must follow the same localization rules as Section 11:

- Use Supabase `translations` table in the user's current UI language when cached/available.
- Use cached translations offline.
- Use English code fallback if translations are unavailable.

Required keys:

| Key | English fallback |
|-----|------------------|
| `chatNotificationNewMessage` | "New message" |
| `chatNotificationEncryptedPreviewUnavailable` | "New message" |
| `chatNotificationPhoto` | "Photo" |
| `chatNotificationMedia` | "Media message" |
| `chatNotificationLocked` | "New message" |

### 13.6 Acceptance Rules for Previews

- Server-side push never contains plaintext for encrypted rows.
- If the user disables previews, encrypted chat notifications remain generic.
- If the user enables previews, local preview is attempted for translation-enabled and translation-disabled chats.
- If local decryption fails, no user-visible error appears; the generic notification remains.
- Local preview failures are logged only as redacted diagnostics with message ID, platform, and failure category.

---

## 14. Logging and Observability

Forbidden:

- Original message text.
- Translated message text.
- Recovery keys.
- Private keys.
- Message keys.
- Full wrapped key blobs.
- Full ciphertext blobs.
- OAuth/provider tokens.

Allowed:

- IDs.
- Counts.
- Status codes.
- Encryption scheme.
- Key IDs.
- Message length.
- Failure category.
- Timings.

The existing `translate-proxy` logs must be cleaned before encrypted translation is enabled.

---

## 15. Rollout Sequence

### Phase 1 - Foundation

1. Add dependencies.
2. Implement `CryptoService`.
3. Add Dart unit tests.
4. Add Deno crypto helpers.
5. Add Dart/Deno cross-language vectors.

Required tests:

- AES-GCM decrypt succeeds.
- AES-GCM tamper fails.
- X25519 shared secret matches both sides.
- HKDF labels produce different keys.
- PBKDF2 output matches vector.
- CRK checksum catches typo.
- Dart-encrypted message decrypts in Deno and vice versa.

### Phase 2 - Schema

1. Add key tables and wrappers.
2. Add chat encryption columns.
3. Add indexes.
4. Add RLS.
5. Add the soft `chat_messages_v1_no_plaintext_chk` constraint immediately.
6. Do not add the strict shape constraint until app supports mixed mode.

### Phase 3 - Key Setup and Recovery

1. Add chat key setup after auth.
2. Add CRK generation/confirmation.
3. Add password wrapper creation for password users.
4. Add new-device unlock flow.
5. Add lost-key flow.

### Phase 4 - Encrypted Local Cache

1. Add DCK.
2. Encrypt chat cache writes.
3. Migrate existing plaintext cache by wiping and resyncing, not by in-place encryption.

### Phase 5 - Encrypted Send/Receive

1. Encrypt all new outgoing messages.
2. Read mixed plaintext/encrypted rows.
3. Realtime decrypts encrypted rows.
4. Server-sent notifications are generic and plaintext-free.
5. Add optional device-side local notification previews.
6. Add encrypted outbox processing and quiet retry UI.
7. Verify offline send, reconnect, duplicate insert, key-rotation rewrap behavior, and notification preview fallback behavior.

### Phase 6 - Encrypted Translation

1. Add hardcoded Supabase translation public key.
2. Add Edge Function private key secret.
3. Rewrite `translate-proxy`.
4. Support new encrypted webhook flow.
5. Support client-assisted old-message flow.

### Phase 7 - Constraints and Cleanup

1. Add DB check constraint.
2. Remove plaintext selects from encrypted paths.
3. Disable plaintext notification bodies.
4. Optional: opportunistically migrate legacy plaintext messages.

Operational definition of "rollout is stable":

- At least 14 days have passed since the encrypted-send app version was released to production.
- At least 95% of DAU are on an app version that can read `encryption_scheme = 'v1'`.
- At least 98% of DAU are on an app version that can send encrypted messages or handle the recipient-no-key warning.
- There have been zero `chat_messages_v1_no_plaintext_chk` violations in production.
- There are no open Sev 1 or Sev 2 incidents related to chat send, receive, unlock, or translation.
- Engineering lead and product owner approve applying `chat_messages_encryption_shape_chk`, and the decision is recorded in release notes.

Do not apply the strict shape constraint before all conditions are true.

---

## 16. Acceptance Criteria

Encryption is complete only when all criteria pass:

- All rows inserted after the encryption feature is enabled in the app, the sender has completed encryption setup, and the recipient has an active chat key have `encryption_scheme = 'v1'`.
- During the 90-day rollout window only, explicit sender-approved plaintext fallback rows may use `encryption_scheme = 'plaintext'`.
- New encrypted rows have `content_original IS NULL`.
- New encrypted rows have `content_translated IS NULL`.
- DB has the soft constraint preventing `v1` rows from containing plaintext in legacy columns.
- Supabase DB cannot show plaintext for new messages.
- Translation off rows do not include `wrapped_keys.supabase`.
- Translation on rows include `wrapped_keys.supabase`.
- Edge Function can translate only translation-capable rows.
- Edge Function also checks recipient `chats.translation_enabled` at execution time.
- DeepL receives plaintext only for translation-enabled messages.
- Sender sees an explicit warning if recipient has no active chat key; plaintext fallback is explicit and rollout-only.
- Local Hive cache does not store plaintext message JSON.
- Password user can unlock on a second device with password.
- OAuth/passkey user can unlock on a second device with CRK.
- Password reset plus CRK restores access and creates new password wrapper.
- Password reset without CRK leaves old messages locked.
- Lost-key flow creates a new active key without deleting old ciphertext.
- Notifications never include encrypted message plaintext.
- FCM payloads for encrypted rows never include plaintext message previews.
- Optional notification previews are generated only by local device-side decryption when the user enables previews on that device.
- If local notification preview generation fails or the OS does not wake the app, the user receives a generic localized notification.
- Logs contain no plaintext messages, keys, recovery keys, or tokens.
- Legacy plaintext messages remain readable.
- Offline composed messages are stored only in encrypted local outbox.
- Flapping connectivity does not duplicate messages or reset retry loops aggressively.
- Users see calm retry/offline/locked/translation-unavailable copy, not cryptographic error text.
- Technical failures are silently retried according to the retry schedule before user-facing errors appear.

---

## 17. Privacy Copy Requirements

User-facing encryption setup must communicate:

- Messages are encrypted before being stored.
- MatchMe cannot read encrypted messages unless translation is enabled for that message.
- When translation is enabled, message text is temporarily decrypted to translate and sent to DeepL.
- Recovery key is required to read old encrypted messages on a new device if password unlock is unavailable or password was reset.
- MatchMe cannot recover old encrypted chat history if the recovery key is lost and no unlocked device remains.

---

## 18. References

- `CHAT_ENCRYPTION_PLAN.md`
- `ENCRYPTION_PLAN_REVIEW.md`
- `CHAT_ENCRYPTION_REVISED_IMPLEMENTATION.md`
- OWASP Password Storage Cheat Sheet: Argon2id preferred; PBKDF2-HMAC-SHA256 requires 600000 or more iterations when PBKDF2 is used.

---

## 19. Final Implementation Rule

Prefer user safety over silent convenience.

If a user cannot unlock their private chat key, the app must show locked messages and offer recovery/new-key flows. It must never fall back to server-derived keys, `users.id`, OAuth tokens, shared app secrets, or any mechanism that lets Supabase read translation-off messages.
