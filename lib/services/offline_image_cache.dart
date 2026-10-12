import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:matchme/services/hive_encryption_service.dart';

/// Encrypted on-disk cache of raw image bytes, keyed by
/// `StorageHelper.cacheKeyForSource`.
///
/// Used by [SignedImage] on every platform so photos paint from local bytes
/// on relaunch without any signed-URL resolution or network access. A small
/// in-process LRU avoids repeat Hive reads within a session; the Hive box
/// survives relaunches and is cleared on logout.
class OfflineImageCache {
  OfflineImageCache._();

  static final OfflineImageCache instance = OfflineImageCache._();
  static const String _boxName = 'offline_image_bytes';

  /// In-process hot cache (insertion-ordered LRU). Keeps the same byte
  /// instances alive so `Image.memory`'s cache key is stable across rebuilds.
  static const int _maxMemoryEntries = 80;

  /// Bound the encrypted box so native (now also caching chat/profile photos)
  /// cannot grow without limit. On overflow, drop the oldest entries.
  static const int _maxDiskEntries = 500;
  static const int _diskEvictionBatch = 50;

  final Map<String, Uint8List> _memory = {};

  Future<Box>? _boxFuture;

  Future<Box> _box() {
    _boxFuture ??= HiveEncryptionService.instance
        .openEncryptedBoxDynamic(_boxName)
        .catchError((Object error) {
          _boxFuture = null;
          throw StateError('Could not open the offline image cache: $error');
        });
    return _boxFuture!;
  }

  /// Opens the underlying box early so the first read after launch doesn't
  /// pay box-open latency during the first Home frame. Best-effort.
  Future<void> warmup() async {
    try {
      await _box();
    } catch (_) {}
  }

  /// Synchronous hot-cache lookup; returns the shared instance (or null).
  Uint8List? peek(String key) {
    if (key.isEmpty) return null;
    final bytes = _memory.remove(key);
    if (bytes == null) return null;
    // Re-insert to mark as most-recently used.
    _memory[key] = bytes;
    return bytes;
  }

  Future<Uint8List?> read(String key) async {
    if (key.isEmpty) return null;
    final hot = peek(key);
    if (hot != null) return hot;
    try {
      final entry = (await _box()).get(key);
      Uint8List? bytes;
      if (entry is Uint8List) {
        bytes = entry;
      } else if (entry is List<int>) {
        bytes = Uint8List.fromList(entry);
      }
      if (bytes == null || bytes.isEmpty) return null;
      _remember(key, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, Uint8List bytes) async {
    if (key.isEmpty || bytes.isEmpty) return;
    _remember(key, bytes);
    try {
      final box = await _box();
      await box.put(key, bytes);
      if (box.length > _maxDiskEntries) {
        final excess = box.length - _maxDiskEntries + _diskEvictionBatch;
        final staleKeys = box.keys.take(excess).toList();
        for (final k in staleKeys) {
          await box.delete(k);
          _memory.remove(k);
        }
      }
    } catch (_) {}
  }

  Future<void> evict(String key) async {
    if (key.isEmpty) return;
    _memory.remove(key);
    try {
      await (await _box()).delete(key);
    } catch (_) {}
  }

  Future<void> clear() async {
    _memory.clear();
    try {
      await (await _box()).clear();
    } catch (_) {}
  }

  void _remember(String key, Uint8List bytes) {
    _memory.remove(key);
    _memory[key] = bytes;
    while (_memory.length > _maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }
}
