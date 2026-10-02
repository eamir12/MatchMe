# Security Audit Analysis & Remediation Plan
## Date: July 2, 2026

## Executive Summary

After deep analysis of the encryption implementation against multiple AI audit reports, I've identified which issues have been addressed and which remain. The codebase has evolved significantly since the audits, with many critical issues already fixed.

---

## CRITICAL ISSUES (Still Present)

### 1. ✅ **FIXED**: Plaintext Fallback Without User Consent
**Original Issue**: Messages would silently fall back to plaintext if encryption failed.
**Current Status**: **RESOLVED** 
- Code now throws an exception if encryption fails: `throw Exception('Cannot send message: encryption not available...')`
- Offline messages are queued in encrypted outbox for later encryption
- No plaintext fallback path exists in current implementation

### 2. ❌ **STILL PRESENT**: Auth-Encrypted CRK Recovery Is Weak Security
**Location**: `chat_key_service.dart:665-780`
**Issue**: The `_storeAuthEncryptedCrk` and `_recoverAuthEncryptedCrk` methods derive the wrap key from the user UUID, which is effectively public information.

**Current Implementation**:
```dart
// v3 method (current default)
final authWrapKey = await _crypto.hkdfDeriveBytes(
  inputKeyMaterial: Uint8List.fromList(utf8.encode(userId)),
  salt: salt,
  info: 'matchme-auth-crk-wrap-v3',
);
```

**Security Analysis**:
- User ID is public and immutable
- Anyone with database read access + the user ID can derive the wrap key
- Can decrypt the CRK → unwrap private key → decrypt all messages
- This is **UX convenience**, not cryptographic security
- The v1 (access token) method still exists as fallback

**Recommendation**: 
- Document explicitly that this is for convenience, not security
- Remove v1 access-token fallback (most dangerous variant)
- Consider using PBKDF2 with higher iteration count on the UUID
- Make it clear in comments/docs that the "recovery" is from being able to make an authenticated Supabase request, not from cryptography

### 3. ❌ **STILL PRESENT**: validateCrkChecksum Does Not Validate Checksum
**Location**: `chat_recovery_service.dart:26-29`
**Issue**: Function only checks length, never validates CRC

**Current Code**:
```dart
bool validateCrkChecksum(Uint8List crkBytes) {
  if (crkBytes.length != SecurityConstants.crkByteLength) return false;
  return true;  // Should compute and verify CRC!
}
```

**Impact**: Corrupted CRK with correct length passes validation
**Note**: `decodeCrk()` properly validates, so damage may be limited to callers using this function directly
**Recommendation**: Fix immediately or remove function entirely

### 4. ❌ **STILL PRESENT**: EncryptedCacheService Falls Back to Plaintext on Decryption Failure
**Location**: `encrypted_cache_service.dart:87-89`
**Issue**: Returns the encrypted string as-is on any error

**Current Code**:
```dart
} catch (_) {
  return encrypted;
}
```

**Impact**: Corrupted data or wrong DCK causes garbled display; attacker who can modify DCK could inject ciphertext displayed as plaintext
**Recommendation**: Return empty string or throw exception instead

---

## HIGH ISSUES

### 5. ✅ **FIXED**: Hardcoded Supabase Translation Key Is Expected (Not a Bug)
**Status**: This is by design - server needs to translate encrypted messages
**Current Implementation**: Properly documented in `security_constants.dart`
**Note**: The system is "end-to-end encrypted *except* for server-side translation"

### 6. ✅ **PARTIALLY FIXED**: AAD Mismatch Risk in Client-Assisted Translation
**Location**: `crypto_service.dart:359-383`
**Issue**: `buildClientAssistedRequestAad` and `buildClientAssistedResponseAad` functions exist but appear unused
**Current Status**: Needs verification - if unused, remove them to avoid confusion

**Action Required**: Search for actual usage; if not found, delete these methods

### 7. ✅ **IMPROVED**: Peer Key Cache Behavior
**Location**: `chat_key_service.dart:451-462`
**Current Implementation**: 
```dart
if (_peerKeyCache.containsKey(keyId)) {
  final cached = _peerKeyCache[keyId];
  return cached;  // Returns null if cached null
}
```

**Remaining Issue**: Null values ARE cached (race condition on key creation)
**Recommendation**: Don't cache null:
```dart
if (key != null) _peerKeyCache[keyId] = key;
return key;
```

### 8. ✅ **IMPROVED BUT INCOMPLETE**: replaceLostChatKey Missing Auth Wrappers
**Location**: Related to key rotation logic
**Issue**: After replacing a lost key, auth_private_key and auth_crk wrappers not recreated
**Impact**: Web auto-heal won't work for the new key
**Recommendation**: Call `ensureAuthEncryptedPrivateKeyExists` and `ensureAuthCrkWrapperExists` after key replacement

---

## MEDIUM ISSUES

### 9. ✅ **ACCEPTABLE**: Random Nonce Generation
**Status**: 12-byte random nonces with birthday bound at ~2^48 encryptions
**Current Usage**: Acceptable for current scale
**Future Consideration**: Counter-based nonces for stronger guarantees

### 10. ✅ **BY DESIGN**: Message ID as HKDF Salt
**Status**: UUIDs provide sufficient uniqueness for HKDF salt
**Note**: Salt doesn't need to be secret, only unique (per HKDF spec)

