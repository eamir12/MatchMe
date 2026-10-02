# Chat Message Encryption Plan — Review & Analysis

**Reviewer:** GitHub Copilot  
**Date:** May 22, 2026  
**Status:** Review Complete  
**Overall Score:** 8/10

---

## ✅ **Strong Agreement Areas**

### 1. **Layered Key Approach**
The distinction between long-term keys (user key pair, Supabase key pair) and per-message ephemeral keys is solid. This prevents key reuse attacks and provides good separation of concerns.

### 2. **Password-Derived Key for Private Key Wrapping**
PBKDF2-SHA256 for cross-device recovery is practical and standard. The approach of deriving the same key from the password at login to decrypt the wrapped private key is correct and enables multi-device support without requiring a second authentication factor.

### 3. **X25519 + ECDH for Key Exchange**
Appropriate choice for a simple, proven key derivation mechanism without requiring pre-shared secret infrastructure. X25519 is faster and more resistant to timing attacks than other EC implementations.

### 4. **AES-256-GCM with HKDF Wrapping**
Strong authenticated encryption + key derivation via HKDF is excellent. AAD includes `match_id` for integrity binding, preventing message forgery.

### 5. **Toggle-Aware Design**
Cleanly separating translation ON/OFF by presence of `wrapped_keys.supabase` is elegant and avoids major rewrites when toggling. The ability to mix plaintext and encrypted messages in the same table is pragmatic.

### 6. **Backward Compatibility Strategy**
The `encryption_scheme` field ("plaintext" vs "v1") allows graceful handling of legacy messages without requiring data migration or dual codepaths.

### 7. **One-Time Supabase Decryption**
Restricting server decryption to ephemeral memory during the translation Edge Function is the right approach for minimizing exposure. Plaintext never hits the database.

---

## ⚠️ **Areas of Concern or Disagreement**

### 1. **No Forward Secrecy (Acknowledged but Underspecified)**

**Concern:**  
The document mentions this is "not required" but doesn't justify why. If a user's private key is compromised (stolen device, account breach), **all past and future messages become readable**.

**Recommendation:**  
- At minimum, document this as a known limitation in the main architecture doc.
- If future audit requirements or threat model updates emerge, X3DH or a Double Ratchet protocol would be needed — but acknowledge the complexity cost is high (likely 20-30% implementation effort increase).
- Consider whether this aligns with regulatory requirements (GDPR, CCPA, etc.) for "right to be forgotten."

---

### 2. **Password Derivation Security Details Missing**

**Concern:**  
No specification of:
- PBKDF2 iteration count (should be at least 100,000+ per OWASP 2023; consider 310,000 for 100ms on modern hardware)
- Salt generation and storage (is salt unique per user? How is it persisted?)
- Recovery mechanism if a user forgets their password (private key becomes unrecoverable)
- Whether plaintext password is hashed before derivation or used directly

**Recommendation:**  
- Specify iteration count before implementation (suggest 310,000 minimum).
- Document salt strategy: generate cryptographically random salt per user, store in `user_keys.password_salt`.
- Design a password reset flow that either:
  - Re-encrypts all user messages with a new key pair (destructive but simple), or
  - Uses a recovery code at signup (more complex but better UX)
- Clarify whether Supabase auth password is reused or a separate password needed.

---

### 3. **Private Key Rotation Strategy Unclear**

**Concern:**  
`user_keys` table has `key_rotation_count` but no rotation logic is defined:
- What triggers rotation? (Compromised device? Scheduled every 90 days? Manual?)
- How do old wrapped message keys remain valid if the user's key pair rotates?
- Do old messages remain readable, or does the app maintain a history of key pairs?

**Recommendation:**  
- Either define a comprehensive rotation policy or remove the `key_rotation_count` column to avoid false promises.
- If rotation is planned: maintain a `user_keys_history` table mapping retired key pairs to date ranges, and include the key pair ID in `wrapped_keys` for decryption lookup.
- Document whether rotation is a multi-phase process (announce new key → recipients use it → retire old key).

---

### 4. **On-the-Fly Translation Vulnerability (Section 3.7)**

