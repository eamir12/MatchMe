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
  /// Bounded by both entry count and total bytes so full-resolution photos
  /// cannot balloon process memory.
  static const int _maxMemoryEntries = 80;
  static const int _maxMemoryBytes = 64 * 1024 * 1024;

  /// Bound the encrypted box by entries and total bytes. Full-size gallery
  /// photos are several megabytes each, so a count-only limit is not enough.
  /// On overflow, drop the oldest entries.
  static const int _maxDiskEntries = 3000;
  static const int _maxDiskBytes = 256 * 1024 * 1024;

  /// One absurdly large asset should not evict the entire cache.
  static const int maxPersistedImageBytes = 32 * 1024 * 1024;

  final Map<String, Uint8List> _memory = {};
  int _memoryBytes = 0;
  int? _diskBytes;

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
    if (bytes.length > maxPersistedImageBytes) return;
    try {
      final box = await _box();
      await _ensureDiskBytes(box);
      final previous = box.get(key);
      final previousSize = previous is List<int> ? previous.length : 0;
      await box.put(key, bytes);
      _diskBytes = (_diskBytes ?? 0) - previousSize + bytes.length;
      await _evictDiskIfNeeded(box);
    } catch (_) {}
  }

  Future<void> evict(String key) async {
    if (key.isEmpty) return;
    final removed = _memory.remove(key);
    if (removed != null) _memoryBytes -= removed.length;
    try {
      final box = await _box();
      await _ensureDiskBytes(box);
      final previous = box.get(key);
      await box.delete(key);
      if (previous is List<int>) {
        _diskBytes = (_diskBytes ?? 0) - previous.length;
        if (_diskBytes! < 0) _diskBytes = 0;
      }
    } catch (_) {}
  }

  Future<void> clear() async {
    _memory.clear();
    _memoryBytes = 0;
    _diskBytes = 0;
    try {
      await (await _box()).clear();
    } catch (_) {}
  }

  Future<void> _ensureDiskBytes(Box box) async {
    if (_diskBytes != null) return;
    var total = 0;
    for (final value in box.values) {
      if (value is List<int>) total += value.length;
    }
    _diskBytes = total;
  }

  Future<void> _evictDiskIfNeeded(Box box) async {
    var total = _diskBytes ?? 0;
    if (box.length <= _maxDiskEntries && total <= _maxDiskBytes) return;
    for (final key in box.keys.toList()) {
      if (box.length <= _maxDiskEntries && total <= _maxDiskBytes) break;
      final value = box.get(key);
      if (value is List<int>) total -= value.length;
      await box.delete(key);
      _memory.remove(key);
    }
    _diskBytes = total < 0 ? 0 : total;
  }

  void _remember(String key, Uint8List bytes) {
    final previous = _memory.remove(key);
    if (previous != null) _memoryBytes -= previous.length;
    _memory[key] = bytes;
    _memoryBytes += bytes.length;
    while (_memory.length > _maxMemoryEntries ||
        (_memoryBytes > _maxMemoryBytes && _memory.length > 1)) {
      final oldestKey = _memory.keys.first;
      final removed = _memory.remove(oldestKey);
      if (removed != null) _memoryBytes -= removed.length;
    }
  }
}
