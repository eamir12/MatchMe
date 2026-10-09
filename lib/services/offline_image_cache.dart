import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:matchme/services/hive_encryption_service.dart';

class OfflineImageCache {
  OfflineImageCache._();

  static final OfflineImageCache instance = OfflineImageCache._();
  static const String _boxName = 'offline_image_bytes';

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

  Future<Uint8List?> read(String key) async {
    if (key.isEmpty) return null;
    final entry = (await _box()).get(key);
    if (entry is Uint8List) return Uint8List.fromList(entry);
    if (entry is List<int>) return Uint8List.fromList(entry);
    return null;
  }

  Future<void> write(String key, Uint8List bytes) async {
    if (key.isEmpty || bytes.isEmpty) return;
    await (await _box()).put(key, Uint8List.fromList(bytes));
  }

  Future<void> evict(String key) async {
    if (key.isEmpty) return;
    await (await _box()).delete(key);
  }

  Future<void> clear() async {
    await (await _box()).clear();
  }
}