**Concern:**  
The flow states "the client re-encrypts each message's original from Hive with K_batch" — but this is redundant and the threat model is unclear.

**Why this matters:**  
- Messages already have unique AES keys stored as `wrapped_keys.recipient`.
- Wrapping again with `K_batch` doesn't add security if the Supabase Edge Function can unwrap the original key anyway.
- If the goal is to hide the message identity from the edge function, that's valid but should be explicit.

**Recommendation:**  
- Clarify the threat model: Is it trying to prevent the edge function from knowing **which message belongs to which user**? (Valid concern if so.)
- If privacy is the goal, the current K_batch approach is reasonable; if not, simplify: send `message_ids` list and let the edge function unwrap `wrapped_keys.recipient` directly.
- Document whether the edge function has "right to know" correlations (e.g., user A sent message to user B).

---

### 5. **Supabase Public Key Distribution & Authenticity**

**Concern:**  
Public key stored in `app_config` table — but how is authenticity verified?

**Risk:**  
- If an attacker compromises `app_config` (via SQL injection, leaked credentials, etc.), they could replace Supabase's real key with their own, intercepting all translation requests and decrypting messages.
- No pinning or signature verification mentioned.

**Recommendation:**  
- **Do not** rely solely on runtime database fetch for a trust anchor.
- Options (in order of preference):
  1. **Hardcode in app binary** during build: Store Supabase public key as a constant in `lib/config/security_constants.dart`. Rotate via app update.
  2. **Signed manifest:** Fetch public key from `app_config`, but verify signature with a hardcoded root key (e.g., Supabase's signing key for config updates).
  3. **Certificate pinning:** If served via API, pin the certificate of the signing authority.
- Current approach should be **rejected** as single point of failure.

---

### 6. **Realtime Broadcast Payload Unspecified**

**Concern:**  
States "Realtime broadcasts the new row (still opaque blob)" but doesn't specify which fields are included:
- Is `wrapped_keys` included? (It **must** be, or the recipient can't decrypt.)
- Are old plaintext columns (`content_original`, `content_translated`) excluded or explicitly nulled?
- Is the payload schema identical to what's in the database?

**Recommendation:**  
- Explicitly define the realtime subscription schema:
  ```json
  {
    "id": "uuid",
    "match_id": "uuid",
    "sender_id": "uuid",
    "encryption_scheme": "v1",
    "content_original_encrypted": "base64_bytes",
    "encryption_iv": "base64_bytes",
    "wrapped_keys": {"recipient": "base64", "supabase": null},
    "created_at": "timestamp"
  }
  ```
- Ensure old plaintext columns are **not** included in realtime payloads (schema update required).

---

### 7. **Cross-Device Sync of Peer Public Keys**

**Concern:**  
`peer_keys_provider` caches other users' public keys locally, but no cache invalidation strategy is documented:
- What if a user rotates their key? Do other users' caches eventually invalidate?
- How long is the TTL? (Hours? Days? Indefinite?)
- If not invalidated, old Device B will try to decrypt new messages with a stale key.

**Recommendation:**  
- Define a cache TTL (suggest 24 hours).
- Add `public_key_updated_at` timestamp to `user_keys` table; clients check this field against cached time.
- On decryption failure: fetch fresh public key and retry.
- Consider: should app push a notification when a user's key rotates? (Better UX, prevents silent failures.)

---

### 8. **Password Change Flow Incomplete**

**Concern:**  
Section 3.2 says: "Derive old key from old password, decrypt private key; derive new key from new password, re-encrypt."

**Missing steps:**  
- Who validates that the user entered the **old password correctly**?
- If done on client-side only (without server verification), an attacker with network interception could inject a new wrapped key without the user's knowledge, effectively locking them out.

**Recommendation:**  
- Require the password change endpoint to:
  1. Verify Supabase auth token (already logged in)
  2. Verify old password hash (Supabase JWT claims or additional password check)
  3. Accept new encrypted private key and update `user_keys`
  4. Invalidate all refresh tokens (force re-login on all devices)
- **Never** allow a client to directly update `user_keys.encrypted_private_key` without server-side password verification.

---

### 9. **Hive Cache Security**

**Concern:**  
Decrypted messages are cached in Hive "for offline/performance" (Section 3.5).

**Risk:**  
- Is the Hive database encrypted by default? (Likely not.)
- On a device with a local attacker (jailbroken, rooted, or malware), plaintext cached messages are readable.

**Recommendation:**  
- Either:
  1. Encrypt the Hive cache layer with the same AES key used for the message (or derive a cache encryption key from the user's private key), or
  2. Document this as a known security trade-off in the threat model: "Offline access requires decrypted cache; if device is compromised, messages are readable."
- If encryption is chosen: use a separate cache key derivation (e.g., HKDF with salt="hive-cache") to avoid using the same AES key for multiple purposes.

---

### 10. **Table Schema Efficiency**

**Concern:**  
Storing both `wrapped_keys.recipient` and `wrapped_keys.supabase` in a single JSONB column is fine, but:
- No index on `encryption_scheme` — queries filtering by "plaintext" or "v1" will be slow.
- Large message tables may suffer N+1 queries during initial sync.

**Recommendation:**  
- Add:
  ```sql
  CREATE INDEX idx_chat_messages_encryption_scheme 
    ON chat_messages(encryption_scheme);
  ```
- Consider a `translation_capable` boolean column (denormalized from `wrapped_keys` for performance):
  ```sql
  ALTER TABLE chat_messages ADD COLUMN 
    translation_capable bool GENERATED ALWAYS AS (wrapped_keys->>'supabase' IS NOT NULL) STORED;
  CREATE INDEX idx_chat_messages_translation_capable 
    ON chat_messages(translation_capable) WHERE translation_capable = true;
  ```
- This allows fast filtering of messages eligible for translation.

---

### 11. **Batch Translation Edge Cases**

**Concern:**  
Section 3.7 doesn't specify behavior for:
- A message's sender has rotated their key — can the Supabase function still ECDH with the old key?
- A message was already partially translated — is the cached translation overwritten?
- Batch fails mid-stream (e.g., on message 50 of 100) — are results rolled back?

**Recommendation:**  
- **Key rotation during batch:** Store the key pair ID in `wrapped_keys` metadata or as a separate column (`sender_key_pair_version`). Edge function uses the correct retired key for ECDH.
- **Duplicate translation:** Check if `content_translated_encrypted` already exists; if so, skip or warn.
- **Batch failure:** Use a transaction; if any message fails, rollback all. Alternatively, use a `translation_batch_status` to track partial completion and allow resume.

---

## 🤔 **Questions & Clarifications Needed**

### 1. **Why AES-KW instead of direct XOR or AES-GCM for key wrapping?**
AES-KW is correct (RFC 3394), but the document should explain:
- AES-KW prevents replay attacks and provides authenticity of the wrapped key.
- Direct XOR would require a separate HMAC.
- Why not use AES-GCM? (Valid alternative, but typically KW is chosen for key wrapping to avoid nonce management.)

### 2. **Supabase Edge Function Crash / Atomicity**
If the translate-proxy function crashes mid-translation:
- Are partial updates rolled back?
- Is there a retry mechanism?
- What about idempotency (can the function be safely retried)?

### 3. **"Never Translate This Message" Flag**
Should there be an option for users to mark specific messages as "do not translate"? (E.g., code snippets, personal names, or sensitive identifiers.)

**Recommendation:** Add a `translation_disabled` boolean column; check in Edge Function.

### 4. **Offline Mode: Decryption Without Peer Public Keys**
Can users decrypt old messages while offline if they don't have the peer's public key cached?

**Answer:** No (they need sender's public key for ECDH). But should be pre-cached on first login.

**Recommendation:** Pre-fetch all peer public keys (contacts) on login; store in local cache with expiry.

### 5. **Admin Moderation / Abuse Detection**
Can app admins decrypt user messages for content moderation?

**Current design:** No (good privacy).

**But:** What about legal compliance (law enforcement requests)? Should there be an admin override key pair?

**Recommendation:** Document this as a design decision and consider whether a master recovery key is needed (with strong access controls).

### 6. **Message Deletion & Key Material**
When a user deletes a message:
- Is the AES key also "forgotten"?
- Should Supabase also have a way to delete decrypted translation memory?

**Recommendation:** Document retention and deletion policies for both plaintext and key material.

### 7. **Key Exchange Protocol Synchronization**
If a new user joins a match after the key exchange:
- How do they get the peer's public key? (Fetch from DB, cache it locally, done.)
- But what if the peer's key was rotated before the new user joined? (They use the current key; future messages use new key.)

**Recommendation:** Version the key pair ID in `wrapped_keys` to handle this cleanly.

---

## 📊 **Overall Assessment**

### Strengths
- ✅ Solid cryptographic foundation (X25519, AES-256-GCM, HKDF)
- ✅ Pragmatic backward compatibility
- ✅ Clear separation of concerns (client-side encryption, server-side translation)
- ✅ Implementation order is sensible and incremental

### Weaknesses
- ❌ No forward secrecy (acknowledged but not justified)
- ❌ Critical security gaps in key distribution (public key authenticity)
- ❌ Missing operational details (PBKDF2 parameters, key rotation, cache invalidation)
- ❌ Incomplete threat model for on-the-fly translations

### Risk Level: **Medium**

The design is sound, but several details must be resolved before development:

---

## 🚨 **Highest Priority Fixes (Before Implementation)**

| Priority | Item | Impact |
|----------|------|--------|
| **CRITICAL** | Specify Supabase public key authenticity verification (hardcode or sign) | Security: Single point of failure |
| **CRITICAL** | Define PBKDF2 parameters (iterations, salt handling, storage) | Security: Weak password derivation |
| **HIGH** | Clarify on-the-fly translation threat model and K_batch necessity | Clarity: Current flow may be over-engineered |
| **HIGH** | Document password change server-side validation | Security: Private key injection attack |
| **HIGH** | Define private key rotation policy or remove column | Clarity: Avoid false promises |
| **MEDIUM** | Specify cache invalidation for peer public keys (TTL strategy) | Availability: Silent decryption failures |
| **MEDIUM** | Clarify Hive cache encryption or document as trade-off | Security: Local plaintext exposure |
| **MEDIUM** | Add database indexes for `encryption_scheme` and `translation_capable` | Performance: Large tables will be slow |
| **LOW** | Document "no forward secrecy" as a known limitation | Compliance: Align with audit/regulatory review |

---

## 📋 **Pre-Implementation Checklist**

- [ ] Resolve all CRITICAL items above
- [ ] Write PBKDF2 parameters and password reset flow to a separate document
- [ ] Define Supabase public key distribution strategy and update schema
- [ ] Specify realtime subscription schema explicitly
- [ ] Add cache TTL and invalidation strategy to design
- [ ] Document threat model for on-the-fly batch translation
- [ ] Add database indexes and schema additions
- [ ] Create separate document for key rotation operational procedures
- [ ] Review with security team / external auditor before development starts
- [ ] Plan for future X3DH integration if forward secrecy becomes a requirement

---

## 📝 **Notes for Development Team**

1. **Start with Phase 1 (crypto primitives)** — all downstream phases depend on correct implementations of `encryptMessage`, `decryptMessage`, key wrapping, etc. Unit test heavily.

2. **Edge Function testing is critical** — the translate-proxy Edge Function handles sensitive plaintext. Test failure modes, edge cases, and recovery thoroughly.

3. **Cross-device testing** — multi-device scenarios (login on new device, key rotation, message sync) are complex. Plan for integration tests.

4. **Audit planning** — consider engaging an external security firm to review the implementation of phases 2-6 before release.

5. **User communication** — when rolling out encryption, clearly explain:
   - "What is encrypted and what isn't?"
   - "What happens if I forget my password?"
   - "Can I use multiple devices?"

---

## 🔄 **Recommended Next Steps**

1. **Create a Security Specification document** addressing all CRITICAL items.
2. **Propose updated schema** with indexes, key pair versioning, and authentication flow updates.
3. **Circulate to stakeholders** (product, security, compliance) for sign-off.
4. **Kick off Phase 1** of implementation with crypto service tests.

---

**End of Review**
