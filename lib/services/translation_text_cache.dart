import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistent + in-memory cache for one-off text translations.
///
/// Chat messages are translated server-side and stored in the database, but
/// free-form text (the AI's verification reasoning, the mismatch-region
/// descriptions) is translated on the device through DeepL. Without a cache
/// the very same sentence is sent to DeepL again on every screen entry, and
/// a rebuild while a translation is still in flight sends it twice.
class TranslationTextCache {
  TranslationTextCache();

  static final TranslationTextCache instance = TranslationTextCache();

  /// Prefix of the on-device (SharedPreferences) key.
  static const String _prefsPrefix = 'translation_text_cache_';

  /// Session cache: survives rebuilds and screen re-entries.
  ///
  /// Bounded: the oldest entry is dropped when the cap is reached, so a
  /// long session cannot grow it without limit.
  final Map<String, String> _memory = <String, String>{};

  /// Maximum number of entries kept in memory.
  static const int _maxMemoryEntries = 200;

  /// In-flight translations, so two callers asking for the same text at the
  /// same time share ONE request instead of each sending their own.
  final Map<String, Future<String>> _inFlight = <String, Future<String>>{};

  /// Stable key for a (text, target language) pair.
  ///
  /// The sha256 of the text is used on purpose: `String.hashCode` is
  /// documented as *not* guaranteed to be stable between runs, which would
  /// orphan the cached translation and send the text to DeepL again after
  /// every app restart. A content hash is identical on every device,
  /// platform and app version.
  static String cacheKey(String text, String targetLanguage) {
    final digest = sha256.convert(utf8.encode(text)).toString();
    return '${digest}_$targetLanguage';
  }

  /// The on-device key a translation is stored under.
  static String storageKey(String text, String targetLanguage) =>
      '$_prefsPrefix${cacheKey(text, targetLanguage)}';

  /// Returns the cached translation for [text], or null when there is none.
  Future<String?> read(String text, String targetLanguage) async {
    final key = cacheKey(text, targetLanguage);
    final hot = _memory[key];
    if (hot != null) return hot;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('$_prefsPrefix$key');
      if (stored == null || stored.isEmpty) return null;
      _memory.remove(key);
      _memory[key] = stored;
      return stored;
    } catch (e) {
      debugPrint('[TranslationTextCache] Error reading cache: $e');
      return null;
    }
  }

  /// Stores a translation in the session cache and on the device.
  Future<void> write(
    String text,
    String targetLanguage,
    String translated,
  ) async {
    if (translated.isEmpty) return;
    final key = cacheKey(text, targetLanguage);
    // Re-insert so the map keeps insertion order (oldest first).
    _memory.remove(key);
    _memory[key] = translated;
    while (_memory.length > _maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefsPrefix$key', translated);
    } catch (e) {
      debugPrint('[TranslationTextCache] Error writing cache: $e');
    }
  }

  /// Returns the translation of [text] into [targetLanguage].
  ///
  /// The cached copy is used when there is one; otherwise [translate] runs
  /// once and its result is cached. Concurrent callers for the same text
  /// share a single request.
  ///
  /// [legacyStorageKey] points at a translation cached by an older build:
  /// it is adopted instead of paying for another request, so an upgrade does
  /// not send the text to the translator again.
  ///
  /// [shouldCache] decides whether the result is worth keeping. A failed
  /// request comes back as the untranslated source text; caching that would
  /// pin the untranslated text forever, so it is rejected and the next
  /// attempt tries again.
  Future<String> translate(
    String text,
    String targetLanguage,
    Future<String> Function() translate, {
    String? legacyStorageKey,
    bool Function(String translated)? shouldCache,
  }) async {
    final cached = await read(text, targetLanguage);
    if (cached != null) return cached;

    final key = cacheKey(text, targetLanguage);
    final pending = _inFlight[key];
    if (pending != null) return pending;

    final future = _run(
      text,
      targetLanguage,
      translate,
      legacyStorageKey,
    ).then((translated) async {
      if (shouldCache == null || shouldCache(translated)) {
        await write(text, targetLanguage, translated);
      }
      return translated;
    }).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<String> _run(
    String text,
    String targetLanguage,
    Future<String> Function() translate,
    String? legacyStorageKey,
  ) async {
    if (legacyStorageKey != null) {
      final legacy = await readLegacy(legacyStorageKey);
      if (legacy != null) return legacy;
    }
    return translate();
  }

  /// Reads a translation stored under an arbitrary key (legacy format).
  Future<String?> readLegacy(String storageKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(storageKey);
      if (stored == null || stored.isEmpty) return null;
      return stored;
    } catch (_) {
      return null;
    }
  }
}
