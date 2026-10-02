// lib/utils/translation_edit_marker.dart

/// Content-version markers for cached chat translations.
///
/// An edit rewrites a message in place: the row keeps its `id` and only its
/// `edited_at` (and ciphertext) change. Anything cached "for this message" is
/// therefore still keyed by the same id after an edit, which makes `id` useless
/// for deciding whether a cached translation describes the text currently on
/// screen. The fix used throughout the app is to also record the `edited_at` the
/// translation was produced for and require the two to still agree.
///
/// This is the same invariant translate-proxy enforces server-side with
/// `chat_messages.translated_source_edited_at`; these helpers are the client
/// side of it, shared by the message cache and the chat-list preview cache so
/// both fail in the same direction (retranslate, never serve stale text).
library;

/// Normalizes a raw `edited_at` into a comparable marker string.
///
/// Timestamps arrive as a Dart `DateTime` (PostgREST), an ISO string (Hive
/// round trip), or as the string `'null'` (JSON decoded from SQL NULL), and
/// "absent" legitimately means "this message was never edited". Collapse every
/// spelling of absent to `null` so callers can compare with `==`.
String? normalizeEditMarker(Object? raw) {
  if (raw == null) return null;
  final text = raw is DateTime ? raw.toIso8601String() : raw.toString();
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed == 'null') return null;
  return trimmed;
}

/// True when a translation was made for the row's current content:
/// the marker recorded at translation time still matches the row's `edited_at`.
///
/// NULL-safe on both sides and compared as instants (immune to timestamptz
/// formatting drift). A missing marker matches only a never-edited row, so a
/// translation cached before this marker existed is correctly treated as stale
/// for any row that has since been edited, and as current for one that has not.
/// Unparseable values fail safe (false -> retranslate, never serve stale).
bool translationEditMarkersMatch(String? storedMarker, String? rowEditedAt) {
  final m = normalizeEditMarker(storedMarker);
  final e = normalizeEditMarker(rowEditedAt);
  if (m == null || e == null) return m == e;
  if (m == e) return true;
  final mMs = DateTime.tryParse(m)?.millisecondsSinceEpoch;
  final eMs = DateTime.tryParse(e)?.millisecondsSinceEpoch;
  if (mMs == null || eMs == null) return false;
  return mMs == eMs;
}

/// True when a cached chat-list preview translation may still be rendered.
///
/// The Recent Chats row is driven by a decrypted preview cached in Hive
/// (`recent_chats_$userId`) rather than by the message cache, so it needs both
/// halves of the check: the cached text must be a real translation *of the
/// current UI language* and *of the message's current content*.
///
/// [cachedText] is expected to already have been rejected if it is raw
/// ciphertext (see `looksLikeEncryptedBlob`).
bool previewTranslationIsCurrent({
  required String? cachedText,
  required String? cachedTargetLanguage,
  required String? cachedEditedAt,
  required String? messageEditedAt,
  required String uiLanguage,
  required String Function(String) normalizeLanguage,
}) {
  if (cachedText == null || cachedText.isEmpty || cachedText == 'null') {
    return false;
  }
  final cachedTarget = normalizeEditMarker(cachedTargetLanguage);
  if (cachedTarget == null || normalizeLanguage(cachedTarget) != uiLanguage) {
    return false;
  }
  return translationEditMarkersMatch(cachedEditedAt, messageEditedAt);
}