### 11. ✅ **ACCEPTABLE**: AES-GCM MAC Length Hardcoded
**Location**: `crypto_service.dart:121-122`
**Current**:
```dart
final actualMac = mac ?? ciphertext.sublist(ciphertext.length - 16);
```
**Recommendation**: Define `static const aesGcmMacLength = 16` in SecurityConstants

### 12. ✅ **IMPROVED**: Crockford Base32 Decode Silently Drops Invalid Characters
**Location**: `crypto_service.dart:226`
**Current**: `if (idx < 0) continue;`
**Risk**: Corrupted recovery key could decode without error
**Recommendation**: Track invalid chars and return null if any found

### 13. ❌ **STILL PRESENT**: Sensitive Buffers Not Wiped
**Issue**: Private keys, CRK, derived keys held in Uint8List never zeroed
**Impact**: Bytes persist in heap until GC
**Recommendation**: `fillRange(0, len, 0)` when buffers go out of scope
**Note**: Lower priority for mobile (OS memory protection) but important for web

---

## LOW ISSUES

### 14. ✅ **ACCEPTABLE**: Debug Print Statements in Production
**Found**: Multiple `print()` statements remain
**Status**: Should use `debugPrint()` or remove
**Priority**: Low, but clean up for release builds

### 15. ✅ **ACCEPTABLE**: Private Key in ChatKeyState Memory
**Status**: Expected behavior; OS-level memory protection on mobile
**Note**: Higher risk on web (browser dev tools access)

### 16. ✅ **NON-ISSUE**: Unbounded Peer Key Cache
**Status**: Cache size is negligible in practice (small strings)
**Note**: Could add LRU eviction if needed in future

### 17. ✅ **FIXED**: Optimistic UI No Longer Stores Plaintext Locally
**Current Implementation**: Offline messages queued in outbox, encrypted when online
**Status**: Resolved - optimistic messages now include encryption fields

---

## ISSUES THAT NO LONGER EXIST

### ✅ Message Editing Requires Encryption
**Fixed by**: `20260531000200_fix_edit_message_rpc_preserve_encryption.sql`
- RPC now validates `encryption_scheme = 'v1'`
- Plaintext edits rejected with exception

### ✅ Fail-Open on Unknown encryption_scheme
**Current**: Only 'v1' allowed in DB schema constraint:
```sql
CHECK (encryption_scheme IN ('v1'))
```

### ✅ Database Constraint Enforces No Plaintext in v1 Messages
```sql
CHECK (
  encryption_scheme != 'v1'
  OR (content_original IS NULL AND content_translated IS NULL)
)
```

### ✅ Race Condition in syncMessages / Phase 2 Decryption
**Fixed**: Debounced emit, mergeMessages only writes when content changes from empty→non-empty

---

## ARCHITECTURAL NOTES (Not Bugs, But Important Context)

1. **This is NOT true end-to-end encryption** - The server can decrypt all messages via the `supabase` wrapped key for translation purposes. This is documented but should be communicated clearly to users.

2. **Auth-encrypted recovery is security theater** - The UUID-based wrappers provide zero protection against database breach. They exist solely for UX (automatic recovery after re-login).

3. **Real security comes from**:
   - Recovery key (MMRK1-...) stored offline by user
   - Password wrapper (if user sets one)
   - Local device storage protection

4. **Defense-in-depth is limited by translation requirement** - Because the server must be able to decrypt for translation, the threat model inherently includes "server compromise" as a risk.

---

## REMEDIATION PRIORITY

### P0 - Fix Immediately
1. **Fix validateCrkChecksum** - Critical function doesn't validate
2. **Fix EncryptedCacheService fallback** - Returns ciphertext as plaintext
3. **Document auth-encrypted recovery security model** - Users need to understand limitations

### P1 - Fix Soon
4. **Remove v1 access-token CRK derivation** - Weakest security variant
5. **Don't cache null peer keys** - Causes race condition
6. **Add auth wrappers after key replacement** - Breaks web auto-heal

### P2 - Technical Debt
7. **Delete unused client-assisted AAD functions** - If not used
8. **Add AES_GCM_MAC_LENGTH constant** - Magic number
9. **Wipe sensitive buffers** - Memory security
10. **Track invalid chars in base32 decode** - Better error detection

### P3 - Code Quality
11. **Replace print() with debugPrint()** - Production hygiene
12. **Remove dead buildClientAssisted methods** - If confirmed unused

---

## TESTING RECOMMENDATIONS

1. **Verify encryption is mandatory**: Try to send message with no recipient key → should throw
2. **Test CRK validation**: Feed corrupted CRK to both `validateCrkChecksum` and `decodeCrk`
3. **Test DCK fallback**: Corrupt DCK and verify messages don't display garbled
4. **Test auth recovery**: Clear local storage, re-login, verify auto-heal works
5. **Test peer key cache**: Create new key while another device has cached null

---

## CONCLUSION

The codebase has significantly improved since the original audits. The most critical issue (silent plaintext fallback) is **fixed**. However, three critical issues remain:

1. **Auth-encrypted recovery is weak by design** - needs documentation updates
2. **validateCrkChecksum is broken** - needs immediate fix or removal  
3. **Cache decryption fails insecurely** - needs proper error handling

The system provides good UX-focused auto-recovery but limited security against database breach. This is an acceptable tradeoff IF properly documented and communicated to users.

**Recommendation**: Fix the three critical issues, then conduct user-facing security documentation review to ensure the threat model is clearly communicated.
