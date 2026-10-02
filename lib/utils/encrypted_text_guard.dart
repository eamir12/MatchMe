import 'dart:math' as math;

/// Marker `translate-proxy` appends to `chat_messages.translated_target_language`
/// while it owns a translation round trip. See `claimMessageForTranslation` in
/// `supabase/functions/translate-proxy/index.ts`:
/// `translated_target_language = "<lang>#pending#<epochMs>"`.
///
/// While the marker is present the row still holds the *previous* target's
/// ciphertext, so any client that compares the raw column value against the UI
/// language sees a mismatch and blanks an otherwise perfectly readable cached
/// translation.
const String kPendingTranslationMarker = '#pending#';

final RegExp _pendingMarkerPattern = RegExp(
  r'^(.*?)#pending#\d+\s*$',
  caseSensitive: false,
);

/// Returns the base language code with any `#pending#<epoch>` claim marker
/// removed, lowercased. Returns `null` for null/blank input.
String? stripPendingTranslationMarker(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final match = _pendingMarkerPattern.firstMatch(trimmed);
  if (match == null) return trimmed.toLowerCase();
  final base = match.group(1)?.trim() ?? '';
  return base.isEmpty ? null : base.toLowerCase();
}

/// True when [value] carries an in-flight `#pending#` translation claim.
bool hasPendingTranslationMarker(String? value) {
  if (value == null) return false;
  return value.toLowerCase().contains(kPendingTranslationMarker);
}

final RegExp _base64Shape = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

/// Shannon entropy (bits per character) of [value].
double _shannonEntropy(String value) {
  if (value.isEmpty) return 0;
  final counts = <int, int>{};
  for (final unit in value.codeUnits) {
    counts[unit] = (counts[unit] ?? 0) + 1;
  }
  var entropy = 0.0;
  for (final count in counts.values) {
    final p = count / value.length;
    entropy -= p * (math.log(p) / math.ln2);
  }
  return entropy;
}

/// Detects a raw AES-256-GCM blob (base64 of `ciphertext || mac`).
///
/// `get_user_recent_chats` exposes `chat_messages.content_translated_encrypted`
/// in its `last_message_translated` column, so raw ciphertext can reach the
/// chats cache whenever decryption is unavailable — the chat key is not loaded
/// yet, the peer public key cannot be fetched, or the translated AAD does not
/// match because `translate-proxy` currently holds a `#pending#` claim on the
/// row. None of those blobs are readable, so they must never be shown.
///
/// The shape test is deliberately strict (long, whitespace-free, base64
/// alphabet) and is combined with an entropy floor: base64 of 80+ random bytes
/// sits above ~4.6 bits/char, while human-written text of the same length
/// stays well below that. This keeps long single-word messages such as
/// `helloworldthisisalongusername` from being mistaken for ciphertext.
bool looksLikeEncryptedBlob(String? value) {
  if (value == null) return false;
  final trimmed = value.trim();
  // A blob is always a long unbroken token. Anything with whitespace, line
  // breaks or sentence punctuation is human-readable text.
  if (trimmed.length < 32) return false;
  if (trimmed.contains(RegExp(r'\s'))) return false;
  if (!_base64Shape.hasMatch(trimmed)) return false;
  return _shannonEntropy(trimmed) >= 4.6;
}

/// Returns [value] when it is safe to hand to the UI, otherwise an empty
/// string. Use for any text that may have originated from the encrypted chat
/// pipeline so ciphertext degrades to the caller's loading/empty state instead
/// of being painted.
String displaySafeText(String? value) {
  if (value == null) return '';
  if (value == 'null' || value == 'Loading…') return value;
  if (looksLikeEncryptedBlob(value)) return '';
  return value;
}
